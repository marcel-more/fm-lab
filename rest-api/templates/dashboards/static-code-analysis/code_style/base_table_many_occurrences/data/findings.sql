-- Only base tables that resolve to a real, local BaseTable object are counted.
-- TableOccurrenceCatalog.BT_UUID is NULL for occurrences whose base table lives
-- in an external, non-imported file (these were previously merged into one
-- meaningless NULL-group row) and points to unresolvable UUIDs for cross-file
-- references into files outside the corpus (previously a broken navigation
-- link). The JOIN to ObjectCatalog restricts to resolvable local base tables,
-- so every nav_uuid navigates correctly.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'base-table-many-occurrences' AS rule_id, 'info' AS severity,
        any_value(o.File_Name) AS file_name, to2.BT_UUID AS nav_uuid, any_value(o.Object_Name) AS base_table,
        COUNT(*) AS occurrence_count,
        COUNT(*) || ' occurrences' AS message
    FROM TableOccurrenceCatalog to2
    JOIN ObjectCatalog o ON o.Object_UUID = to2.BT_UUID AND o.Object_Type = 'BaseTable'
        -- Local occurrences pair with the same-file base table; external ones (DS set)
        -- legitimately point into another file, where the bare UUID is all we have.
        AND (to2.DS_UUID IS NOT NULL OR o.File_Name = to2.File_Name)
    WHERE (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
    GROUP BY to2.BT_UUID, o.File_Name
    HAVING COUNT(*) > 8
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.occurrence_count DESC, u) AS row_key
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
