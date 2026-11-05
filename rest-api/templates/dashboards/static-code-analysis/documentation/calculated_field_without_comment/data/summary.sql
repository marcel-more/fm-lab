-- Feeds the KPI strip (finding_count for the selected filter) and the comment
-- filter chips (count_without / count_with = true totals, uncapped).
WITH calc AS (
    SELECT c.File_Name,
        (COALESCE(f.Field_Comment, '') <> ''
         OR (c.Formula_Hash IS NOT NULL AND EXISTS (
              SELECT 1 FROM DDR_Calculations d
              WHERE d.Calc_Hash = c.Formula_Hash AND d.Chunk_Type = 'Comment'))) AS has_comment
    FROM CalculationsCatalog c
    JOIN FieldsForTables f ON f.Field_UUID = c.Owner_UUID AND f.File_Name = c.File_Name
    WHERE c.Calc_Role = 'field_calculation'
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
sel AS (SELECT COALESCE(getvariable('comment'), 'without') = 'with' AS want_with)
SELECT
    COUNT(*) FILTER (WHERE NOT has_comment) AS count_without,
    COUNT(*) FILTER (WHERE has_comment)     AS count_with,
    CASE WHEN (SELECT want_with FROM sel) THEN COUNT(*) FILTER (WHERE has_comment)
         ELSE COUNT(*) FILTER (WHERE NOT has_comment) END AS finding_count,
    'info' AS severity,
    CASE WHEN (SELECT want_with FROM sel) THEN COUNT(DISTINCT File_Name) FILTER (WHERE has_comment)
         ELSE COUNT(DISTINCT File_Name) FILTER (WHERE NOT has_comment) END AS affected_files
FROM calc;
