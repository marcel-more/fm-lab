-- OData platform check. Claris publishes NO per-step OData column - the step
-- base is BORROWED from the 'server' column (OData runs scripts as server-side
-- scripts; the derivation is stated in every message), plus the OData rules
-- that ARE derivable from the catalog: script naming (no leading digit, no
-- special characters) and Commit Records/Requests at the end of data-changing
-- scripts. Never invent an 'odata' column.
-- Source: reference/fm_spec.duckdb -> step_compat/script_steps via ATTACH 'ref'.
-- The three rule branches are UNIONed; DuckDB only allows plain column
-- references in a set operation's ORDER BY, so the union lives in a FROM
-- clause and the severity ranking orders the outer SELECT.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT * EXCLUDE (row_key),
           CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END AS _ord_1,
           file_name AS _ord_2,
           script_name AS _ord_3,
           step_no AS _ord_4 FROM (
    SELECT 'platform-odata' AS rule_id,
        CASE WHEN c.step_id IS NULL THEN 'info'
             WHEN c.server = false THEN 'error'
             ELSE 'warning' END AS severity,
        s.File_Name AS file_name, s.Script_UUID AS nav_uuid, s.Script_Name AS script_name,
        s.Step_Index + 1 AS step_no, s.Step_UUID AS step_uuid,
        COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS step_name,
        st.url_slug AS doc_slug,
        CASE WHEN c.step_id IS NULL
             THEN COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' has no published compatibility row (borrowed Server base - OData runs scripts server-side)'
             WHEN c.server = false
             THEN COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' does not run server-side (borrowed Server base - OData runs scripts as server-side scripts)'
             ELSE COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' is PARTIALLY supported server-side (borrowed Server base) - see the step notes on its Claris help page'
        END AS message,
        row_number() OVER (ORDER BY s.File_Name, s.Script_Name, s.Step_Index) AS row_key
    FROM StepsForScripts s
    LEFT JOIN ref.script_steps st ON st.step_id = s.Step_ID
    LEFT JOIN ref.step_compat c ON c.step_id = s.Step_ID
    WHERE s.Is_Enabled
      AND s.Step_ID <> 89  -- "# (comment)"
      AND (c.step_id IS NULL OR c.server = false OR c.server IS NULL)
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))

    UNION ALL

    SELECT 'platform-odata' AS rule_id, 'warning' AS severity,
        s.File_Name AS file_name, s.Script_UUID AS nav_uuid, any_value(s.Script_Name) AS script_name,
        NULL AS step_no, NULL AS step_uuid,
        'Script name' AS step_name, NULL AS doc_slug,
        CASE WHEN regexp_matches(any_value(s.Script_Name), '^[0-9]')
             THEN 'Script name starts with a digit - not callable via OData naming rules'
             ELSE 'Script name contains special characters - not callable via OData naming rules'
        END AS message,
        1000000 + row_number() OVER (ORDER BY s.File_Name, s.Script_UUID) AS row_key
    FROM StepsForScripts s
    WHERE (regexp_matches(s.Script_Name, '^[0-9]') OR regexp_matches(s.Script_Name, '[^A-Za-z0-9_ \-]'))
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY s.File_Name, s.Script_UUID

    UNION ALL

    SELECT 'platform-odata' AS rule_id, 'info' AS severity,
        g.File_Name AS file_name, g.Script_UUID AS nav_uuid, g.Script_Name AS script_name,
        g.last_step_no AS step_no, g.last_step_uuid AS step_uuid,
        'Commit Records/Requests' AS step_name, 'commit-records-requests' AS doc_slug,
        'Data-changing script does not end with Commit Records/Requests - Claris recommends committing at the end of scripts run via OData' AS message,
        2000000 + row_number() OVER (ORDER BY g.File_Name, g.Script_Name) AS row_key
    FROM (
        SELECT s.File_Name, s.Script_UUID, any_value(s.Script_Name) AS Script_Name,
               arg_max(s.Step_ID, s.Step_Index) AS last_step_id,
               MAX(s.Step_Index) + 1 AS last_step_no,
               arg_max(s.Step_UUID, s.Step_Index) AS last_step_uuid,
               COUNT(*) FILTER (WHERE s.Step_ID IN (7, 8, 9, 10, 35, 51, 76, 91, 147)) AS dml_steps
        FROM StepsForScripts s
        WHERE s.Is_Enabled AND s.Step_ID <> 89  -- "# (comment)"
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
        GROUP BY s.File_Name, s.Script_UUID
    ) g
    WHERE g.dml_steps > 0 AND g.last_step_id <> 75  -- 75 = "Commit Records/Requests"
    )
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u) AS row_key
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
