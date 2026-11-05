-- @template_type: report
-- @description: Every catalog occurrence of a UUID that exists in more than one file of the solution (clone collisions). Duplicate detection is always solution-wide; the file/scope params filter the listed occurrences only.
-- @params: file (optional), scope_uuids (optional), limit (optional, default 500)
-- keep in sync with data/summary.sql (shared dup CTE + outer filters)
-- Params are normalised ONCE here ('' and NULL both mean "no filter"); each
-- getvariable appears exactly once so the M5a copy-sync check stays green.
WITH params AS (
    SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '') AS file_filter,
           NULLIF(CAST(getvariable('scope_uuids') AS VARCHAR), '') AS scope_csv
),
dup AS (
    SELECT Object_UUID,
           COUNT(*) AS occurrences,
           COUNT(DISTINCT File_Name) AS file_count,
           COUNT(DISTINCT Object_Type) AS type_count
    FROM ObjectCatalog
    WHERE Object_UUID IS NOT NULL
      AND File_Name IS NOT NULL
      -- Native FileMaker UUIDs only (8-4-4-4-12), relationships included. FM-Lab's
      -- synthetic identities (md5 variables/builtins/plugin components, part_/trig_/
      -- paste_ prefixes, rel_ fallback keys of relationships without <UUID>) are
      -- tool-internal and partly global by design - not solution metadata defects.
      AND regexp_matches(Object_UUID, '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')
    GROUP BY Object_UUID
    HAVING COUNT(DISTINCT File_Name) > 1
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'uuid-clone-collision' AS rule_id,
        'warning' AS severity,
        oc.Object_UUID AS nav_uuid,
        oc.Object_Type AS type,
        oc.Object_Name AS name,
        oc.File_Name AS file,
        d.file_count,
        d.occurrences,
        CASE WHEN d.type_count > 1 THEN 'type conflict' ELSE '' END AS type_conflict,
           d.file_count AS _ord_1,
           oc.Object_UUID AS _ord_2,
           oc.File_Name AS _ord_3
    FROM ObjectCatalog oc
    JOIN dup d USING (Object_UUID)
    CROSS JOIN params p
    WHERE (p.file_filter IS NULL OR oc.File_Name = p.file_filter)
      AND (p.scope_csv IS NULL
           OR oc.Object_UUID IN (SELECT unnest(string_split(p.scope_csv, ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1 DESC, u._ord_2, u._ord_3, u) AS row_key
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
