-- Distinct object types among the rule's findings — options dataset for the
-- object-type Select. Deliberately independent of the reason and object_type
-- filters so the option list stays stable while filtering; respects the
-- file/scope filters.
WITH named AS (
    SELECT File_Name, Layout_ID, Object_Type, Object_Name
    FROM LayoutObjects
    WHERE Object_Name IS NOT NULL AND trim(Object_Name) <> ''
),
dups AS (
    SELECT File_Name, Layout_ID, Object_Name
    FROM named
    GROUP BY ALL
    HAVING COUNT(*) > 1
)
SELECT DISTINCT n.Object_Type AS value, n.Object_Type AS label
FROM named n
JOIN Layouts l ON n.Layout_ID = l.L_ID AND n.File_Name = l.File_Name
LEFT JOIN dups d ON d.File_Name = n.File_Name AND d.Layout_ID = n.Layout_ID
 AND d.Object_Name = n.Object_Name
WHERE (n.Object_Name LIKE '% Copy' OR n.Object_Name LIKE '% copy' OR n.Object_Name LIKE '% Kopie'
       OR regexp_matches(n.Object_Name, ' \d{1,4}$')
       OR d.Object_Name IS NOT NULL)
  AND (getvariable('file') IS NULL OR n.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY value;
