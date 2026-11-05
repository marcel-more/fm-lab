-- Ratio KPIs for the local-CSS metric. objects_total / objects_with_css /
-- share_pct describe the whole scope (they ignore min_share — the share is the
-- measurement, not a filter result), while finding_count counts the layouts
-- the table actually lists, i.e. those at or above the slider threshold. That
-- is also the member's default result, so the tests tab reports "layouts above
-- the threshold" rather than "objects with CSS".
WITH per_layout AS (
    SELECT lo.File_Name, lo.Layout_ID,
           COUNT(*) AS objects_total,
           COUNT(*) FILTER (WHERE lo.Object_XML LIKE '%<LocalCSS%') AS objects_with_css
    FROM LayoutObjects lo
    GROUP BY lo.File_Name, lo.Layout_ID
),
scoped AS (
    SELECT p.*, ly.L_UUID
    FROM per_layout p
    JOIN Layouts ly ON p.Layout_ID = ly.L_ID AND p.File_Name = ly.File_Name
    WHERE p.objects_total > 0
      AND (getvariable('file') IS NULL OR p.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
)
SELECT COALESCE(SUM(objects_total), 0) AS objects_total,
       COALESCE(SUM(objects_with_css), 0) AS objects_with_css,
       COALESCE(ROUND(100.0 * SUM(objects_with_css) / NULLIF(SUM(objects_total), 0), 1), 0) AS share_pct,
       COUNT(*) FILTER (WHERE objects_with_css > 0
                          AND 100.0 * objects_with_css / objects_total
                              >= CAST(COALESCE(getvariable('min_share'), '50') AS DOUBLE)) AS finding_count
FROM scoped;
