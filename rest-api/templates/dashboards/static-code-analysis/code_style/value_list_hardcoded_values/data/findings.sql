-- Custom_Values is a VARCHAR[] holding one newline-separated blob; split it back
-- into individual values, drop empties, and preview the first five (with an
-- ellipsis when more follow).
WITH vl AS (
    SELECT DISTINCT File_Name, VL_Name, VL_UUID, Custom_Values
    FROM OptionsForValueLists WHERE Source_Type = 'Custom'
),
prepared AS (
    SELECT File_Name, VL_Name, VL_UUID,
        list_filter(string_split(array_to_string(Custom_Values, chr(10)), chr(10)), lambda x: trim(x) <> '') AS vals
    FROM vl
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'value-list-hardcoded-values' AS rule_id, 'info' AS severity,
        File_Name AS file_name, VL_UUID AS nav_uuid, VL_Name AS vl_name,
        array_to_string(list_slice(vals, 1, 5), ', ') || CASE WHEN len(vals) > 5 THEN ', …' ELSE '' END AS values_preview,
        'Value list uses hard-coded custom values' AS message
    FROM prepared
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file_name, u.vl_name, u) AS row_key
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
