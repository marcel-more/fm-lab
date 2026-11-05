-- Distinct object types among the rule's findings — options dataset for the
-- object-type Select. Deliberately independent of the defect and object_type
-- filters so the option list stays stable while filtering; respects the
-- file/scope filters and the min_w/min_h sliders (they change which objects are
-- findings at all).
WITH sized AS (
    SELECT File_Name, Layout_ID, Object_Type, Text_Content,
           (Bounds_Right - Bounds_Left) AS w, (Bounds_Bottom - Bounds_Top) AS h
    FROM LayoutObjects
    WHERE Object_Type <> 'Line'
),
classified AS (
    SELECT *,
        CASE WHEN w <= 0 OR h <= 0 THEN 'zero-size'
             WHEN Object_Type = 'Text' AND trim(COALESCE(Text_Content, '')) = '' THEN 'empty-text'
             WHEN w < CAST(COALESCE(getvariable('min_w'), '4') AS INTEGER)
              AND h < CAST(COALESCE(getvariable('min_h'), '4') AS INTEGER) THEN 'undersized'
        END AS defect
    FROM sized
)
SELECT DISTINCT c.Object_Type AS value, c.Object_Type AS label
FROM classified c
JOIN Layouts ly ON c.Layout_ID = ly.L_ID AND c.File_Name = ly.File_Name
WHERE c.defect IS NOT NULL
  AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY value;
