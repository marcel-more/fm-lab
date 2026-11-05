-- Plugin-function compatibility for FileMaker Go (iOS) (axis a, plugin evidence).
-- Verbatim layer: reference/plugin_spec.duckdb (ATTACHed as 'plugref' by the
-- API connection; the fm-test direct path attaches it itself), derived from
-- the MBS docs mirror. Interpretation layer: plugin_generic_rules
-- ('FileMaker Go supports no plug-ins', Claris doc) - applies to EVERY
-- plug-in function regardless of vendor or doc coverage.
-- Severity model: mapped effect ('error') for functions the map excludes from
-- this environment; unknown function of a known plugin -> 'info' (unresolved,
-- never a silent fall-through). MBS platform flags are binary with MBS
-- authority - independent of the Claris tri-state step_compat semantics.
WITH plugin_calls AS (
    -- Direct plugin-function usage (edges resolved at import). The '::' filter
    -- excludes the known misclassified PluginFunction rows without a qualified
    -- name (see analysis-workflows.md, platform pitfalls).
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
    -- (the standard error-handling idiom; deeper CF chains are out of scope).
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
-- Name resolution: catalog name 'MBS:Files.FileSize::Files.FileSize' ->
-- prefix before the first ':' matches plugins.detect_prefix, sub-name after
-- the last '::' matches plugin_functions (case-insensitive), old names
-- resolve via plugin_function_aliases. Never a silent fall-through: known
-- plugin without a doc hit surfaces as an 'unresolved' info row.
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
enriched AS (
    SELECT n.*, fc.component
    FROM named n
    LEFT JOIN plugref.plugin_functions fc
           ON fc.plugin_id = n.plugin_id AND fc.function_name = n.canonical_name
),
core AS (
    SELECT 'platform-plugins-ios' AS rule_id,
        gr.effect AS severity,
        e.file_name, e.nav_uuid, e.object_type, e.object_name AS script_name,
        e.plugin_id, COALESCE(e.canonical_name, e.raw_name) AS function_name,
        e.component, e.via_custom_function, e.evidence_kind, e.usage_count,
        'Plug-in function ' || COALESCE(e.canonical_name, e.raw_name) || ' (' || e.plugin_prefix
            || ') cannot run in FileMaker Go - FileMaker Go does not support plug-ins (any vendor; not to be confused with the Claris iOS SDK)'
            || CASE WHEN e.via_custom_function IS NOT NULL
                    THEN ' - called via custom function "' || e.via_custom_function || '"' ELSE '' END
            AS message
    FROM enriched e
    JOIN plugref.plugin_generic_rules gr ON gr.fm_env = 'go'
    -- The whole row breaks the remaining ties: every request picks the same row.
    QUALIFY row_number() OVER (
        PARTITION BY e.nav_uuid, COALESCE(e.canonical_name, e.raw_name)
        ORDER BY (e.via_custom_function IS NOT NULL), e.via_custom_function, e) = 1
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT *,
           CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END AS _ord_1,
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
