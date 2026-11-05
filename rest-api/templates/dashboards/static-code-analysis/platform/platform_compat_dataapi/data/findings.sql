-- Platform-compatibility check against the Claris tri-state table.
-- Source: reference/fm_spec.duckdb -> step_compat, ATTACHed as 'ref' by the API
-- connection (config/database.js); the fm-test direct path attaches it itself.
-- Severity model: false = 'No' -> error; NULL = 'Partial' -> warning (NEVER
-- 'undocumented'); missing row (6x dataapi/cwp) = no statement -> info.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'platform-dataapi' AS rule_id,
        CASE WHEN c.step_id IS NULL THEN 'info'
             WHEN c.dataapi = false THEN 'error'
             ELSE 'warning' END AS severity,
        s.File_Name AS file_name, s.Script_UUID AS nav_uuid, s.Script_Name AS script_name,
        s.Step_Index + 1 AS step_no, s.Step_UUID AS step_uuid,
        COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS step_name,
        st.url_slug AS doc_slug,
        CASE WHEN c.step_id IS NULL
             THEN COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' has no published compatibility row for FileMaker Data API (genuine gap in the Claris table)'
             WHEN c.dataapi = false
             THEN COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' does not run on FileMaker Data API'
             ELSE COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' is PARTIALLY supported on FileMaker Data API - conditionally supported, see the step notes on its Claris help page'
        END AS message,
           CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END AS _ord_1
    FROM StepsForScripts s
    LEFT JOIN ref.script_steps st ON st.step_id = s.Step_ID
    LEFT JOIN ref.step_compat c ON c.step_id = s.Step_ID
    WHERE s.Is_Enabled
      AND s.Step_ID <> 89  -- "# (comment)"
      AND (c.step_id IS NULL OR c.dataapi = false OR c.dataapi IS NULL)
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1),
           row_number() OVER (ORDER BY u._ord_1, u.file_name, u.script_name, u.step_no, u) AS row_key
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
