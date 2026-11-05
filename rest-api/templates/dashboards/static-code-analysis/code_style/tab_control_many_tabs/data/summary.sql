-- Feeds the KPI strip (finding_count / affected_files at the current threshold)
-- and the header slider's dynamic upper bound (max_tab_count = the highest value
-- across ALL rows in scope, independent of the threshold).
WITH per_group AS (
    SELECT COUNT(*) AS cnt, lo.File_Name AS file_name
    FROM LayoutObjects lo
    WHERE lo.Object_Type = 'Panel'
      AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
    GROUP BY lo.Parent_Object_ID, lo.Layout_ID, lo.File_Name
),
threshold AS (SELECT CAST(COALESCE(getvariable('min_tabs'), '6') AS INTEGER) AS t)
SELECT
    COUNT(*) FILTER (WHERE cnt >= (SELECT t FROM threshold))                 AS finding_count,
    'info'                                                                   AS severity,
    COUNT(DISTINCT file_name) FILTER (WHERE cnt >= (SELECT t FROM threshold)) AS affected_files,
    COALESCE(MAX(cnt), 0)                                                     AS max_tab_count
FROM per_group;
