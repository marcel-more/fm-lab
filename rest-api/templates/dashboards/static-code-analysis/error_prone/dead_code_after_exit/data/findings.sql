WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'dead-code-after-exit' AS rule_id, 'warning' AS severity,
        File_Name AS file_name, Script_UUID AS nav_uuid, Script_Name AS script_name,
        dead_index + 1 AS step_no, dead_uuid AS step_uuid, dead_name AS dead_step,
        'Step ' || (dead_index + 1) || ' (' || dead_name || ') is unreachable — it follows unconditional ' || term_name || ' at step ' || (Step_Index + 1) AS message
    FROM (
        -- Comments (Step_ID 89) are skipped so that `Exit Script; # note; Close Window`
        -- still reports the executable follower. Terminators: 103 Exit Script, 90 Halt Script.
        -- Followers 69 Else / 70 End If / 73 End Loop / 125 Else If continue or close the
        -- branch and are reachable via the untaken path; anything else is dead.
        SELECT File_Name, Script_ID, Script_UUID, Script_Name, Step_Index, Step_ID,
               Step_Name AS term_name,
               lead(Step_ID)    OVER w AS dead_id,
               lead(Step_UUID)  OVER w AS dead_uuid,
               lead(Step_Name)  OVER w AS dead_name,
               lead(Step_Index) OVER w AS dead_index
        FROM v_script_block_tree
        WHERE Is_Enabled AND Step_ID <> 89
        WINDOW w AS (PARTITION BY File_Name, Script_ID ORDER BY Step_Index)
    ) t
    WHERE Step_ID IN (103, 90)
      AND dead_id IS NOT NULL
      AND dead_id NOT IN (69, 70, 73, 125)
      AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file_name, u.script_name, u.step_no, u) AS row_key
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
