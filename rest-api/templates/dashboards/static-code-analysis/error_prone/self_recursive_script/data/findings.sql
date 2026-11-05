WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'self-recursive-script' AS rule_id, 'info' AS severity,
        oc.File_Name AS file_name, oc.Object_UUID AS nav_uuid, oc.Object_Name AS script_name,
        'Script calls itself (recursion)' AS message,
           oc.File_Name AS _ord_1,
           oc.Object_Name AS _ord_2
    FROM ObjectLinks ol
    JOIN ObjectCatalog oc ON oc.Object_UUID = ol.Source_UUID AND oc.File_Name = ol.Source_File AND oc.Object_Type = 'Script'
    WHERE ol.Link_Role = 'calls_script' AND ol.Source_UUID = ol.Target_UUID AND ol.Source_File IS NOT DISTINCT FROM ol.Target_File AND (getvariable('file') IS NULL OR oc.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR oc.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY oc.File_Name, oc.Object_UUID, oc.Object_Name
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u) AS row_key
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
