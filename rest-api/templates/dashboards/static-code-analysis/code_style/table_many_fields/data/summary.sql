-- Feeds the KPI strip (finding_count / affected_files at the current threshold)
-- and the header slider's dynamic upper bound (max_field_count = the highest value
-- across ALL rows in scope, independent of the threshold).
WITH per_group AS (
    SELECT COUNT(*) AS cnt, any_value(f.File_Name) AS file_name
    FROM FieldsForTables f
    WHERE (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
    GROUP BY f.File_Name, f.Table_UUID
),
threshold AS (SELECT CAST(COALESCE(getvariable('min_fields'), '100') AS INTEGER) AS t)
SELECT
    COUNT(*) FILTER (WHERE cnt >= (SELECT t FROM threshold))                 AS finding_count,
    'info'                                                                   AS severity,
    COUNT(DISTINCT file_name) FILTER (WHERE cnt >= (SELECT t FROM threshold)) AS affected_files,
    COALESCE(MAX(cnt), 0)                                                     AS max_field_count
FROM per_group;
