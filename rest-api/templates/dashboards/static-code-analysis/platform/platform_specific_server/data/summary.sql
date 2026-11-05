-- Hand-maintained wrapper embedding the findings core of rule (platform_specific_server).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with
-- data/findings.sql. Core metric is script_count (unit "scripts"): the goal is
-- script identification, not occurrence counting — the dedicated unit keeps the
-- folder/traffic-light consolidation sums clean (results.service only sums
-- within one unit; platform-bound scripts must never mix with error findings).
-- Every target row counts as one script (resolved, external or dynamic — a
-- dynamic row IS a server-executed script, just not statically identifiable).
-- exclusive/dedicated stay 0 here (no such signal source for Server) — the
-- columns are kept for a uniform summary shape across the specific bundles.
SELECT
    COUNT(*) AS script_count,
    0 AS exclusive_scripts,
    0 AS dedicated_scripts,
    COUNT(*) AS contextual_scripts,
    CAST(COALESCE(SUM(usage_count), 0) AS BIGINT) AS evidence_count,
    COUNT(*) FILTER (WHERE target_kind = 'resolved') AS resolved_targets,
    COUNT(*) FILTER (WHERE target_kind = 'external') AS external_targets,
    COUNT(*) FILTER (WHERE target_kind = 'dynamic')  AS dynamic_targets,
    COUNT(DISTINCT file_name) AS affected_files
FROM (
WITH callsites AS (
    SELECT x.File_Name AS file_name, x.Script_UUID AS caller_uuid,
           s.Script_Name AS caller_name, s.Step_Index + 1 AS step_no,
           s.Step_UUID AS step_uuid,
           x.Ref_UUID AS target_uuid, x.Ref_Name AS target_name,
           x.Data_Source_Name AS data_source_name
    FROM XMLStepReferences x
    JOIN StepsForScripts s
      ON s.Step_UUID = x.Step_UUID AND s.Script_UUID = x.Script_UUID
     AND s.File_Name = x.File_Name
    WHERE x.Ref_Type = 'script' AND s.Step_ID IN (164, 210) AND s.Is_Enabled
),
resolved AS (
    SELECT cs.*,
           tgt.Object_UUID AS resolved_uuid, tgt.Object_Name AS resolved_name,
           tgt.File_Name AS resolved_file
    FROM callsites cs
    LEFT JOIN (SELECT DISTINCT Source_UUID, Source_File, Target_UUID, Target_File
               FROM ObjectLinks
               WHERE Link_Role = 'calls_script'
                 AND Link_Subrole IN ('on_server', 'on_server_callback')) e
      ON e.Source_UUID = cs.caller_uuid AND e.Source_File = cs.file_name
     AND e.Target_UUID = cs.target_uuid
    LEFT JOIN ObjectCatalog tgt
      ON tgt.Object_UUID = e.Target_UUID AND tgt.File_Name = e.Target_File
     AND tgt.Object_Type = 'Script'
),
dynamic AS (
    SELECT c.File_Name AS file_name, s.Script_UUID AS caller_uuid,
           s.Script_Name AS caller_name, s.Step_Index + 1 AS step_no,
           c.Owner_UUID AS step_uuid, trim(COALESCE(c.Formula_Text, c.Display_Text)) AS dyn_expr
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Step_ID IN (164, 210) AND s.Is_Enabled AND c.Source_Path = 'Step/List'
),
targets AS (
    SELECT resolved_uuid AS nav_uuid, resolved_name AS script_name,
           resolved_file AS file_name, count(*) AS usage_count,
           'resolved' AS target_kind
    FROM resolved
    WHERE resolved_uuid IS NOT NULL
    GROUP BY resolved_uuid, resolved_name, resolved_file
    UNION ALL
    SELECT CAST(NULL AS VARCHAR),
           COALESCE(target_name, '(unknown script)')
             || COALESCE(' @ ' || data_source_name, ''),
           file_name, count(*), 'external'
    FROM resolved
    WHERE resolved_uuid IS NULL
    GROUP BY 2, file_name
    UNION ALL
    SELECT CAST(NULL AS VARCHAR), COALESCE(dyn_expr, '(calculated name)'),
           file_name, count(*), 'dynamic'
    FROM dynamic
    GROUP BY COALESCE(dyn_expr, '(calculated name)'), file_name
)
SELECT file_name, nav_uuid, usage_count, target_kind
FROM targets
WHERE (getvariable('file') IS NULL OR file_name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
) _summary;
