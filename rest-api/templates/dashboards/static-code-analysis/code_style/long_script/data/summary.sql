-- Feeds the KPI strip (finding_count / affected_files at the current threshold)
-- and the header slider's dynamic upper bound (max_step_count = the highest value
-- across ALL rows in scope, independent of the threshold).
WITH per_group AS (
    SELECT COUNT(*) AS cnt, File_Name AS file_name
    FROM StepsForScripts
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY File_Name, Script_ID
),
threshold AS (SELECT CAST(COALESCE(getvariable('min_steps'), '150') AS INTEGER) AS t)
SELECT
    COUNT(*) FILTER (WHERE cnt >= (SELECT t FROM threshold))                 AS finding_count,
    'info'                                                                   AS severity,
    COUNT(DISTINCT file_name) FILTER (WHERE cnt >= (SELECT t FROM threshold)) AS affected_files,
    COALESCE(MAX(cnt), 0)                                                     AS max_step_count
FROM per_group;
