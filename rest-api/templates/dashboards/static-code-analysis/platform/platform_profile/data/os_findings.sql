-- OS-bound scripts result list of the platform profile tile (v7.1): one row
-- per script, aggregated over the three evidence sources of the
-- platform-os-binding set (Claris steps / builtin functions / plug-in
-- functions). Keep the per-source cores in sync with data/os_summary.sql
-- (same union) and the member bundles.
-- @params: file (optional), os (optional: macos|windows|linux|ios - the
-- KPI-tile filter; a desktop-only script matches both macos and windows),
-- limit (optional, default 500)
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
           s.Script_Name AS script_name, 'step' AS source,
           COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS feature,
           e.macos, e.windows, e.linux, e.ios
    FROM StepsForScripts s
    JOIN step_effective e ON e.step_id = s.Step_ID
    LEFT JOIN ref.script_steps st ON st.step_id = s.Step_ID
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
           src.Object_Name AS script_name, 'function' AS source,
           COALESCE(f.canonical_name, 'Function ' || sf.function_id) AS feature,
           l.macos, l.windows, l.linux, l.ios
    FROM ObjectLinks ol
    JOIN fn_seeds sf ON ol.Target_UUID = sf.Object_UUID
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN fn_labeled l ON l.function_id = sf.function_id
    LEFT JOIN ref.functions f ON f.function_id = sf.function_id
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    UNION ALL
    SELECT src.Object_UUID, src.File_Name, src.Object_Name, 'function',
           COALESCE(f.canonical_name, 'Function ' || cc.function_id),
           l.macos, l.windows, l.linux, l.ios
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM fn_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN fn_labeled l ON l.function_id = cc.function_id
    LEFT JOIN ref.functions f ON f.function_id = cc.function_id
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
           src.Object_Name AS script_name, 'plugin' AS source,
           fl.function_name AS feature,
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
),
-- OS-SPECIFIC rule: a binding marks a script as bound to an OS only when its
-- supported-OS set is confined to at most TWO systems (macos-only,
-- desktop-only, windows+ios, ...). Broad restrictions like "everything
-- except Linux" (three supported OS) stay in the unfiltered list but never
-- feed a per-OS tile — otherwise a Clipboard function that merely lacks a
-- Linux build would surface under the iOS filter (cross-contamination).
scoped AS (
    SELECT *,
        (CAST(COALESCE(macos, false) AS INT) + CAST(COALESCE(windows, false) AS INT)
         + CAST(COALESCE(linux, false) AS INT) + CAST(COALESCE(ios, false) AS INT)) <= 2
            AS os_specific
    FROM all_scripts
),
-- With an active os filter only the OS-specific bindings naming that OS
-- survive BEFORE aggregation — the row then shows exactly the bindings that
-- justify the match, not every restriction the script happens to carry.
os_filtered AS (
    SELECT * FROM scoped
    WHERE getvariable('os') IS NULL OR getvariable('os') = ''
       OR (os_specific AND CASE getvariable('os')
             WHEN 'macos' THEN macos WHEN 'windows' THEN windows
             WHEN 'linux' THEN linux WHEN 'ios' THEN ios
             ELSE true END)
),
per_script AS (
    SELECT nav_uuid, file_name, script_name,
           bool_or(macos)   AS macos,
           bool_or(windows) AS windows,
           bool_or(linux)   AS linux,
           bool_or(ios)     AS ios,
           string_agg(DISTINCT source, ', ' ORDER BY source) AS sources,
           string_agg(DISTINCT feature, ', ' ORDER BY feature) AS bindings,
           COUNT(*) AS evidence_count
    FROM os_filtered
    GROUP BY nav_uuid, file_name, script_name
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT nav_uuid, file_name AS file, script_name AS name,
        CASE
            WHEN macos AND NOT windows AND NOT linux AND NOT ios THEN 'macos-only'
            WHEN windows AND NOT macos AND NOT linux AND NOT ios THEN 'windows-only'
            WHEN linux AND NOT macos AND NOT windows AND NOT ios THEN 'linux-only'
            WHEN ios AND NOT macos AND NOT windows AND NOT linux THEN 'ios-only'
            WHEN macos AND windows AND NOT linux AND NOT ios THEN 'desktop-only'
            WHEN macos AND ios AND NOT windows AND NOT linux THEN 'apple-only'
            ELSE 'mixed'
        END AS os_profile,
        macos, windows, linux, ios, sources, bindings, evidence_count,
           file_name AS _ord_1,
           script_name AS _ord_2
    FROM per_script
    WHERE (getvariable('file') IS NULL OR getvariable('file') = '' OR file_name = getvariable('file'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u) AS row_key
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
