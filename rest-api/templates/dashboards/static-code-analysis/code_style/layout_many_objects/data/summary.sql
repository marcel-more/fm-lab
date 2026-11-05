-- Feeds the KPI strip (finding_count / affected_files at the current threshold)
-- and the header slider's dynamic upper bound (max_object_count = the highest
-- object count across ALL layouts in scope, independent of the threshold).
WITH per_layout AS (
    SELECT lo.Layout_ID, lo.File_Name, COUNT(*) AS object_count
    FROM LayoutObjects lo
    WHERE (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
    GROUP BY lo.Layout_ID, lo.File_Name
),
threshold AS (SELECT CAST(COALESCE(getvariable('min_objects'), '250') AS INTEGER) AS t)
SELECT
    COUNT(*) FILTER (WHERE object_count >= (SELECT t FROM threshold))                    AS finding_count,
    'info'                                                                               AS severity,
    COUNT(DISTINCT File_Name) FILTER (WHERE object_count >= (SELECT t FROM threshold))    AS affected_files,
    COALESCE(MAX(object_count), 0)                                                        AS max_object_count
FROM per_layout;
