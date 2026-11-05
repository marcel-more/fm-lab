-- Linux server readiness: everything in scope that works on macOS/Windows
-- FileMaker Server but NOT (or not reliably) on a Linux-based server - the
-- inverse of an OS binding inventory. Linux has practically no exclusive
-- features; its real question is "what breaks when I move my server to
-- Linux?". Three signal sources, one row per script x feature:
--   plugin   - functions with Server=Yes whose OS flags miss Linux (verbatim
--              vendor flags folded through the curated OS map; host-OS set
--              from the reference host matrix). Includes one-level
--              custom-function wrappers.
--   function - Claris calculation functions the documentation marks as not
--              supported on Linux hosts (source-true inverse statements,
--              e.g. "returns an empty string in FileMaker WebDirect when
--              evaluated by a Linux host"). Includes CF-transitive usage.
--   step     - Claris script steps with a Linux-unsupported statement
--              (currently none documented - the branch exists so future
--              curation flows through without SQL changes).
-- Steps/functions that do not run under ANY server engine are deliberately
-- absent - they fail on every server OS and belong to the server
-- compatibility test, not to the Linux delta.
WITH RECURSIVE plugin_calls AS (
    SELECT src.Object_UUID AS nav_uuid, src.Object_Name AS script_name,
           src.File_Name AS file_name,
           CAST(NULL AS VARCHAR) AS via_custom_function,
           tgt.Object_Name AS target_name
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND src.Object_Type = 'Script'
      AND tgt.Object_Type = 'PluginFunction'
      AND tgt.Object_Name LIKE '%::%'
    UNION ALL
    SELECT s.Object_UUID, s.Object_Name, s.File_Name, cf.Object_Name, tgt.Object_Name
    FROM ObjectLinks sc
    JOIN ObjectCatalog s   ON sc.Source_UUID = s.Object_UUID AND s.Object_Type = 'Script'
    JOIN ObjectCatalog cf  ON sc.Target_UUID = cf.Object_UUID AND cf.Object_Type = 'CustomFunction'
    JOIN ObjectLinks pl    ON pl.Source_UUID = cf.Object_UUID AND pl.Link_Role = 'calls_pluginfunction'
    JOIN ObjectCatalog tgt ON pl.Target_UUID = tgt.Object_UUID AND tgt.Object_Type = 'PluginFunction'
    WHERE sc.Link_Role = 'calls_customfunction'
      AND tgt.Object_Name LIKE '%::%'
),
no_linux_plugins AS (
    SELECT pf.plugin_id, pf.function_name,
           string_agg(so.os, ', ' ORDER BY so.os)
               FILTER (WHERE COALESCE(osf.supported, false)) AS runs_on
    FROM plugref.plugin_function_platforms pf
    JOIN (SELECT os FROM ref.runtime_os_matrix WHERE fm_env = 'server' AND supported) so ON true
    LEFT JOIN plugref.plugin_os_map m
      ON m.plugin_id = pf.plugin_id AND m.os = so.os
    LEFT JOIN plugref.plugin_function_platforms osf
      ON osf.plugin_id = pf.plugin_id AND osf.function_name = pf.function_name
     AND osf.platform = m.platform
    WHERE pf.platform = 'server' AND pf.supported
    GROUP BY pf.plugin_id, pf.function_name
    HAVING NOT bool_and(COALESCE(osf.supported, false))
       AND NOT bool_or(so.os = 'linux' AND COALESCE(osf.supported, false))
),
plugin_evidence AS (
    SELECT pc.nav_uuid, pc.script_name, pc.file_name,
           'plugin' AS source,
           COALESCE(f.function_name, af.function_name) AS feature,
           nl.runs_on,
           'Runs under the server script engine, but only on ' || nl.runs_on
             || ' servers - fails on Linux-based FileMaker Server'
             || CASE WHEN pc.via_custom_function IS NOT NULL
                     THEN ' (called via custom function "' || pc.via_custom_function || '")' ELSE '' END
             AS message
    FROM plugin_calls pc
    JOIN plugref.plugins p
      ON lower(p.detect_prefix) = lower(split_part(pc.target_name, ':', 1))
    LEFT JOIN plugref.plugin_functions f
      ON f.plugin_id = p.plugin_id
     AND lower(f.function_name) = lower(regexp_replace(pc.target_name, '^.*::', ''))
    LEFT JOIN plugref.plugin_function_aliases af
      ON af.plugin_id = p.plugin_id
     AND lower(af.alias) = lower(regexp_replace(pc.target_name, '^.*::', ''))
    JOIN no_linux_plugins nl
      ON nl.plugin_id = p.plugin_id
     AND nl.function_name = COALESCE(f.function_name, af.function_name)
    -- The whole row breaks the remaining ties: every request picks the same row.
    QUALIFY row_number() OVER (
        PARTITION BY pc.nav_uuid, nl.function_name
        ORDER BY (pc.via_custom_function IS NOT NULL), pc.via_custom_function, pc, nl) = 1
),
linux_unsupported_fns AS (
    SELECT function_id, note
    FROM ref.function_os_affinity
    WHERE os = 'linux' AND affinity = 'unsupported'
),
fn_seeds AS (
    SELECT fn.Object_UUID, MIN(fl.function_id) AS function_id
    FROM ObjectCatalog fn
    JOIN ref.function_name_lookup fl
      ON replace(lower(fl.lookup_name), ' ', '') = replace(lower(fn.Object_Name), ' ', '')
      OR replace(lower(fl.lookup_name), ' ', '')
         = replace(lower(regexp_extract(fn.Object_Name, '\(\s*(.*?)\s*\)\s*$', 1)), ' ', '')
    JOIN linux_unsupported_fns a ON a.function_id = fl.function_id
    WHERE fn.Object_Type = 'BuiltinFunction'
    GROUP BY fn.Object_UUID
),
fn_closure(cf_uuid, function_id, path) AS (
    SELECT ol.Source_UUID, sf.function_id, [ol.Source_UUID]
    FROM ObjectLinks ol
    JOIN fn_seeds sf ON ol.Target_UUID = sf.Object_UUID
    WHERE ol.Link_Role = 'calls_function' AND ol.Source_Type = 'CustomFunction'
    UNION ALL
    SELECT ol.Source_UUID, c.function_id, list_append(c.path, ol.Source_UUID)
    FROM fn_closure c
    JOIN ObjectLinks ol ON ol.Target_UUID = c.cf_uuid
    WHERE ol.Link_Role = 'calls_customfunction' AND ol.Source_Type = 'CustomFunction'
      AND NOT list_contains(c.path, ol.Source_UUID)
),
fn_evidence AS (
    SELECT src.Object_UUID AS nav_uuid, src.Object_Name AS script_name,
           src.File_Name AS file_name,
           'function' AS source,
           COALESCE(f.canonical_name, 'Function ' || sf.function_id) AS feature,
           'macos, windows' AS runs_on,
           'Not supported on Linux hosts - Claris documents an empty result when evaluated by a Linux server (see the function''s help page)' AS message
    FROM ObjectLinks ol
    JOIN fn_seeds sf ON ol.Target_UUID = sf.Object_UUID
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    LEFT JOIN ref.functions f ON f.function_id = sf.function_id
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    UNION ALL
    SELECT src.Object_UUID, src.Object_Name, src.File_Name,
           'function',
           COALESCE(f.canonical_name, 'Function ' || cc.function_id),
           'macos, windows',
           'Not supported on Linux hosts - Claris documents an empty result when evaluated by a Linux server (reached through a custom function)'
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM fn_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    LEFT JOIN ref.functions f ON f.function_id = cc.function_id
    WHERE ol.Link_Role = 'calls_customfunction' AND src.Object_Type = 'Script'
),
step_evidence AS (
    SELECT s.Script_UUID AS nav_uuid, s.Script_Name AS script_name,
           s.File_Name AS file_name,
           'step' AS source,
           COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS feature,
           'macos, windows' AS runs_on,
           'Claris documents this step as not supported on Linux' AS message
    FROM StepsForScripts s
    JOIN ref.step_os_affinity a
      ON a.step_id = s.Step_ID AND a.os = 'linux' AND a.affinity = 'unsupported'
    LEFT JOIN ref.script_steps st ON st.step_id = s.Step_ID
    WHERE s.Is_Enabled
),
evidence AS (
    SELECT * FROM plugin_evidence
    UNION ALL SELECT DISTINCT * FROM fn_evidence
    UNION ALL SELECT * FROM step_evidence
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT nav_uuid, file_name AS file, script_name AS name,
        source, feature, runs_on, message
    FROM evidence
    WHERE (getvariable('file') IS NULL OR getvariable('file') = '' OR file_name = getvariable('file'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file, u.name, u.feature, u) AS row_key
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
