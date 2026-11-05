WITH auto_exit AS (
    SELECT DISTINCT t.File_Name, t.Script_ID
    FROM v_script_block_tree t
    JOIN StepsForScripts s ON s.Step_UUID = t.Step_UUID AND s.File_Name = t.File_Name
    WHERE t.Step_ID IN (16, 99)
      AND t.loop_depth_before >= 1
      AND regexp_matches(s.Step_XML, 'value="[34]">\s*<Boolean[^>]*value="True"')
),
loops AS (
    SELECT File_Name, Script_ID,
        any_value(Script_UUID) AS nav_uuid,
        any_value(Script_Name) AS script_name,
        COUNT(*) FILTER (WHERE Step_ID = 71) AS loop_count,
        COUNT(*) FILTER (WHERE Step_ID = 72) AS exit_if_count,
        MIN(Step_Index) FILTER (WHERE Step_ID = 71) + 1 AS step_no,
        arg_min(Step_UUID, Step_Index) FILTER (WHERE Step_ID = 71) AS step_uuid
    FROM v_script_block_tree
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY File_Name, Script_ID
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'loop-without-exit-loop-if' AS rule_id, 'info' AS severity,
        l.File_Name AS file_name, l.nav_uuid, l.script_name,
        l.step_no, l.step_uuid,
        l.loop_count,
        'Loop(s) with no Exit Loop If and no auto-exit Go to Record/Portal Row' AS message
    FROM loops l
    LEFT JOIN auto_exit a ON a.File_Name = l.File_Name AND a.Script_ID = l.Script_ID
    WHERE l.loop_count > 0 AND l.exit_if_count = 0 AND a.Script_ID IS NULL
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
