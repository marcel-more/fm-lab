-- OS binding via Claris builtin functions (axis b, OS sub-axis - inventory,
-- not defects). Source: ref.function_os_affinity (fm_spec >= 1.13.0) - a
-- CURATED, SPARSE set from the Claris help prose; absence of a row means "no
-- Claris statement", never "runs everywhere". Only the binding classes feed
-- findings: 'exclusive' (ComputeModel: macOS+iOS) and source-true inverse
-- 'unsupported' rows (resolved against all four OS - functions have no
-- compat table, the calc engine exists on every OS through some runtime).
-- 'variant' rows (Tranche 2: path formats, window geometry, ...) are doc
-- knowledge -> fm-spec badge only; 'os_probe' rows (Get(SystemPlatform), ...)
-- are the guard idiom -> context evidence, never a binding (E1 territory).
-- 'ios' is the OPERATING SYSTEM (FileMaker Go and iOS SDK apps), never the
-- Go runtime chip. Resolution and CF transitivity follow the v5 function
-- member (platform_specific_ios): locale-tolerant name lookup, calls_function
-- edges, recursive CF closure with a path guard against cycles.
WITH RECURSIVE aff AS (
    SELECT function_id,
           bool_or(affinity = 'exclusive') AS has_exclusive,
           bool_or(affinity = 'exclusive' AND os = 'macos')   AS excl_macos,
           bool_or(affinity = 'exclusive' AND os = 'windows') AS excl_windows,
           bool_or(affinity = 'exclusive' AND os = 'linux')   AS excl_linux,
           bool_or(affinity = 'exclusive' AND os = 'ios')     AS excl_ios,
           bool_or(affinity = 'unsupported' AND os = 'macos')   AS unsup_macos,
           bool_or(affinity = 'unsupported' AND os = 'windows') AS unsup_windows,
           bool_or(affinity = 'unsupported' AND os = 'linux')   AS unsup_linux,
           bool_or(affinity = 'unsupported' AND os = 'ios')     AS unsup_ios,
           string_agg(os, ', ' ORDER BY os) FILTER (WHERE affinity = 'unsupported') AS unsup_list
    FROM ref.function_os_affinity
    WHERE affinity IN ('exclusive', 'unsupported')
    GROUP BY function_id
),
profiled AS (
    SELECT *,
        CASE WHEN has_exclusive THEN excl_macos   ELSE NOT unsup_macos   END AS macos,
        CASE WHEN has_exclusive THEN excl_windows ELSE NOT unsup_windows END AS windows,
        CASE WHEN has_exclusive THEN excl_linux   ELSE NOT unsup_linux   END AS linux,
        CASE WHEN has_exclusive THEN excl_ios     ELSE NOT unsup_ios     END AS ios,
        CASE WHEN has_exclusive THEN 'exclusive' ELSE 'unsupported' END AS affinity
    FROM aff
),
labeled AS (
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
            CASE WHEN ios THEN 'iOS' END) AS supported_list
    FROM profiled
),
-- Locale-tolerant function resolution (catalog BuiltinFunction names are
-- localized); space-insensitive plus the inner text of a trailing "(...)".
seed_functions AS (
    SELECT fn.Object_UUID, MIN(fl.function_id) AS function_id
    FROM ObjectCatalog fn
    JOIN ref.function_name_lookup fl
      ON replace(lower(fl.lookup_name), ' ', '') = replace(lower(fn.Object_Name), ' ', '')
      OR replace(lower(fl.lookup_name), ' ', '')
         = replace(lower(regexp_extract(fn.Object_Name, '\(\s*(.*?)\s*\)\s*$', 1)), ' ', '')
    JOIN labeled a ON a.function_id = fl.function_id
    WHERE fn.Object_Type = 'BuiltinFunction'
    GROUP BY fn.Object_UUID
),
function_evidence AS (
    SELECT src.File_Name AS file_name, src.Object_UUID AS nav_uuid,
           src.Object_Name AS script_name,
           sf.function_id,
           COALESCE(f.canonical_name, 'Function ' || sf.function_id) AS feature,
           f.url_slug AS doc_slug, count(*) AS usage_count,
           CAST(NULL AS VARCHAR) AS via_custom_function
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN seed_functions sf ON ol.Target_UUID = sf.Object_UUID
    LEFT JOIN ref.functions f ON f.function_id = sf.function_id
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, src.Object_Name, sf.function_id,
             f.canonical_name, f.url_slug
),
-- Transitive closure: custom functions reaching a seed function directly or
-- through other CFs; the path array guards cycles (self-recursive CFs stop).
cf_closure(cf_uuid, function_id, path) AS (
    SELECT ol.Source_UUID, sf.function_id, [ol.Source_UUID]
    FROM ObjectLinks ol
    JOIN seed_functions sf ON ol.Target_UUID = sf.Object_UUID
    WHERE ol.Link_Role = 'calls_function' AND ol.Source_Type = 'CustomFunction'
    UNION ALL
    SELECT ol.Source_UUID, c.function_id, list_append(c.path, ol.Source_UUID)
    FROM cf_closure c
    JOIN ObjectLinks ol ON ol.Target_UUID = c.cf_uuid
    WHERE ol.Link_Role = 'calls_customfunction' AND ol.Source_Type = 'CustomFunction'
      AND NOT list_contains(c.path, ol.Source_UUID)
),
cf_evidence AS (
    SELECT src.File_Name AS file_name, src.Object_UUID AS nav_uuid,
           src.Object_Name AS script_name,
           cc.function_id,
           COALESCE(f.canonical_name, 'Function ' || cc.function_id) AS feature,
           f.url_slug AS doc_slug, count(*) AS usage_count,
           cf.Object_Name AS via_custom_function
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM cf_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog cf ON cc.cf_uuid = cf.Object_UUID AND cf.Object_Type = 'CustomFunction'
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    LEFT JOIN ref.functions f ON f.function_id = cc.function_id
    WHERE ol.Link_Role = 'calls_customfunction' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, src.Object_Name, cc.function_id,
             f.canonical_name, cf.Object_Name, f.url_slug
),
evidence AS (
    SELECT * FROM function_evidence
    UNION ALL
    SELECT * FROM cf_evidence
),
core AS (
    SELECT 'platform-os-functions' AS rule_id,
        'info' AS severity,
        e.file_name, e.nav_uuid, 'Script' AS object_type, e.script_name,
        e.feature
          || CASE WHEN e.via_custom_function IS NOT NULL
                  THEN ' (via CF ' || e.via_custom_function || ')' ELSE '' END AS feature,
        e.doc_slug,
        l.os_profile, l.macos, l.windows, l.linux, l.ios,
        l.affinity, 'exclusive' AS signal,
        e.via_custom_function, e.usage_count,
        CASE l.affinity
             WHEN 'exclusive'
             THEN e.feature || ' is supported only on ' || l.supported_list || ' (' || l.os_profile || ')'
             ELSE e.feature || ' is not supported on ' || l.unsup_list || ' (Claris prose, stored source-true); works on ' || l.supported_list
        END
          || CASE WHEN e.via_custom_function IS NOT NULL
                  THEN ' - called via custom function "' || e.via_custom_function || '"' ELSE '' END
          || '; used ' || e.usage_count || 'x in this script' AS message
    FROM evidence e
    JOIN labeled l ON l.function_id = e.function_id
    -- Direct evidence wins over the CF wrapper for the same script+function.
    -- The whole row breaks the remaining ties: every request picks the same row.
    QUALIFY row_number() OVER (
        PARTITION BY e.nav_uuid, e.function_id
        ORDER BY (e.via_custom_function IS NOT NULL), e.via_custom_function, e) = 1
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT *,
           os_profile AS _ord_1,
           file_name AS _ord_2,
           script_name AS _ord_3,
           feature AS _ord_4
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
