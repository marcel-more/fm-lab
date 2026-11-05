-- Hand-maintained aggregate over the same evidence as data/findings.sql -
-- keep the CTEs and filters in sync. Counts the Linux delta: scripts and
-- features that work on macOS/Windows FileMaker Server but not on a
-- Linux-based server.
WITH RECURSIVE plugin_calls AS (
    SELECT src.Object_UUID AS nav_uuid, src.File_Name AS file_name,
           tgt.Object_Name AS target_name
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND src.Object_Type = 'Script'
      AND tgt.Object_Type = 'PluginFunction'
      AND tgt.Object_Name LIKE '%::%'
    UNION ALL
    SELECT s.Object_UUID, s.File_Name, tgt.Object_Name
    FROM ObjectLinks sc
    JOIN ObjectCatalog s   ON sc.Source_UUID = s.Object_UUID AND s.Object_Type = 'Script'
    JOIN ObjectCatalog cf  ON sc.Target_UUID = cf.Object_UUID AND cf.Object_Type = 'CustomFunction'
    JOIN ObjectLinks pl    ON pl.Source_UUID = cf.Object_UUID AND pl.Link_Role = 'calls_pluginfunction'
    JOIN ObjectCatalog tgt ON pl.Target_UUID = tgt.Object_UUID AND tgt.Object_Type = 'PluginFunction'
    WHERE sc.Link_Role = 'calls_customfunction'
      AND tgt.Object_Name LIKE '%::%'
),
no_linux_plugins AS (
    SELECT pf.plugin_id, pf.function_name
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
    SELECT pc.nav_uuid, pc.file_name, nl.function_name AS feature, 'plugin' AS source
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
),
linux_unsupported_fns AS (
    SELECT function_id FROM ref.function_os_affinity
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
    SELECT src.Object_UUID AS nav_uuid, src.File_Name AS file_name,
           'fn:' || sf.function_id AS feature, 'function' AS source
    FROM ObjectLinks ol
    JOIN fn_seeds sf ON ol.Target_UUID = sf.Object_UUID
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    UNION ALL
    SELECT src.Object_UUID, src.File_Name, 'fn:' || cc.function_id, 'function'
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM fn_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    WHERE ol.Link_Role = 'calls_customfunction' AND src.Object_Type = 'Script'
),
step_evidence AS (
    SELECT s.Script_UUID AS nav_uuid, s.File_Name AS file_name,
           'step:' || s.Step_ID AS feature, 'step' AS source
    FROM StepsForScripts s
    JOIN ref.step_os_affinity a
      ON a.step_id = s.Step_ID AND a.os = 'linux' AND a.affinity = 'unsupported'
    WHERE s.Is_Enabled
),
evidence AS (
    SELECT DISTINCT * FROM plugin_evidence
    UNION ALL SELECT DISTINCT * FROM fn_evidence
    UNION ALL SELECT DISTINCT * FROM step_evidence
)
SELECT
    COUNT(DISTINCT nav_uuid) AS script_count,
    COUNT(DISTINCT feature) FILTER (WHERE source = 'plugin')   AS plugin_functions,
    COUNT(DISTINCT feature) FILTER (WHERE source = 'function') AS claris_functions,
    COUNT(DISTINCT feature) FILTER (WHERE source = 'step')     AS claris_steps,
    COUNT(DISTINCT file_name) AS affected_files,
    getvariable('file') AS file
FROM evidence
WHERE (getvariable('file') IS NULL OR getvariable('file') = '' OR file_name = getvariable('file'));
