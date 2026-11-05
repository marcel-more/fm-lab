-- Local CSS as a ratio, aggregated PER LAYOUT rather than per object.
--
-- Local overrides are near-universal in practice (well over 90 % of all
-- objects in a mature solution), so an object-level findings list would be a
-- dump of the whole catalog rather than a set of defects. The useful signal is
-- the share per layout, and the min_share slider sets where "styled by hand"
-- starts. Layouts without objects are left out — a share of zero out of zero
-- is not a finding.
--
-- Findings are layout-level: object_uuid stays NULL and the row click opens
-- the layout without an object highlight.
-- Translated from fmCheckMate ReportLocalCSS (traffic-light idea).
WITH per_layout AS (
    SELECT lo.File_Name, lo.Layout_ID,
           COUNT(*) AS objects_total,
           COUNT(*) FILTER (WHERE lo.Object_XML LIKE '%<LocalCSS%') AS objects_with_css
    FROM LayoutObjects lo
    GROUP BY lo.File_Name, lo.Layout_ID
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-local-css' AS rule_id, 'info' AS severity,
        p.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        NULL AS object_uuid,
        p.objects_total, p.objects_with_css,
        ROUND(100.0 * p.objects_with_css / p.objects_total, 1) AS share_pct,
        p.objects_with_css || ' of ' || p.objects_total || ' objects on this layout carry local CSS ('
          || ROUND(100.0 * p.objects_with_css / p.objects_total, 1) || ' %)' AS message,
           (1.0 * p.objects_with_css / p.objects_total) AS _ord_1,
           p.objects_with_css AS _ord_2,
           p.File_Name AS _ord_3,
           ly.L_Name AS _ord_4
    FROM per_layout p
    JOIN Layouts ly ON p.Layout_ID = ly.L_ID AND p.File_Name = ly.File_Name
    WHERE p.objects_total > 0
      AND p.objects_with_css > 0
      AND 100.0 * p.objects_with_css / p.objects_total
          >= CAST(COALESCE(getvariable('min_share'), '50') AS DOUBLE)
      AND (getvariable('file') IS NULL OR p.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4),
           row_number() OVER (ORDER BY u._ord_1 DESC, u._ord_2 DESC, u._ord_3, u._ord_4, u) AS row_key
    FROM unkeyed u
),
-- >>> shared paging table-search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) NOT IN ('uuid', 'nav_uuid', 'row_key')))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging table-search block
filtered AS (
    SELECT * FROM searched
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
