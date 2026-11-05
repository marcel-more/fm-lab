-- The scope filter (getvariable('scope'), default 'active') hides disabled
-- (inactive) Show Custom Dialog steps: a disabled step never runs, so it can't
-- trap the user in per-iteration prompts and is a false positive here. 'all'
-- shows every match, including disabled ones. Is_Enabled comes from
-- StepsForScripts (Step_UUID is 1:1 with v_script_block_tree).
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'show-dialog-in-loop' AS rule_id, 'warning' AS severity,
        t.File_Name AS file_name, t.Script_UUID AS nav_uuid, t.Script_Name AS script_name,
        t.Step_Index + 1 AS step_index, t.Step_UUID AS step_uuid,
        CASE WHEN s.Is_Enabled THEN 'active' ELSE 'inactive' END AS status,
        'Show Custom Dialog inside loop (depth ' || t.loop_depth_before || ') at step ' || (t.Step_Index + 1) AS message,
           t.File_Name AS _ord_1,
           t.Script_Name AS _ord_2,
           t.Step_Index AS _ord_3
    FROM v_script_block_tree t
    JOIN StepsForScripts s ON s.Step_UUID = t.Step_UUID AND s.File_Name = t.File_Name
    WHERE t.Step_ID = 87 AND t.loop_depth_before >= 1
      AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR t.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
      AND (COALESCE(getvariable('scope'), 'active') = 'all' OR s.Is_Enabled)
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u) AS row_key
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
