-- OS-binding row of the platform profile tile (v7): distinct scripts bound to
-- each operating system, unioned over the three evidence sources of the
-- platform-os-binding set (Claris steps, builtin functions, plug-in
-- functions). Keep the per-source cores in sync with the member bundles
-- (platform_os_steps / platform_os_functions / platform_specific_os).
-- A desktop-only script counts for macOS AND Windows. Requires fm_spec >=
-- 1.13.0 (ref) and plugin_spec >= 1.1.0 (plugref) - like the sibling datasets
-- of this tile, which already hard-depend on the current reference.
WITH RECURSIVE step_aff AS (
    SELECT step_id,
           bool_or(affinity = 'exclusive')   AS has_exclusive,
           bool_or(affinity = 'unsupported') AS has_unsupported,
           bool_or(affinity = 'exclusive' AND os = 'macos')   AS excl_macos,
           bool_or(affinity = 'exclusive' AND os = 'windows') AS excl_windows,
           bool_or(affinity = 'exclusive' AND os = 'linux')   AS excl_linux,
           bool_or(affinity = 'exclusive' AND os = 'ios')     AS excl_ios,
           bool_or(affinity = 'unsupported' AND os = 'macos')   AS unsup_macos,
           bool_or(affinity = 'unsupported' AND os = 'windows') AS unsup_windows,
           bool_or(affinity = 'unsupported' AND os = 'linux')   AS unsup_linux,
           bool_or(affinity = 'unsupported' AND os = 'ios')     AS unsup_ios,
           bool_or(affinity = 'variant' AND os = 'macos')   AS var_macos,
           bool_or(affinity = 'variant' AND os = 'windows') AS var_windows,
           bool_or(affinity = 'variant' AND os = 'linux')   AS var_linux,
           bool_or(affinity = 'variant' AND os = 'ios')     AS var_ios
    FROM ref.step_os_affinity
    GROUP BY step_id
),
step_hosts AS (
    SELECT c.step_id,
           bool_or(m.os = 'macos')   AS host_macos,
           bool_or(m.os = 'windows') AS host_windows,
           bool_or(m.os = 'linux')   AS host_linux,
           bool_or(m.os = 'ios')     AS host_ios
    FROM ref.step_compat c
    JOIN ref.runtime_os_matrix m ON m.supported
     AND m.fm_env IN ('pro', 'server', 'go', 'webdirect', 'cloud', 'dataapi', 'cwp')
     AND CASE m.fm_env
           WHEN 'pro' THEN c.pro WHEN 'server' THEN c.server WHEN 'go' THEN c.go
           WHEN 'webdirect' THEN c.webdirect WHEN 'cloud' THEN c.cloud
           WHEN 'dataapi' THEN c.dataapi WHEN 'cwp' THEN c.cwp
         END IS DISTINCT FROM false
    GROUP BY c.step_id
),
step_effective AS (
    SELECT a.step_id,
        CASE WHEN a.has_exclusive THEN a.excl_macos
             WHEN a.has_unsupported THEN COALESCE(h.host_macos, false) AND NOT a.unsup_macos
             ELSE a.var_macos END AS macos,
        CASE WHEN a.has_exclusive THEN a.excl_windows
             WHEN a.has_unsupported THEN COALESCE(h.host_windows, false) AND NOT a.unsup_windows
             ELSE a.var_windows END AS windows,
        CASE WHEN a.has_exclusive THEN a.excl_linux
             WHEN a.has_unsupported THEN COALESCE(h.host_linux, false) AND NOT a.unsup_linux
             ELSE a.var_linux END AS linux,
        CASE WHEN a.has_exclusive THEN a.excl_ios
             WHEN a.has_unsupported THEN COALESCE(h.host_ios, false) AND NOT a.unsup_ios
             ELSE a.var_ios END AS ios
    FROM step_aff a
    LEFT JOIN step_hosts h USING (step_id)
    WHERE a.has_exclusive OR a.has_unsupported OR a.step_id = 57
),
step_scripts AS (
    SELECT s.Script_UUID AS nav_uuid, s.File_Name AS file_name,
           e.macos, e.windows, e.linux, e.ios
    FROM StepsForScripts s
    JOIN step_effective e ON e.step_id = s.Step_ID
    WHERE s.Is_Enabled
),
fn_aff AS (
    SELECT function_id,
           bool_or(affinity = 'exclusive') AS has_exclusive,
           bool_or(affinity = 'exclusive' AND os = 'macos')   AS excl_macos,
           bool_or(affinity = 'exclusive' AND os = 'windows') AS excl_windows,
           bool_or(affinity = 'exclusive' AND os = 'linux')   AS excl_linux,
           bool_or(affinity = 'exclusive' AND os = 'ios')     AS excl_ios,
           bool_or(affinity = 'unsupported' AND os = 'macos')   AS unsup_macos,
           bool_or(affinity = 'unsupported' AND os = 'windows') AS unsup_windows,
           bool_or(affinity = 'unsupported' AND os = 'linux')   AS unsup_linux,
           bool_or(affinity = 'unsupported' AND os = 'ios')     AS unsup_ios
    FROM ref.function_os_affinity
    WHERE affinity IN ('exclusive', 'unsupported')
    GROUP BY function_id
),
fn_labeled AS (
    SELECT function_id,
        CASE WHEN has_exclusive THEN excl_macos   ELSE NOT unsup_macos   END AS macos,
        CASE WHEN has_exclusive THEN excl_windows ELSE NOT unsup_windows END AS windows,
        CASE WHEN has_exclusive THEN excl_linux   ELSE NOT unsup_linux   END AS linux,
        CASE WHEN has_exclusive THEN excl_ios     ELSE NOT unsup_ios     END AS ios
    FROM fn_aff
),
fn_seeds AS (
    SELECT fn.Object_UUID, MIN(fl.function_id) AS function_id
    FROM ObjectCatalog fn
    JOIN ref.function_name_lookup fl
      ON replace(lower(fl.lookup_name), ' ', '') = replace(lower(fn.Object_Name), ' ', '')
      OR replace(lower(fl.lookup_name), ' ', '')
         = replace(lower(regexp_extract(fn.Object_Name, '\(\s*(.*?)\s*\)\s*$', 1)), ' ', '')
    JOIN fn_labeled a ON a.function_id = fl.function_id
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
fn_scripts AS (
    SELECT src.Object_UUID AS nav_uuid, src.File_Name AS file_name,
           l.macos, l.windows, l.linux, l.ios
    FROM ObjectLinks ol
    JOIN fn_seeds sf ON ol.Target_UUID = sf.Object_UUID
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN fn_labeled l ON l.function_id = sf.function_id
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    UNION ALL
    SELECT src.Object_UUID, src.File_Name, l.macos, l.windows, l.linux, l.ios
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM fn_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN fn_labeled l ON l.function_id = cc.function_id
    WHERE ol.Link_Role = 'calls_customfunction' AND src.Object_Type = 'Script'
),
plugin_flags AS (
    SELECT pf.plugin_id, pf.function_name,
           bool_or(CASE WHEN m.os = 'macos'   THEN pf.supported END) AS macos,
           bool_or(CASE WHEN m.os = 'windows' THEN pf.supported END) AS windows,
           bool_or(CASE WHEN m.os = 'linux'   THEN pf.supported END) AS linux,
           bool_or(CASE WHEN m.os = 'ios'     THEN pf.supported END) AS ios
    FROM plugref.plugin_function_platforms pf
    JOIN plugref.plugin_os_map m
      ON m.plugin_id = pf.plugin_id AND m.platform = pf.platform
    GROUP BY pf.plugin_id, pf.function_name
    HAVING NOT (macos AND windows AND linux AND ios)
),
plugin_scripts AS (
    SELECT src.Object_UUID AS nav_uuid, src.File_Name AS file_name,
           fl.macos, fl.windows, fl.linux, fl.ios
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID AND src.Object_Type = 'Script'
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID AND tgt.Object_Type = 'PluginFunction'
    JOIN plugref.plugins p ON lower(p.detect_prefix) = lower(split_part(tgt.Object_Name, ':', 1))
    JOIN plugin_flags fl
      ON fl.plugin_id = p.plugin_id
     AND fl.function_name = (
           SELECT COALESCE(
             (SELECT f.function_name FROM plugref.plugin_functions f
               WHERE f.plugin_id = p.plugin_id
                 AND lower(f.function_name) = lower(regexp_replace(tgt.Object_Name, '^.*::', ''))),
             (SELECT af.function_name FROM plugref.plugin_function_aliases af
               WHERE af.plugin_id = p.plugin_id
                 AND lower(af.alias) = lower(regexp_replace(tgt.Object_Name, '^.*::', '')))))
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND tgt.Object_Name LIKE '%::%'
),
all_scripts AS (
    SELECT * FROM step_scripts
    UNION ALL SELECT * FROM fn_scripts
    UNION ALL SELECT * FROM plugin_scripts
)
-- Counts are deliberately NOT narrowed by the `os` param: the KPI tiles act
-- as filter chips for the os_findings list and keep their totals stable.
-- The `file` echo feeds the {{file}} token of the tile onClick actions
-- (round-trip pattern, see script_todos).
-- Per-OS counts apply the OS-SPECIFIC rule (keep in sync with
-- data/os_findings.sql): only bindings confined to at most TWO operating
-- systems mark a script as bound to an OS — broad "everything except X"
-- restrictions count toward the total but never toward a per-OS tile.
SELECT
    COUNT(DISTINCT nav_uuid) AS os_bound_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE macos AND os_specific)   AS os_macos_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE windows AND os_specific) AS os_windows_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE linux AND os_specific)   AS os_linux_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE ios AND os_specific)     AS os_ios_scripts,
    getvariable('file') AS file
FROM (
    SELECT *,
        (CAST(COALESCE(macos, false) AS INT) + CAST(COALESCE(windows, false) AS INT)
         + CAST(COALESCE(linux, false) AS INT) + CAST(COALESCE(ios, false) AS INT)) <= 2
            AS os_specific
    FROM all_scripts
)
WHERE (getvariable('file') IS NULL OR getvariable('file') = '' OR file_name = getvariable('file'));
