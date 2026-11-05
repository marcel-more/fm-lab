-- Hand-maintained COUNT wrapper embedding the findings core of rule (allow_user_abort_off).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'allow-user-abort-off' AS rule_id, 'info' AS severity,
    b.File_Name AS file_name, b.Script_UUID AS nav_uuid, b.Script_Name AS script_name,
    b.Step_Index + 1 AS step_index, b.Step_UUID AS step_uuid,
    'Allow User Abort [Off] at step ' || (b.Step_Index + 1) AS message,
    row_number() OVER (ORDER BY b.File_Name, b.Script_Name, b.Step_Index) AS row_key
FROM v_script_block_tree b
JOIN StepsForScripts s ON s.Step_UUID = b.Step_UUID AND s.File_Name = b.File_Name
WHERE b.Step_ID = 85 AND s.Boolean_Value = 'False' AND (getvariable('file') IS NULL OR b.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR b.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY b.File_Name, b.Script_Name, b.Step_Index
) _summary;
