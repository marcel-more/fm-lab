-- Only enabled steps execute: a disabled If or End If left over from editing
-- does not change the nesting FileMaker runs, so the balance and the running
-- depth are computed over the enabled steps alone (v_script_block_tree itself
-- counts every step — its depths drive the indentation of the script view).
WITH active AS (
    SELECT File_Name, Script_ID, Script_UUID, Script_Name,
        CASE WHEN Is_Enabled IS NOT FALSE THEN if_delta ELSE 0 END AS active_if_delta,
        SUM(CASE WHEN Is_Enabled IS NOT FALSE THEN if_delta ELSE 0 END)
            OVER (PARTITION BY File_Name, Script_ID ORDER BY Step_Index
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS active_running_depth
    FROM v_script_block_tree
),
bal AS (
    SELECT File_Name, Script_ID,
        MIN(Script_UUID) AS Script_UUID, MIN(Script_Name) AS Script_Name,
        CAST(SUM(active_if_delta) AS INTEGER) AS net_if_balance,
        CAST(MIN(active_running_depth) AS INTEGER) AS worst_running_depth
    FROM active GROUP BY File_Name, Script_ID
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'unbalanced-if-block' AS rule_id, 'error' AS severity,
        File_Name AS file_name, Script_UUID AS nav_uuid, Script_Name AS script_name,
        'If/End-If imbalance (' || net_if_balance || ') — structurally broken block nesting' AS message
    FROM bal
    WHERE (net_if_balance <> 0 OR worst_running_depth < 0) AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file_name, u.script_name, u) AS row_key
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
