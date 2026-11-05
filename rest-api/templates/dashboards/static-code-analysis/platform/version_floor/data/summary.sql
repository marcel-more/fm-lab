-- KPI row of the version floor. The CTE chain is a textual copy of
-- data/findings.sql - keep filters (file filter + scope block) in sync. Beyond
-- the finding count it answers the neutral question too: which FileMaker
-- version does the scope actually need (effective_version = the maximum over
-- all three axes, whether or not any file declares less), and how many files
-- carry no readable declaration to compare against.
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
, effective AS (
    SELECT arg_max(required_version, required_num) AS effective_version,
           max(required_num) AS effective_num
    FROM usage
),
undeclared AS (
    SELECT count(*) AS files_without_declaration
    FROM declared d
    WHERE d.declared_num IS NULL
      AND (getvariable('file') IS NULL OR d.file_name = getvariable('file'))
      AND EXISTS (SELECT 1 FROM usage u WHERE u.file_name = d.file_name)
)
SELECT
    (SELECT count(*) FROM drivers) AS finding_count,
    (SELECT count(DISTINCT file_name) FROM drivers) AS affected_files,
    (SELECT effective_version FROM effective) AS effective_version,
    (SELECT count(*) FROM drivers WHERE axis = 'step') AS steps,
    (SELECT count(*) FROM drivers WHERE axis = 'function') AS functions,
    (SELECT count(*) FROM drivers WHERE axis = 'trigger') AS triggers,
    (SELECT files_without_declaration FROM undeclared) AS files_without_declaration;
