-- Hand-maintained aggregate over the same core as data/findings.sql - keep
-- the CTEs and scope filters in sync. The default result counts SCRIPTS
-- (unit "scripts"); the per-OS columns feed the consolidated OS matrix of
-- the platform-os-binding set.
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
           bool_or(affinity = 'unsupported' AND os = 'ios')     AS unsup_ios
    FROM ref.function_os_affinity
    WHERE affinity IN ('exclusive', 'unsupported')
    GROUP BY function_id
),
labeled AS (
    SELECT function_id,
        CASE WHEN has_exclusive THEN excl_macos   ELSE NOT unsup_macos   END AS macos,
        CASE WHEN has_exclusive THEN excl_windows ELSE NOT unsup_windows END AS windows,
        CASE WHEN has_exclusive THEN excl_linux   ELSE NOT unsup_linux   END AS linux,
        CASE WHEN has_exclusive THEN excl_ios     ELSE NOT unsup_ios     END AS ios
    FROM aff
),
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
           sf.function_id, CAST(NULL AS VARCHAR) AS via_custom_function
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN seed_functions sf ON ol.Target_UUID = sf.Object_UUID
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, sf.function_id
),
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
           cc.function_id, 'cf' AS via_custom_function
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM cf_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    WHERE ol.Link_Role = 'calls_customfunction' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, cc.function_id
),
core AS (
    SELECT e.file_name, e.nav_uuid, e.function_id, l.macos, l.windows, l.linux, l.ios
    FROM (SELECT * FROM function_evidence UNION ALL SELECT * FROM cf_evidence) e
    JOIN labeled l ON l.function_id = e.function_id
    QUALIFY row_number() OVER (
        PARTITION BY e.nav_uuid, e.function_id
        ORDER BY (e.via_custom_function IS NOT NULL)) = 1
)
-- Per-OS counts apply the OS-SPECIFIC rule (shared with the OS matrix and
-- the profile tile): only bindings confined to at most TWO operating systems
-- mark a script as bound to an OS.
SELECT
    COUNT(DISTINCT nav_uuid) AS script_count,
    COUNT(*) AS finding_count,
    COUNT(DISTINCT function_id) AS distinct_functions,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE macos AND os_specific)   AS os_macos_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE windows AND os_specific) AS os_windows_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE linux AND os_specific)   AS os_linux_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE ios AND os_specific)     AS os_ios_scripts,
    COUNT(DISTINCT file_name) AS affected_files
FROM (
    SELECT *,
        (CAST(macos AS INT) + CAST(windows AS INT)
         + CAST(linux AS INT) + CAST(ios AS INT)) <= 2 AS os_specific
    FROM core
)
WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
