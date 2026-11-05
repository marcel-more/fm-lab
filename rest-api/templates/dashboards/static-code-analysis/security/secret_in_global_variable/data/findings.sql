WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'secret-in-global-variable' AS rule_id, 'warning' AS severity,
        CASE WHEN len(v.Files) > 0 THEN v.Files[1] ELSE '—' END AS file_name,
        md5(v.Variable_Scope || '::' || v.Scope_Anchor || '::' || v.Variable_Name) AS nav_uuid,
        v.Display_Name AS variable_name, v.Variable_Scope AS scope,
        v.Set_Count AS set_count, v.Read_Count AS read_count,
           v.Display_Name AS _ord_1
    FROM VariablesCatalog v
    WHERE v.Variable_Scope IN ('global', 'superglobal')
      AND regexp_matches(LOWER(v.Display_Name), '(password|passwort|secret|token|apikey|api_key)')
      AND (getvariable('file') IS NULL OR list_contains(v.Files, getvariable('file')))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1),
           row_number() OVER (ORDER BY u._ord_1, u) AS row_key
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
-- Chip filter: narrows the whole result; its counts (_chip_facets) leave out
-- the search and the chip itself.
filtered AS (
    SELECT * FROM searched
    WHERE (getvariable('variable_scope') IS NULL OR scope = getvariable('variable_scope'))
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
    -- Facets ordered by value, so every request returns the same text.
    (SELECT to_json(map_from_entries(list((scope, n) ORDER BY scope)))
       FROM (SELECT scope, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
