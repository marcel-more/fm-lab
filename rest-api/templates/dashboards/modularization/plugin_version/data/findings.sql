-- Version violations against the user-selected installed plugin version.
-- Active only when a version is chosen in the header select (neutral entry =
-- empty param = no check, empty result). The catalog knows no installed
-- plugin version - the selection is the user's honest statement, never an
-- assumption. Same evidence and resolution as data/summary.sql - keep the
-- CTEs in sync. Comparison always runs on since_version_num (major*1000 +
-- minor), never on the version string. An unparseable selection degrades to
-- "no check" plus a single info hint row.
WITH plugin_calls AS (
    SELECT src.Object_UUID AS nav_uuid, src.Object_Type AS object_type,
           src.Object_Name AS object_name, src.File_Name AS file_name,
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
           cf.Object_Name, tgt.Object_Name
    FROM ObjectLinks sc
    JOIN ObjectCatalog s   ON sc.Source_UUID = s.Object_UUID AND s.Object_Type = 'Script'
    JOIN ObjectCatalog cf  ON sc.Target_UUID = cf.Object_UUID AND cf.Object_Type = 'CustomFunction'
    JOIN ObjectLinks pl    ON pl.Source_UUID = cf.Object_UUID AND pl.Link_Role = 'calls_pluginfunction'
    JOIN ObjectCatalog tgt ON pl.Target_UUID = tgt.Object_UUID AND tgt.Object_Type = 'PluginFunction'
    WHERE sc.Link_Role = 'calls_customfunction'
      AND tgt.Object_Name LIKE '%::%'
),
scoped AS (
    SELECT * FROM plugin_calls
    WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
grouped AS (
    SELECT nav_uuid, object_type, object_name, file_name,
           via_custom_function, target_name, COUNT(*) AS usage_count
    FROM scoped
    GROUP BY ALL
),
named AS (
    SELECT g.*,
           split_part(g.target_name, ':', 1) AS plugin_prefix,
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
    WHERE p.plugin_id IS NOT NULL
),
enriched AS (
    SELECT n.*, fc.component, fc.since_version, fc.since_version_num
    FROM named n
    LEFT JOIN plugref.plugin_functions fc
           ON fc.plugin_id = n.plugin_id AND fc.function_name = n.canonical_name
),
-- Defensive parse: raw selection + numeric key. TRY_CAST keeps a future
-- non-numeric part from erroring; the strict major.minor regex decides.
installed AS (
    SELECT NULLIF(getvariable('installed_version'), '') AS raw,
           CASE WHEN regexp_matches(COALESCE(getvariable('installed_version'), ''), '^\d+\.\d+$')
                THEN TRY_CAST(split_part(getvariable('installed_version'), '.', 1) AS INTEGER) * 1000
                     + TRY_CAST(split_part(getvariable('installed_version'), '.', 2) AS INTEGER)
           END AS num
),
violations AS (
    SELECT 'plugin-version-requirement' AS rule_id,
        'warning' AS severity,
        'version_violation' AS finding_kind,
        e.file_name, e.nav_uuid, e.object_type, e.object_name AS script_name,
        e.plugin_id, e.canonical_name AS function_name,
        e.component, e.since_version,
        i.raw AS installed_version,
        e.via_custom_function, e.usage_count,
        e.plugin_prefix || ' function ' || e.canonical_name || ' needs plugin >= '
            || e.since_version || ', installed is ' || i.raw
            || CASE WHEN e.via_custom_function IS NOT NULL
                    THEN ' - called via custom function "' || e.via_custom_function || '"' ELSE '' END
            AS message
    FROM enriched e, installed i
    WHERE i.num IS NOT NULL
      AND e.since_version_num > i.num
    -- Direct evidence wins over the CF wrapper for the same script+function.
    -- The whole row breaks the remaining ties: every request picks the same row.
    QUALIFY row_number() OVER (
        PARTITION BY e.nav_uuid, e.canonical_name
        ORDER BY (e.via_custom_function IS NOT NULL), e.via_custom_function, e) = 1
),
-- Unparseable selection: degrade defined - one hint row, no check.
hint AS (
    SELECT 'plugin-version-requirement' AS rule_id,
        'info' AS severity,
        'unparseable_version' AS finding_kind,
        CAST(NULL AS VARCHAR) AS file_name, CAST(NULL AS VARCHAR) AS nav_uuid,
        CAST(NULL AS VARCHAR) AS object_type, CAST(NULL AS VARCHAR) AS script_name,
        CAST(NULL AS VARCHAR) AS plugin_id, CAST(NULL AS VARCHAR) AS function_name,
        CAST(NULL AS VARCHAR) AS component, CAST(NULL AS VARCHAR) AS since_version,
        i.raw AS installed_version,
        CAST(NULL AS VARCHAR) AS via_custom_function, CAST(NULL AS BIGINT) AS usage_count,
        'installed_version "' || i.raw || '" is not a major.minor version - no check performed' AS message
    FROM installed i
    WHERE i.raw IS NOT NULL AND i.num IS NULL
),
core AS (
    SELECT * FROM violations
    UNION ALL
    SELECT * FROM hint
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
