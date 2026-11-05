-- Window opener (New Window, or Go to Related Record with its "New window" option —
-- StepsForScripts.Opens_Window, derived at import) with NO enabled Close Window
-- later in the same script. Heuristic by design: a callee script may close the
-- window, and a Close Window that exists in some branch does not guarantee every
-- exit path closes it. Numeric-ID join includes File_Name (FM IDs are per-file).
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'window-opened-without-close' AS rule_id, 'warning' AS severity,
        o.File_Name AS file_name, o.Script_UUID AS nav_uuid, o.Script_Name AS script_name,
        o.Step_Index + 1 AS step_no, o.Step_UUID AS step_uuid,
        o.Step_Name AS opener,
        o.Step_Name || ' at step ' || (o.Step_Index + 1) || ' opens a window, but no Close Window follows in this script (a callee may close it — verify)' AS message
    FROM StepsForScripts o
    WHERE o.Opens_Window AND o.Is_Enabled
      AND NOT EXISTS (
          SELECT 1 FROM StepsForScripts c
          WHERE c.File_Name = o.File_Name AND c.Script_ID = o.Script_ID
            AND c.Step_ID = 121 AND c.Is_Enabled AND c.Step_Index > o.Step_Index)
      AND (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR o.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
