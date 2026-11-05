-- Scripts with several navigation steps (Go to Layout = 6, Go to Related
-- Record = 74) and no Freeze Window (79). Every hop repaints the screen and
-- evaluates the intermediate layout; one Freeze Window before the sequence
-- suppresses all of it. Threshold-based heuristic, severity info.
--
-- called_via_psos: the script's UUID appears in a ScriptReference of an
-- enabled Perform Script on Server step (164/210). Context column, not an
-- exclusion — a script can be called both client- and server-side. The UUID
-- is extracted from the attribute form (UUID="…"), which does not collide
-- with the step's own <UUID> element. Same-file references are reliable;
-- cross-file UUIDs can be stale (documented limitation of the context column).
--
-- Deep link: `step` anchors on the first navigation step, `marks` highlights
-- the first 25 (list_slice, because the preprocessor eats [1:25]).
WITH nav AS (
    SELECT File_Name, Script_UUID, any_value(Script_Name) AS script_name,
           CAST(count(*) FILTER (WHERE Step_ID IN (6, 74)) AS INTEGER) AS nav_steps,
           count(*) FILTER (WHERE Step_ID = 79) AS freeze_steps,
           list(Step_UUID ORDER BY Step_Index) FILTER (WHERE Step_ID IN (6, 74)) AS nav_uuids
    FROM StepsForScripts
    WHERE Is_Enabled
    GROUP BY 1, 2
),
psos_targets AS (
    SELECT DISTINCT unnest(regexp_extract_all(Step_XML, 'UUID="([0-9A-Fa-f-]+)"', 1)) AS target_uuid
    FROM StepsForScripts
    WHERE Step_ID IN (164, 210) AND Is_Enabled
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'multi-navigation-without-freeze' AS rule_id,
        'info' AS severity,
        n.File_Name AS file_name,
        n.Script_UUID AS nav_uuid,
        n.script_name AS script_name,
        n.nav_steps,
        CASE WHEN p.target_uuid IS NOT NULL THEN 'yes' ELSE '' END AS called_via_psos,
        n.nav_uuids[1] AS step_uuid,
        array_to_string(list_slice(n.nav_uuids, 1, 25), ',') AS marks,
        'Script performs ' || n.nav_steps || ' navigation steps without Freeze Window'
          || CASE WHEN p.target_uuid IS NOT NULL THEN ' (also called via Perform Script on Server)' ELSE '' END AS message,
           n.nav_steps AS _ord_1,
           n.File_Name AS _ord_2,
           n.script_name AS _ord_3
    FROM nav n
    LEFT JOIN psos_targets p ON p.target_uuid = n.Script_UUID
    WHERE n.freeze_steps = 0
      AND n.nav_steps >= CAST(COALESCE(getvariable('min_nav'), '3') AS INTEGER)
      AND (getvariable('file') IS NULL OR n.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR n.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1 DESC, u._ord_2, u._ord_3, u) AS row_key
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
