-- Hand-maintained wrapper embedding the findings core of rule (platform_specific_ios).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with
-- data/findings.sql. Core metric is script_count (unit "scripts"): the goal is
-- script identification, not occurrence counting — the dedicated unit keeps the
-- folder/traffic-light consolidation sums clean (results.service only sums
-- within one unit; platform-bound scripts must never mix with error findings).
SELECT
    COUNT(DISTINCT nav_uuid) AS script_count,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE binding = 'exclusive')  AS exclusive_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE binding = 'dedicated')  AS dedicated_scripts,
    COUNT(DISTINCT nav_uuid) FILTER (WHERE binding = 'contextual') AS contextual_scripts,
    COUNT(*) AS evidence_count,
    COUNT(DISTINCT file_name) AS affected_files
FROM (
WITH RECURSIVE affinity AS (
    SELECT function_id, affinity
    FROM ref.function_platform_affinity
    WHERE platform = 'go'
),
step_evidence AS (
    SELECT s.File_Name AS file_name, s.Script_UUID AS nav_uuid,
           s.Script_Name AS script_name,
           'step' AS evidence_kind, 'exclusive' AS signal,
           COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS feature,
           s.Step_Index + 1 AS step_no, s.Step_UUID AS step_uuid,
           st.url_slug AS doc_slug, 1 AS usage_count
    FROM StepsForScripts s
    JOIN ref.step_compat c ON c.step_id = s.Step_ID
    LEFT JOIN ref.script_steps st ON st.step_id = s.Step_ID
    WHERE s.Is_Enabled
      AND c.go = true AND c.pro = false AND c.server = false
      AND c.webdirect = false AND c.cloud = false AND c.dataapi = false
      AND c.cwp = false
),
seed_functions AS (
    SELECT fn.Object_UUID, MIN(fl.function_id) AS function_id
    FROM ObjectCatalog fn
    JOIN ref.function_name_lookup fl
      ON replace(lower(fl.lookup_name), ' ', '') = replace(lower(fn.Object_Name), ' ', '')
      OR replace(lower(fl.lookup_name), ' ', '')
         = replace(lower(regexp_extract(fn.Object_Name, '\(\s*(.*?)\s*\)\s*$', 1)), ' ', '')
    JOIN affinity a ON a.function_id = fl.function_id
    WHERE fn.Object_Type = 'BuiltinFunction'
    GROUP BY fn.Object_UUID
),
function_evidence AS (
    SELECT src.File_Name AS file_name, src.Object_UUID AS nav_uuid,
           src.Object_Name AS script_name,
           'function' AS evidence_kind, a.affinity AS signal,
           COALESCE(f.canonical_name, 'Function ' || sf.function_id) AS feature,
           CAST(NULL AS INTEGER) AS step_no, CAST(NULL AS VARCHAR) AS step_uuid,
           f.url_slug AS doc_slug, count(*) AS usage_count
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN seed_functions sf ON ol.Target_UUID = sf.Object_UUID
    JOIN affinity a ON a.function_id = sf.function_id
    LEFT JOIN ref.functions f ON f.function_id = sf.function_id
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, src.Object_Name, a.affinity,
             f.canonical_name, sf.function_id, f.url_slug
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
           src.Object_Name AS script_name,
           'function' AS evidence_kind, a.affinity AS signal,
           COALESCE(f.canonical_name, 'Function ' || cc.function_id)
             || ' (via CF ' || cf.Object_Name || ')' AS feature,
           CAST(NULL AS INTEGER) AS step_no, CAST(NULL AS VARCHAR) AS step_uuid,
           f.url_slug AS doc_slug, count(*) AS usage_count
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM cf_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog cf ON cc.cf_uuid = cf.Object_UUID AND cf.Object_Type = 'CustomFunction'
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN affinity a ON a.function_id = cc.function_id
    LEFT JOIN ref.functions f ON f.function_id = cc.function_id
    WHERE ol.Link_Role = 'calls_customfunction' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, src.Object_Name, a.affinity,
             f.canonical_name, cc.function_id, cf.Object_Name, f.url_slug
),
evidence AS (
    SELECT * FROM step_evidence
    UNION ALL
    SELECT * FROM function_evidence
    UNION ALL
    SELECT * FROM cf_evidence
),
ranked AS (
    SELECT e.*,
           MIN(CASE e.signal WHEN 'exclusive' THEN 1 WHEN 'dedicated' THEN 2 ELSE 3 END)
               OVER (PARTITION BY e.nav_uuid) AS binding_rank
    FROM evidence e
)
SELECT file_name, nav_uuid,
    CASE binding_rank WHEN 1 THEN 'exclusive' WHEN 2 THEN 'dedicated'
         ELSE 'contextual' END AS binding
FROM ranked
WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
) _summary;
