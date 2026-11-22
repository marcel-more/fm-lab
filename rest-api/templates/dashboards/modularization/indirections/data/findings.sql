-- @template_type: report
-- @description: Server-paged list of the indirect references of the current lens — one row per site: mechanism, carrier (script with step, custom function, field, layout object), the addressing expression, its resolution class and, for a resolvable literal, the presumed target.
-- @params: file, scope_uuids, disabled (hide|include, default hide), kind (default all), resolution (default all), mechanism (optional), q, page, page_size, sort
WITH
--#include shared/sites.sql
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        c.mechanism_id,
        c.mechanism_label,
        c.kind,
        c.file_name                                      AS file,
        c.nav_uuid,
        c.nav_type,
        c.carrier_type,
        c.carrier_name,
        c.step_no,
        c.step_uuid,
        CASE WHEN length(regexp_replace(c.expression, '\s+', ' ', 'g')) > 160
             THEN left(regexp_replace(c.expression, '\s+', ' ', 'g'), 159) || '…'
             ELSE regexp_replace(c.expression, '\s+', ' ', 'g') END AS expression,
        c.resolution_class,
        c.target_type,
        c.target_name,
        c.match_count,
        c.target_note,
        c.guarded,
        c.low_confidence,
        c.is_enabled,
        c.sql_index                                      AS _ord_sql,
        coalesce(c.expression, '')                       AS _ord_expr
    FROM lens c
    WHERE c.in_kind AND c.in_resolution AND c.in_mechanism
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_sql, _ord_expr),
           row_number() OVER (ORDER BY u.file, u.carrier_name, u.step_no, u.mechanism_id, u._ord_sql, u._ord_expr, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 400), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*, pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
