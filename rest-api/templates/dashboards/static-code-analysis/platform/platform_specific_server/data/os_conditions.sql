-- Server x OS conditions inside the server usage profile: plug-in functions
-- used in scope that run under the FileMaker Server script engine but NOT on
-- every server operating system (practically: no Linux build) - one row per
-- function with the carrying and the missing OS set. Cores shared with the
-- platform_compat_plugins_server member (keep in sync); needs both reference
-- attachments (ref for the host matrix, plugref for the flags and the OS
-- map) - without the plug-in platform map this card reports an error while
-- the rest of the dashboard keeps working.
WITH plugin_calls AS (
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
named AS (
    SELECT g.nav_uuid, g.file_name,
           p.plugin_id,
           COALESCE(f.function_name, af.function_name) AS canonical_name
    FROM plugin_calls g
    LEFT JOIN plugref.plugins p
           ON lower(p.detect_prefix) = lower(split_part(g.target_name, ':', 1))
    LEFT JOIN plugref.plugin_functions f
           ON f.plugin_id = p.plugin_id
          AND lower(f.function_name) = lower(regexp_replace(g.target_name, '^.*::', ''))
    LEFT JOIN plugref.plugin_function_aliases af
           ON af.plugin_id = p.plugin_id
          AND lower(af.alias) = lower(regexp_replace(g.target_name, '^.*::', ''))
    WHERE COALESCE(f.function_name, af.function_name) IS NOT NULL
),
os_condition AS (
    SELECT pf.plugin_id, pf.function_name,
           string_agg(so.os, ', ' ORDER BY so.os)
               FILTER (WHERE COALESCE(osf.supported, false)) AS os_condition,
           string_agg(so.os, ', ' ORDER BY so.os)
               FILTER (WHERE NOT COALESCE(osf.supported, false)) AS os_missing
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
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT n.canonical_name AS function_name,
        fc.component,
        oc.os_condition, oc.os_missing,
        COUNT(DISTINCT n.nav_uuid) AS script_count,
        COUNT(DISTINCT n.file_name) AS affected_files
    FROM named n
    JOIN os_condition oc
      ON oc.plugin_id = n.plugin_id AND oc.function_name = n.canonical_name
    LEFT JOIN plugref.plugin_functions fc
      ON fc.plugin_id = n.plugin_id AND fc.function_name = n.canonical_name
    WHERE (getvariable('file') IS NULL OR n.file_name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR n.nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY n.canonical_name, fc.component, oc.os_condition, oc.os_missing
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.script_count DESC, u.function_name, u) AS row_key
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
