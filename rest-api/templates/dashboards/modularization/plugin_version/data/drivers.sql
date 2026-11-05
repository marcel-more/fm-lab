-- Driver functions of the version requirement: plug-in functions in use,
-- descending by their documented introduction version - "which function
-- drives the requirement?" makes the derived required_version verifiable.
-- Same evidence and resolution as data/summary.sql - keep the CTEs in sync.
-- When a version is selected in the header, exceeds_installed marks the
-- functions that violate it (comparison on since_version_num, never on the
-- version string).
WITH plugin_calls AS (
    SELECT src.Object_UUID AS nav_uuid, src.Object_Type AS object_type,
           src.Object_Name AS object_name, src.File_Name AS file_name,
           CAST(NULL AS VARCHAR) AS via_custom_function,
           tgt.Object_Name AS target_name, tgt.Object_UUID AS target_uuid
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND src.Object_Type IN ('Script', 'LayoutObject', 'Field')
      AND tgt.Object_Type = 'PluginFunction'
      AND tgt.Object_Name LIKE '%::%'
    UNION ALL
    SELECT s.Object_UUID, s.Object_Type, s.Object_Name, s.File_Name,
           cf.Object_Name, tgt.Object_Name, tgt.Object_UUID
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
named AS (
    SELECT g.*, p.plugin_id,
           COALESCE(f.function_name, af.function_name) AS canonical_name
    FROM scoped g
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
    SELECT n.*, fc.component, fc.status, fc.since_version, fc.since_version_num
    FROM named n
    LEFT JOIN plugref.plugin_functions fc
           ON fc.plugin_id = n.plugin_id AND fc.function_name = n.canonical_name
),
-- Defensive parse of the header selection: TRY_CAST + strict major.minor -
-- an unparseable value behaves like no selection (see data/findings.sql).
installed AS (
    SELECT CASE WHEN regexp_matches(COALESCE(getvariable('installed_version'), ''), '^\d+\.\d+$')
                THEN TRY_CAST(split_part(getvariable('installed_version'), '.', 1) AS INTEGER) * 1000
                     + TRY_CAST(split_part(getvariable('installed_version'), '.', 2) AS INTEGER)
           END AS num
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        COALESCE(e.canonical_name, regexp_replace(e.target_name, '^.*::', '')) AS function_name,
        e.component,
        e.since_version,
        e.since_version_num,
        e.status,
        COUNT(*) AS callsites,
        COUNT(DISTINCT e.nav_uuid) AS objects,
        COUNT(DISTINCT e.file_name) AS files,
        arg_max(e.target_uuid, e.target_name) AS nav_uuid,
        CASE WHEN i.num IS NULL THEN NULL
             ELSE e.since_version_num > i.num END AS exceeds_installed,
           e.since_version_num AS _ord_1
    FROM enriched e, installed i
    GROUP BY ALL
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1),
           row_number() OVER (ORDER BY u._ord_1 DESC NULLS LAST, u.callsites DESC, u.function_name, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 100), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
