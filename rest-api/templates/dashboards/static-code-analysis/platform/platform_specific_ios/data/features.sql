-- Feature breakdown of the iOS usage profile: WHICH iOS features bind the
-- scripts — one row per feature (exclusive step / dedicated function, the
-- CF-wrapped variants collapse onto their builtin function). Same core as
-- data/findings.sql (textual copy convention — keep the CTEs and scope
-- filters in sync); the findings list answers "which scripts", this dataset
-- answers "through what".
WITH RECURSIVE affinity AS (
    SELECT function_id, affinity
    FROM ref.function_platform_affinity
    WHERE platform = 'go'
),
step_evidence AS (
    SELECT s.File_Name AS file_name, s.Script_UUID AS nav_uuid,
           'step' AS evidence_kind, 'exclusive' AS signal,
           COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS feature,
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
           'function' AS evidence_kind, a.affinity AS signal,
           COALESCE(f.canonical_name, 'Function ' || sf.function_id) AS feature,
           f.url_slug AS doc_slug, count(*) AS usage_count
    FROM ObjectLinks ol
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN seed_functions sf ON ol.Target_UUID = sf.Object_UUID
    JOIN affinity a ON a.function_id = sf.function_id
    LEFT JOIN ref.functions f ON f.function_id = sf.function_id
    WHERE ol.Link_Role = 'calls_function' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, a.affinity, f.canonical_name,
             sf.function_id, f.url_slug
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
           'function' AS evidence_kind, a.affinity AS signal,
           COALESCE(f.canonical_name, 'Function ' || cc.function_id) AS feature,
           f.url_slug AS doc_slug, count(*) AS usage_count
    FROM ObjectLinks ol
    JOIN (SELECT DISTINCT cf_uuid, function_id FROM cf_closure) cc
      ON ol.Target_UUID = cc.cf_uuid
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
    JOIN affinity a ON a.function_id = cc.function_id
    LEFT JOIN ref.functions f ON f.function_id = cc.function_id
    WHERE ol.Link_Role = 'calls_customfunction' AND src.Object_Type = 'Script'
    GROUP BY src.File_Name, src.Object_UUID, a.affinity, f.canonical_name,
             cc.function_id, f.url_slug
),
evidence AS (
    SELECT * FROM step_evidence
    UNION ALL
    SELECT * FROM function_evidence
    UNION ALL
    SELECT * FROM cf_evidence
)
SELECT feature, evidence_kind, signal, doc_slug,
    COUNT(DISTINCT nav_uuid) AS script_count,
    CAST(SUM(usage_count) AS BIGINT) AS usage_count,
    COUNT(DISTINCT file_name) AS affected_files,
    row_number() OVER (ORDER BY COUNT(DISTINCT nav_uuid) DESC, feature) AS row_key
FROM evidence
WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
GROUP BY feature, evidence_kind, signal, doc_slug
ORDER BY script_count DESC, feature;
