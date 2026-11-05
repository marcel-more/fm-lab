-- The comment filter (getvariable('comment'), default 'without') toggles between
-- substantial scripts (>= 10 steps) WITHOUT any real comment and those WITH one —
-- the documented scripts are useful as commenting inspiration.
--
-- A Comment step (Step_ID 89) only counts as documentation when it carries text:
-- FileMaker stores that either as an attribute (`<Comment value="…"/>`) or as
-- element text (`<Comment>…</Comment>`). Empty spacer comments (`<Comment/>`,
-- blank `#` lines) do NOT count — otherwise a script padded with blank comment
-- lines was wrongly flagged as documented (and its comments-only view was blank).
WITH s AS (
    SELECT File_Name, Script_ID,
        any_value(Script_UUID) AS uuid, any_value(Script_Name) AS name,
        COUNT(*) AS step_count,
        COUNT(*) FILTER (WHERE Step_ID = 89
            AND (Step_XML LIKE '%<Comment value="%' OR Step_XML LIKE '%<Comment>%')) AS comment_steps
    FROM StepsForScripts
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
    GROUP BY File_Name, Script_ID
    HAVING COUNT(*) >= 10
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'undocumented-script' AS rule_id, 'info' AS severity,
        File_Name AS file_name, uuid AS nav_uuid, name AS script_name,
        step_count,
        -- Documented scripts open with the ScriptViewer's comments-only view
        -- (comment lines highlighted). Undocumented rows leave nav_mode NULL, so
        -- the openObject action drops the mode param and opens normally.
        CASE WHEN comment_steps > 0 THEN 'comments-only' END AS nav_mode,
        step_count || ' steps, ' || comment_steps || ' comments' AS message
    FROM s
    WHERE (comment_steps > 0) = (COALESCE(getvariable('comment'), 'without') = 'with')
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.step_count DESC, u) AS row_key
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
