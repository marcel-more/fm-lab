-- @template_type: report
-- @description: Compare scripts by total step count, real comment steps, whitespace-only comments, and the resulting density factors.
-- @params: file (optional, exact File_Name match), min_steps (optional, default 10), limit (optional, default 200)

WITH script_stats AS (
    SELECT
        s.Script_UUID,
        s.Script_Name,
        s.File_Name,
        COUNT(st.Step_UUID)                                           AS total_steps,
        -- Step_ID 89 = comment step (locale-independent; Step_Name is localized).
        COUNT(*) FILTER (WHERE st.Step_ID = 89)                       AS comment_steps,
        COUNT(*) FILTER (WHERE st.Step_ID = 89
                           AND st.Parameters_XML LIKE '%<Comment/>%') AS whitespace_steps
    FROM ScriptCatalog s
    LEFT JOIN StepsForScripts st ON st.Script_UUID = s.Script_UUID AND st.File_Name = s.File_Name
    WHERE (s.Folder_Type IS NULL OR s.Folder_Type = 'False')
      AND NOT s.Is_Separator
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
    GROUP BY ALL
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        Script_UUID                                                                                     AS uuid,
        Script_Name                                                                                     AS name,
        File_Name                                                                                       AS file,
        total_steps,
        comment_steps - whitespace_steps                                                                AS real_comments,
        whitespace_steps,
        ROUND((comment_steps - whitespace_steps) * 100.0
              / NULLIF(total_steps - whitespace_steps, 0), 1)                                           AS comment_pct,
        ROUND(whitespace_steps * 100.0 / NULLIF(total_steps, 0), 1)                                     AS whitespace_pct
    FROM script_stats
    WHERE total_steps >= CAST(COALESCE(getvariable('min_steps'), '10') AS INTEGER)
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.total_steps DESC, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 200), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
