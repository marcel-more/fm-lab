-- Platform-binding inventory (axis b): scripts built FOR FileMaker Server.
-- Neutral by design: findings are properties, not defects — severity is always
-- 'info', the result state stays neutral and never colours a traffic light.
-- Evidence is CONTEXT, not features: there is no server-exclusive step or
-- function, so "built for Server" is derived as "is the target of a
-- Perform Script on Server callsite (steps 164/210)" — the derivation is
-- stated in every message (same convention as the borrowed OData base).
--
-- Since schema 1.20.0 this is fully structured — NO Step_XML regex:
--   resolved — designed targets from XMLStepReferences (per-callsite P2
--              extraction), target identity/file decided by the
--              calls_script edge with Link_Subrole 'on_server' /
--              'on_server_callback' (P4 resolution ladder: declared data
--              sources, prefer-local — resolves declared cross-file targets
--              the old file-internal join had to leave unresolved).
--   external — designed target without a catalog resolution (file not
--              imported); the declared data source name is shown when known.
--   dynamic  — "By name" mode: the target expression is the step's
--              CalculationsCatalog instance (Source_Path 'Step/List'),
--              computed at runtime.
--   empty (unconfigured) callsites have neither row and are skipped.
-- Callsite granularity keeps the enabled-steps convention (Is_Enabled).
WITH callsites AS (
    SELECT x.File_Name AS file_name, x.Script_UUID AS caller_uuid,
           s.Script_Name AS caller_name, s.Step_Index + 1 AS step_no,
           s.Step_UUID AS step_uuid,
           x.Ref_UUID AS target_uuid, x.Ref_Name AS target_name,
           x.Data_Source_Name AS data_source_name
    FROM XMLStepReferences x
    JOIN StepsForScripts s
      ON s.Step_UUID = x.Step_UUID AND s.Script_UUID = x.Script_UUID
     AND s.File_Name = x.File_Name
    WHERE x.Ref_Type = 'script' AND s.Step_ID IN (164, 210) AND s.Is_Enabled
),
resolved AS (
    SELECT cs.*,
           tgt.Object_UUID AS resolved_uuid, tgt.Object_Name AS resolved_name,
           tgt.File_Name AS resolved_file
    FROM callsites cs
    LEFT JOIN (SELECT DISTINCT Source_UUID, Source_File, Target_UUID, Target_File
               FROM ObjectLinks
               WHERE Link_Role = 'calls_script'
                 AND Link_Subrole IN ('on_server', 'on_server_callback')) e
      ON e.Source_UUID = cs.caller_uuid AND e.Source_File = cs.file_name
     AND e.Target_UUID = cs.target_uuid
    LEFT JOIN ObjectCatalog tgt
      ON tgt.Object_UUID = e.Target_UUID AND tgt.File_Name = e.Target_File
     AND tgt.Object_Type = 'Script'
),
dynamic AS (
    SELECT c.File_Name AS file_name, s.Script_UUID AS caller_uuid,
           s.Script_Name AS caller_name, s.Step_Index + 1 AS step_no,
           c.Owner_UUID AS step_uuid, trim(COALESCE(c.Formula_Text, c.Display_Text)) AS dyn_expr
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Step_ID IN (164, 210) AND s.Is_Enabled AND c.Source_Path = 'Step/List'
),
targets AS (
    -- One row per resolved target script (usage_count = number of callsites)…
    SELECT resolved_uuid AS nav_uuid, resolved_name AS script_name,
           resolved_file AS file_name, count(*) AS usage_count,
           'resolved' AS target_kind
    FROM resolved
    WHERE resolved_uuid IS NOT NULL
    GROUP BY resolved_uuid, resolved_name, resolved_file
    UNION ALL
    -- …one explicit row per unresolved (external / not-in-catalog) target…
    SELECT CAST(NULL AS VARCHAR),
           COALESCE(target_name, '(unknown script)')
             || COALESCE(' @ ' || data_source_name, ''),
           file_name, count(*), 'external'
    FROM resolved
    WHERE resolved_uuid IS NULL
    GROUP BY 2, file_name
    UNION ALL
    -- …and one row per distinct by-name expression (runtime-computed target).
    SELECT CAST(NULL AS VARCHAR), COALESCE(dyn_expr, '(calculated name)'),
           file_name, count(*), 'dynamic'
    FROM dynamic
    GROUP BY COALESCE(dyn_expr, '(calculated name)'), file_name
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'platform-specific-server' AS rule_id,
        'info' AS severity,
        file_name, nav_uuid, script_name,
        'contextual' AS binding,
        'context' AS evidence_kind, 'contextual' AS signal,
        CASE target_kind
             WHEN 'resolved' THEN 'Perform Script on Server target'
             WHEN 'external' THEN '<unresolved external target>'
             ELSE '<dynamic target (by name)>' END AS feature,
        CAST(NULL AS INTEGER) AS step_no, CAST(NULL AS VARCHAR) AS step_uuid,
        usage_count,
        CASE target_kind
             WHEN 'resolved'
             THEN script_name || ' is called via Perform Script on Server (' || usage_count || ' callsite' || CASE WHEN usage_count > 1 THEN 's' ELSE '' END || ') — built for server-side execution'
             WHEN 'external'
             THEN '"' || script_name || '" is a Perform Script on Server target outside the imported catalog (' || usage_count || ' callsite' || CASE WHEN usage_count > 1 THEN 's' ELSE '' END || ') — external file target, deliberately not resolved'
             ELSE 'Perform Script on Server resolves its target by calculated name — ' || script_name || ' (' || usage_count || ' callsite' || CASE WHEN usage_count > 1 THEN 's' ELSE '' END || ') — server-bound execution, target not statically resolvable'
        END AS message,
        CAST(NULL AS VARCHAR) AS doc_slug,
           CASE target_kind WHEN 'resolved' THEN 0 WHEN 'external' THEN 1 ELSE 2 END AS _ord_1
    FROM targets
    WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1),
           row_number() OVER (ORDER BY u._ord_1, u.file_name, u.script_name, u) AS row_key
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
