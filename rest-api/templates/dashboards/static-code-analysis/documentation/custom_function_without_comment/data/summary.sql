-- Feeds the KPI strip and the comment filter chips (true totals, uncapped).
WITH cf AS (
    SELECT c.File_Name,
        EXISTS (SELECT 1 FROM DDR_Calculations d
                WHERE d.Calc_Hash = c.Formula_Hash AND d.Chunk_Type = 'Comment') AS has_comment
    FROM CalculationsCatalog c
    WHERE c.Calc_Role = 'custom_function'
      AND c.Formula_Hash IS NOT NULL
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
FROM cf;
