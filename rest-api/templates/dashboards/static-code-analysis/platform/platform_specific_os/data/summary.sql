-- Hand-maintained aggregate over the same core as data/findings.sql -
-- keep the CTEs and scope filters in sync. The default result counts SCRIPTS
-- (unit "scripts", script evidence only - layout/field usages are listed in
-- the findings but never inflate the core metric).
WITH plugin_calls AS (
    SELECT src.Object_UUID AS nav_uuid, src.Object_Type AS object_type,
           src.Object_Name AS object_name, src.File_Name AS file_name,
           CASE WHEN src.Object_Type = 'Script' THEN 'script' ELSE 'layout' END AS evidence_kind,
           CAST(NULL AS VARCHAR) AS via_custom_function,
           tgt.Object_Name AS target_name
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND src.Object_Type IN ('Script', 'LayoutObject', 'Field')
      AND tgt.Object_Type = 'PluginFunction'
      AND tgt.Object_Name LIKE '%::%'
    UNION ALL
    SELECT s.Object_UUID, s.Object_Type, s.Object_Name, s.File_Name,
           'script', cf.Object_Name, tgt.Object_Name
    FROM ObjectLinks sc
    JOIN ObjectCatalog s   ON sc.Source_UUID = s.Object_UUID AND s.Object_Type = 'Script'
    JOIN ObjectCatalog cf  ON sc.Target_UUID = cf.Object_UUID AND cf.Object_Type = 'CustomFunction'
    JOIN ObjectLinks pl    ON pl.Source_UUID = cf.Object_UUID AND pl.Link_Role = 'calls_pluginfunction'
    JOIN ObjectCatalog tgt ON pl.Target_UUID = tgt.Object_UUID AND tgt.Object_Type = 'PluginFunction'
    WHERE sc.Link_Role = 'calls_customfunction'
      AND tgt.Object_Name LIKE '%::%'
),
grouped AS (
    SELECT nav_uuid, object_type, object_name, file_name, evidence_kind,
           via_custom_function, target_name, COUNT(*) AS usage_count
    FROM plugin_calls
    GROUP BY ALL
),
named AS (
    SELECT g.*,
           split_part(g.target_name, ':', 1) AS plugin_prefix,
           regexp_replace(g.target_name, '^.*::', '') AS raw_name,
           p.plugin_id,
           COALESCE(f.function_name, af.function_name) AS canonical_name
    FROM grouped g
    LEFT JOIN plugref.plugins p
           ON lower(p.detect_prefix) = lower(split_part(g.target_name, ':', 1))
    LEFT JOIN plugref.plugin_functions f
           ON f.plugin_id = p.plugin_id
          AND lower(f.function_name) = lower(regexp_replace(g.target_name, '^.*::', ''))
    LEFT JOIN plugref.plugin_function_aliases af
           ON af.plugin_id = p.plugin_id
          AND lower(af.alias) = lower(regexp_replace(g.target_name, '^.*::', ''))
),
-- OS tuple via the curated plugref.plugin_os_map (shared OS vocabulary
-- macos|windows|linux|ios; 'server' is a runtime flag, no map row) - keep in
-- sync with data/findings.sql.
flags AS (
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
profiled AS (
    SELECT *,
        CASE
            WHEN macos AND NOT windows AND NOT linux AND NOT ios THEN 'macos-only'
            WHEN windows AND NOT macos AND NOT linux AND NOT ios THEN 'windows-only'
            WHEN linux AND NOT macos AND NOT windows AND NOT ios THEN 'linux-only'
            WHEN ios AND NOT macos AND NOT windows AND NOT linux THEN 'ios-only'
            WHEN macos AND windows AND NOT linux AND NOT ios THEN 'desktop-only'
            WHEN macos AND ios AND NOT windows AND NOT linux THEN 'apple-only'
            ELSE 'mixed'
        END AS os_profile
    FROM flags
),
core AS (
    SELECT n.file_name, n.nav_uuid, n.evidence_kind, n.canonical_name, pr.os_profile
    FROM named n
    JOIN profiled pr
      ON pr.plugin_id = n.plugin_id AND pr.function_name = n.canonical_name
    QUALIFY row_number() OVER (
        PARTITION BY n.nav_uuid, n.canonical_name
        ORDER BY (n.via_custom_function IS NOT NULL), n.via_custom_function) = 1
)
SELECT
    COUNT(DISTINCT nav_uuid) FILTER (WHERE evidence_kind = 'script') AS script_count,
    COUNT(*) AS finding_count,
    COUNT(DISTINCT canonical_name) AS distinct_functions,
    COUNT(*) FILTER (WHERE os_profile = 'macos-only') AS macos_only,
    COUNT(*) FILTER (WHERE os_profile = 'desktop-only') AS desktop_only,
    COUNT(DISTINCT file_name) AS affected_files
FROM core
WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
