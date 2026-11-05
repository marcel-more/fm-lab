-- Hand-maintained wrapper around the rule core (layout_copied_object_name).
-- The object-type select (getvariable('object_type')) narrows all counts;
-- the reason filter is deliberately NOT applied here — the per-reason counts
-- feed the chip badges, which must always show the true per-reason totals.
WITH named AS (
    SELECT File_Name, Layout_ID, Object_UUID, Object_Type, Object_Name
    FROM LayoutObjects
    WHERE Object_Name IS NOT NULL AND trim(Object_Name) <> ''
),
dups AS (
    SELECT File_Name, Layout_ID, Object_Name
    FROM named
    GROUP BY ALL
    HAVING COUNT(*) > 1
),
flagged AS (
    SELECT n.File_Name, n.Layout_ID,
        CASE WHEN n.Object_Name LIKE '% Copy' OR n.Object_Name LIKE '% copy' OR n.Object_Name LIKE '% Kopie'
             THEN 'copy-suffix'
             WHEN d.Object_Name IS NOT NULL THEN 'duplicate-name'
             ELSE 'numeric-suffix' END AS reason,
        l.L_UUID
    FROM named n
    JOIN Layouts l ON n.Layout_ID = l.L_ID AND n.File_Name = l.File_Name
    LEFT JOIN dups d ON d.File_Name = n.File_Name AND d.Layout_ID = n.Layout_ID
     AND d.Object_Name = n.Object_Name
    WHERE (n.Object_Name LIKE '% Copy' OR n.Object_Name LIKE '% copy' OR n.Object_Name LIKE '% Kopie'
           OR regexp_matches(n.Object_Name, ' \d{1,4}$')
           OR d.Object_Name IS NOT NULL)
      AND (getvariable('object_type') IS NULL OR n.Object_Type = getvariable('object_type'))
      AND (getvariable('file') IS NULL OR n.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE reason = 'copy-suffix') AS copy_suffix_count,
       COUNT(*) FILTER (WHERE reason = 'numeric-suffix') AS numeric_suffix_count,
       COUNT(*) FILTER (WHERE reason = 'duplicate-name') AS duplicate_count
FROM flagged;
