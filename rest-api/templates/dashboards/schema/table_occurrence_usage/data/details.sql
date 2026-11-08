-- Every usage of the selected table occurrence (params to_uuid + to_file), grouped by
-- category. A row opens the using object; layout objects open their layout.
-- Server paging (manifest: details_page / details_q / details_sort → page / q / sort).
WITH
unkeyed AS MATERIALIZED (
    SELECT
        u.Category      AS category,
        u.Role          AS role,
        u.User_Type     AS user_type,
        u.User_Name     AS user_name,
        u.Container_Name AS container,
        u.User_File     AS user_file,
        u.Ref_Count     AS refs,
        COALESCE(u.Container_UUID, u.User_UUID) AS nav_uuid,
        COALESCE(u.Container_Type, u.User_Type) AS nav_type,
        u.Category      AS _ord_1,
        u.User_Name     AS _ord_2
    FROM v_table_occurrence_usage u
    WHERE u.TO_UUID = NULLIF(CAST(getvariable('to_uuid') AS VARCHAR), '')
      AND u.File_Name = NULLIF(CAST(getvariable('to_file') AS VARCHAR), '')
),
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 100), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
