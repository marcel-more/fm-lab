-- Version floor (effective minimum FileMaker version) against the version the
-- file DECLARES. Sources: ref.step_compat.originated_in_version_num,
-- ref.functions.origin_version_num (both fm_spec >= 2.9.0) and
-- ref.script_triggers.since_version_num (2.8.0), ATTACHed as 'ref' by the API
-- connection; the fm-test direct path attaches it itself. The reference is the
-- only version authority - never a version string compare ('8.5' < '19.0'
-- lexically fails), always the numeric key.
-- A feature the reference carries no version for is NOT counted: no statement
-- is not "old". '6.0 or earlier' is a floor, not an exact version.
-- Findings: per file and axis the features that require MORE than the file
-- declares - one row per distinct feature with its usage count and one example
-- object as the navigation anchor. Keep the CTE chain in sync with
-- data/summary.sql.
WITH
-- The version a file DECLARES as its minimum (SaXML AddAction/Minimum/@version
-- -> FileOptionsCatalog.Min_Version). Same three-part canon as the reference
-- keys; an unparseable or missing declaration yields NULL and is counted, never
-- guessed (see files_without_declaration in data/summary.sql).
declared AS (
    SELECT File_Name AS file_name, Min_Version AS declared_version,
           CASE WHEN Min_Version IS NULL OR NOT regexp_matches(Min_Version, '^[0-9]+(\.[0-9]+){0,2}$') THEN NULL
                ELSE CAST(regexp_extract(Min_Version, '^([0-9]+)', 1) AS INTEGER) * 1000000
                   + COALESCE(TRY_CAST(regexp_extract(Min_Version, '^[0-9]+\.([0-9]+)', 1) AS INTEGER), 0) * 1000
                   + COALESCE(TRY_CAST(regexp_extract(Min_Version, '^[0-9]+\.[0-9]+\.([0-9]+)', 1) AS INTEGER), 0) END AS declared_num
    FROM FileOptionsCatalog
),
-- Axis 1: script steps. Disabled steps count - FileMaker stores them either
-- way, so the file needs the version that knows them.
step_use AS (
    SELECT s.File_Name AS file_name, 'step' AS axis, c.step_id AS ref_id,
           COALESCE(sl.display_name, 'Step ' || c.step_id) AS feature,
           c.originated_in_version AS required_version, c.originated_in_version_num AS required_num,
           count(*) AS usage_count, min(s.Script_Name) AS example_name,
           arg_min(s.Script_UUID, s.Script_Name) AS nav_uuid
    FROM StepsForScripts s
    JOIN ref.step_compat c ON c.step_id = s.Step_ID
    LEFT JOIN ref.script_steps_lang sl ON sl.step_id = c.step_id AND sl.language = 'en'
    WHERE c.originated_in_version_num IS NOT NULL
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY ALL
),
-- Axis 2: built-in functions. Locale-tolerant name resolution as in the
-- platform members (catalog BuiltinFunction names are localized); the usage
-- edge carries the file, so a custom function counts in the file that DEFINES
-- it - no call closure, the definition is what needs the version.
seed_functions AS (
    SELECT fn.Object_UUID, MIN(fl.function_id) AS function_id
    FROM ObjectCatalog fn
    JOIN ref.function_name_lookup fl
      ON replace(lower(fl.lookup_name), ' ', '') = replace(lower(fn.Object_Name), ' ', '')
      OR replace(lower(fl.lookup_name), ' ', '')
         = replace(lower(regexp_extract(fn.Object_Name, '\(\s*(.*?)\s*\)\s*$', 1)), ' ', '')
    WHERE fn.Object_Type = 'BuiltinFunction'
    GROUP BY fn.Object_UUID
),
function_use AS (
    SELECT src.File_Name AS file_name, 'function' AS axis, f.function_id AS ref_id,
           f.canonical_name AS feature,
           f.origin_version AS required_version, f.origin_version_num AS required_num,
           count(*) AS usage_count, min(src.Object_Name) AS example_name,
           arg_min(src.Object_UUID, src.Object_Name) AS nav_uuid
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN seed_functions sf ON ol.Target_UUID = sf.Object_UUID
    JOIN ref.functions f ON f.function_id = sf.function_id
    WHERE ol.Link_Role = 'calls_function'
      AND f.origin_version_num IS NOT NULL
      AND (getvariable('file') IS NULL OR src.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR src.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY ALL
),
-- Axis 3: script triggers. Join over the SaXML slot id, never the localizable
-- action name. since_version_num is the older TWO-part key (major*1000+minor);
-- * 1000 lifts it into the three-part canon exactly.
trigger_use AS (
    SELECT t.File_Name AS file_name, 'trigger' AS axis, tr.trigger_id AS ref_id,
           tr.event_name AS feature,
           tr.since_version AS required_version, tr.since_version_num * 1000 AS required_num,
           count(*) AS usage_count, min(t.Script_Name) AS example_name,
           arg_min(COALESCE(t.Script_UUID, t.Owner_UUID), t.Script_Name) AS nav_uuid
    FROM ScriptTriggers t
    JOIN ref.script_triggers tr ON tr.trigger_id = t.Trigger_ID
    WHERE tr.since_version_num IS NOT NULL
      AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR t.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
           OR t.Owner_UUID  IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY ALL
),
usage AS (
    SELECT * FROM step_use
    UNION ALL SELECT * FROM function_use
    UNION ALL SELECT * FROM trigger_use
),
drivers AS (
    SELECT u.*, d.declared_version, d.declared_num
    FROM usage u
    JOIN declared d ON d.file_name = u.file_name
    WHERE d.declared_num IS NOT NULL
      AND u.required_num > d.declared_num
)
SELECT 'solution-version-floor' AS rule_id, 'warning' AS severity,
    file_name, nav_uuid, axis, feature,
    required_version, declared_version, usage_count,
    example_name,
    feature || ' requires FileMaker ' || required_version
      || ', the file declares ' || declared_version
      || ' as its minimum (' || usage_count || ' use'
      || CASE WHEN usage_count = 1 THEN '' ELSE 's' END || ', e.g. ' || COALESCE(example_name, '-') || ')' AS message,
    row_number() OVER (ORDER BY required_num DESC, file_name, axis, feature) AS row_key
FROM drivers
ORDER BY required_num DESC, file_name, axis, feature
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
