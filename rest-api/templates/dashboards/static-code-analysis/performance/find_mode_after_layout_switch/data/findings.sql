-- Go to Layout immediately followed by Enter Find Mode. The Claris-documented
-- cost: switching the layout first materializes the browse context of the
-- target table — the client downloads its first records only for the find that
-- follows to throw them away. Reversing the two steps avoids the download.
--
-- The pair is detected on the sequence of ENABLED, NON-COMMENT steps: comments
-- and blank lines both serialize as step 89 and would otherwise hide real
-- adjacencies. Adjacency is the deliberately sharp condition — with other
-- steps in between, the browse context may be used on purpose.
--
-- Step ids, never step names (names are localized): 6 = Go to Layout,
-- 22 = Enter Find Mode, 89 = comment/blank line. The pause option of Enter
-- Find Mode is read via its numeric option id (16777216) — the type attribute
-- of the Boolean parameter follows the export language and must not be matched.
--
-- Deep link: `step` anchors on the Go to Layout step, `marks` highlights both
-- steps of the pair.
WITH enabled AS (
    SELECT File_Name, Script_UUID, Script_Name, Step_Index, Step_ID, Step_UUID, Step_XML,
           row_number() OVER (PARTITION BY File_Name, Script_UUID ORDER BY Step_Index) AS seq
    FROM StepsForScripts
    WHERE Is_Enabled AND Step_ID <> 89
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'find-mode-after-layout-switch' AS rule_id,
        'warning' AS severity,
        g.File_Name AS file_name,
        g.Script_UUID AS nav_uuid,
        g.Script_Name AS script_name,
        g.Step_Index + 1 AS goto_step,
        e.Step_Index + 1 AS find_mode_step,
        CASE WHEN regexp_matches(e.Step_XML, 'id="16777216" value="True"')
             THEN 'pause' ELSE 'no pause' END AS pause_option,
        g.Step_UUID AS step_uuid,
        g.Step_UUID || ',' || e.Step_UUID AS marks,
        'Go to Layout (step ' || (g.Step_Index + 1) || ') is immediately followed by Enter Find Mode (step '
          || (e.Step_Index + 1) || ') — swap the two steps so the target layout''s records are never downloaded' AS message,
           g.File_Name AS _ord_1,
           g.Script_Name AS _ord_2,
           g.Step_Index AS _ord_3
    FROM enabled g
    JOIN enabled e
      ON g.File_Name = e.File_Name AND g.Script_UUID = e.Script_UUID AND e.seq = g.seq + 1
    WHERE g.Step_ID = 6 AND e.Step_ID = 22
      AND (getvariable('file') IS NULL OR g.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR g.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
