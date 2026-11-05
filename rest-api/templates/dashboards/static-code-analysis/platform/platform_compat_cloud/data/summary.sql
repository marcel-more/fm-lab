-- Hand-maintained COUNT wrapper embedding the findings core of rule (platform_compat_cloud).
-- The core is a textual copy - keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*) AS finding_count,
    COUNT(*) FILTER (WHERE severity = 'error')   AS not_supported,
    COUNT(*) FILTER (WHERE severity = 'warning') AS partial_support,
    COUNT(*) FILTER (WHERE severity = 'info')    AS no_statement,
    COUNT(DISTINCT file_name) AS affected_files
FROM (
SELECT 'platform-cloud' AS rule_id,
    CASE WHEN c.step_id IS NULL THEN 'info'
         WHEN c.cloud = false THEN 'error'
         ELSE 'warning' END AS severity,
    s.File_Name AS file_name, s.Script_UUID AS nav_uuid, s.Script_Name AS script_name,
    s.Step_Index + 1 AS step_no, s.Step_UUID AS step_uuid,
    COALESCE(st.canonical_name, 'Step ' || s.Step_ID) AS step_name,
    st.url_slug AS doc_slug,
    CASE WHEN c.step_id IS NULL
         THEN COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' has no published compatibility row for FileMaker Cloud (genuine gap in the Claris table)'
         WHEN c.cloud = false
         THEN COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' does not run on FileMaker Cloud'
         ELSE COALESCE(st.canonical_name, 'Step ' || s.Step_ID) || ' is PARTIALLY supported on FileMaker Cloud - conditionally supported, see the step notes on its Claris help page'
    END AS message,
    row_number() OVER (ORDER BY s.File_Name, s.Script_Name, s.Step_Index) AS row_key
FROM StepsForScripts s
LEFT JOIN ref.script_steps st ON st.step_id = s.Step_ID
LEFT JOIN ref.step_compat c ON c.step_id = s.Step_ID
WHERE s.Is_Enabled
  AND s.Step_ID <> 89  -- "# (comment)"
  AND (c.step_id IS NULL OR c.cloud = false OR c.cloud IS NULL)
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
) _summary;
