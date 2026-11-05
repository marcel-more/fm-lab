-- OS binding via plug-in evidence (axis b, OS sub-axis - inventory, not defects).
-- A script calling a plug-in function that does not exist on at least one OS
-- (macos / windows / linux / ios) is bound to the remaining ones. Flags are
-- the verbatim MBS documentation values (reference/plugin_spec.duckdb,
-- ATTACHed as 'plugref'; binary with MBS authority - a hard 'does not exist
-- there', hence signal='exclusive'), folded into the shared OS vocabulary by
-- the curated plugref.plugin_os_map (v7: formalises the former inline
-- interpretation; 'server' is a runtime flag and stays out of the OS profile).
-- 'ios' means the OPERATING SYSTEM; via plug-in it is always the Claris iOS
-- SDK runtime (qualifier 'sdk-only') - NOT FileMaker Go, which supports no
-- plug-ins and never feeds this member. Severity is always 'info': findings
-- are neutral properties; the pro-environment compatibility tests stay OS-free.
WITH plugin_calls AS (
    -- Direct plugin-function usage; the '::' filter excludes the known
    -- misclassified PluginFunction rows (see analysis-workflows.md pitfalls).
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
    -- One-level custom-function wrapper: Script -> CF -> plugin function
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
-- One row per function with its OS tuple. The verbatim vendor flags fold
-- into the shared OS vocabulary (macos|windows|linux|ios) through the curated
-- plugref.plugin_os_map (since plugin_spec 1.1.0) - the 'server' flag has no
-- map row (runtime statement, handled by the compat members), and 'ios_sdk'
-- maps to the OS 'ios' with qualifier 'sdk-only' (FileMaker Go supports no
-- plug-ins, so an iOS-via-plugin statement is always the Claris iOS SDK).
-- Only functions missing at least one OS carry a binding signal.
flags AS (
    SELECT pf.plugin_id, pf.function_name,
           bool_or(CASE WHEN m.os = 'macos'   THEN pf.supported END) AS macos,
           bool_or(CASE WHEN m.os = 'windows' THEN pf.supported END) AS windows,
           bool_or(CASE WHEN m.os = 'linux'   THEN pf.supported END) AS linux,
           bool_or(CASE WHEN m.os = 'ios'     THEN pf.supported END) AS ios,
           max(CASE WHEN m.os = 'ios' THEN m.qualifier END) AS ios_qualifier
    FROM plugref.plugin_function_platforms pf
    JOIN plugref.plugin_os_map m
      ON m.plugin_id = pf.plugin_id AND m.platform = pf.platform
    GROUP BY pf.plugin_id, pf.function_name
    HAVING NOT (macos AND windows AND linux AND ios)
),
-- Shared os_profile vocabulary of the platform-os-binding set (steps /
-- functions / plugins members render into the same matrix).
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
        END AS os_profile,
        concat_ws(', ',
            CASE WHEN macos THEN 'macOS' END,
            CASE WHEN windows THEN 'Windows' END,
            CASE WHEN linux THEN 'Linux' END,
            CASE WHEN ios THEN 'iOS' ||
                CASE WHEN ios_qualifier IS NOT NULL THEN ' (' || ios_qualifier || ')' ELSE '' END
            END) AS supported_list
    FROM flags
),
core AS (
    SELECT 'platform-os-binding' AS rule_id,
        'info' AS severity,
        n.file_name, n.nav_uuid, n.object_type, n.object_name AS script_name,
        n.plugin_id, n.canonical_name AS function_name, fc.component,
        pr.os_profile, pr.macos, pr.windows, pr.linux, pr.ios,
        CASE WHEN pr.ios THEN pr.ios_qualifier END AS ios_qualifier,
        'exclusive' AS signal,
        n.evidence_kind, n.via_custom_function, n.usage_count,
        n.plugin_prefix || ' function ' || n.canonical_name || ' is platform-bound ('
            || pr.os_profile || ': available on ' || pr.supported_list || ')'
            || CASE WHEN n.via_custom_function IS NOT NULL
                    THEN ' - called via custom function "' || n.via_custom_function || '"' ELSE '' END
            AS message
    FROM named n
    JOIN profiled pr
      ON pr.plugin_id = n.plugin_id AND pr.function_name = n.canonical_name
    LEFT JOIN plugref.plugin_functions fc
      ON fc.plugin_id = n.plugin_id AND fc.function_name = n.canonical_name
    -- Direct evidence wins over the CF wrapper for the same script+function.
    -- The whole row breaks the remaining ties: every request picks the same row.
    QUALIFY row_number() OVER (
        PARTITION BY n.nav_uuid, n.canonical_name
        ORDER BY (n.via_custom_function IS NOT NULL), n.via_custom_function, n, pr) = 1
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT *,
           os_profile AS _ord_1,
           file_name AS _ord_2,
           script_name AS _ord_3,
           function_name AS _ord_4
    FROM core
    WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
