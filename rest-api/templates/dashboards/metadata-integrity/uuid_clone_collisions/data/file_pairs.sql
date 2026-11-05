-- @template_type: report
-- @description: File pairs sharing native UUIDs (which file is a clone of which), with overlap percentages relative to each file's native-UUID population. Logic adopted from quality check T4-C1.
-- @params: file (optional), scope_uuids (optional), limit (optional, default 100)
WITH params AS (
    SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '') AS file_filter,
           NULLIF(CAST(getvariable('scope_uuids') AS VARCHAR), '') AS scope_csv
),
native AS (
    SELECT Object_UUID, File_Name
    FROM ObjectCatalog
    CROSS JOIN params p
    WHERE Object_UUID IS NOT NULL
      AND File_Name IS NOT NULL
      -- Native FileMaker UUIDs only (8-4-4-4-12), same base population as data/findings.sql.
      AND regexp_matches(Object_UUID, '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')
      AND (p.scope_csv IS NULL
           OR Object_UUID IN (SELECT unnest(string_split(p.scope_csv, ','))))
),
pairs AS (
    SELECT a.File_Name AS file_a, b.File_Name AS file_b, COUNT(*) AS shared_uuids
    FROM native a
    JOIN native b
      ON a.Object_UUID = b.Object_UUID AND a.File_Name < b.File_Name
    GROUP BY 1, 2
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT file_a, file_b, shared_uuids,
           ROUND(100.0 * shared_uuids /
                 (SELECT COUNT(*) FROM native WHERE File_Name = file_a), 1) AS pct_of_a,
           ROUND(100.0 * shared_uuids /
                 (SELECT COUNT(*) FROM native WHERE File_Name = file_b), 1) AS pct_of_b
    FROM pairs
    CROSS JOIN params p
    WHERE shared_uuids > 0
      AND (p.file_filter IS NULL OR file_a = p.file_filter OR file_b = p.file_filter)
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.shared_uuids DESC, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 100), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
