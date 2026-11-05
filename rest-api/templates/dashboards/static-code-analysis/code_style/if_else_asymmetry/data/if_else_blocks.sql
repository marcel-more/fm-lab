-- @template_type: report
-- @description: Scripts containing If/Else blocks where the If branch is long and the Else branch is short.
-- @params: file (optional), min_if_len (optional, default 10), max_else_len (optional, default 2), limit (optional, default 50)

-- Control-flow gating is locale-independent via Step_ID
-- (68 = If, 69 = Else, 70 = End If); Step_Name is localized in SaXML exports.
WITH steps_with_depth AS (
    SELECT
        Script_UUID,
        Script_Name,
        File_Name,
        Step_Index,
        Step_ID,
        SUM(CASE WHEN Step_ID = 68 THEN 1
                 WHEN Step_ID = 70 THEN -1
                 ELSE 0 END)
            OVER (PARTITION BY Script_UUID, File_Name
                  ORDER BY Step_Index
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS depth_after
    FROM StepsForScripts
),
if_nodes AS (
    SELECT
        Script_UUID, Script_Name, File_Name,
        Step_Index AS if_idx,
        depth_after AS if_depth
    FROM steps_with_depth
    WHERE Step_ID = 68
),
if_with_end AS (
    SELECT
        i.*,
        (SELECT MIN(e.Step_Index) FROM steps_with_depth e
           WHERE e.Script_UUID = i.Script_UUID AND e.File_Name = i.File_Name
             AND e.Step_Index > i.if_idx
             AND e.Step_ID = 70
             AND e.depth_after = i.if_depth - 1) AS end_idx
    FROM if_nodes i
),
matched AS (
    SELECT
        b.*,
        (SELECT MIN(s.Step_Index) FROM steps_with_depth s
           WHERE s.Script_UUID = b.Script_UUID AND s.File_Name = b.File_Name
             AND s.Step_Index > b.if_idx
             AND s.Step_Index < b.end_idx
             AND s.Step_ID = 69
             AND s.depth_after = b.if_depth) AS else_idx
    FROM if_with_end b
    WHERE b.end_idx IS NOT NULL
),
sized AS (
    SELECT
        m.*,
        (SELECT COUNT(*) FROM StepsForScripts t
           WHERE t.Script_UUID = m.Script_UUID AND t.File_Name = m.File_Name
             AND t.Step_Index > m.if_idx
             AND t.Step_Index < m.else_idx) AS if_len,
        (SELECT COUNT(*) FROM StepsForScripts t
           WHERE t.Script_UUID = m.Script_UUID AND t.File_Name = m.File_Name
             AND t.Step_Index > m.else_idx
             AND t.Step_Index < m.end_idx) AS else_len
    FROM matched m
    WHERE m.else_idx IS NOT NULL
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        s.Script_UUID                                           AS uuid,
        s.Script_Name                                           AS name,
        s.File_Name                                             AS file,
        s.if_idx                                                AS if_pos,
        s.if_len                                                AS if_len,
        s.else_len                                              AS else_len,
        ROUND(s.if_len * 1.0 / (s.else_len + 1), 1)             AS asymmetry_score
    FROM sized s
    WHERE s.if_len  >= CAST(COALESCE(getvariable('min_if_len'),  '10') AS INTEGER)
      AND s.else_len <= CAST(COALESCE(getvariable('max_else_len'), '2') AS INTEGER)
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.asymmetry_score DESC, u.if_len DESC, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 50), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
