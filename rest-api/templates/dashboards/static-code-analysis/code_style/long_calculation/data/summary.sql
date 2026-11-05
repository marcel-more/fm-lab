-- Feeds the KPI strip (finding_count / affected_files at the current threshold)
-- and the header slider's dynamic upper bound (max_calc_length = the highest value
-- across ALL rows in scope, independent of the threshold).
WITH per_group AS (
    SELECT length(COALESCE(f.Calculation_Text, '')) AS cnt, f.File_Name AS file_name
    FROM FieldsForTables f
    WHERE f.Field_Type = 'Calculated'
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
),
threshold AS (SELECT CAST(COALESCE(getvariable('min_calc_length'), '2000') AS INTEGER) AS t)
SELECT
    COUNT(*) FILTER (WHERE cnt >= (SELECT t FROM threshold))                 AS finding_count,
    'info'                                                                   AS severity,
    COUNT(DISTINCT file_name) FILTER (WHERE cnt >= (SELECT t FROM threshold)) AS affected_files,
    COALESCE(MAX(cnt), 0)                                                     AS max_calc_length
FROM per_group;
