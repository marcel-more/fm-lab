-- Hand-maintained COUNT wrapper embedding the findings core of rule (onrecordload_trigger).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'onrecordload-trigger' AS rule_id, 'info' AS severity,
    File_Name AS file_name, Script_UUID AS nav_uuid, Script_Name AS script_name, Owner_Type AS owner_type,
    'OnRecordLoad trigger runs the script for every record' AS message,
    row_number() OVER (ORDER BY File_Name, Script_Name) AS row_key
FROM ScriptTriggers
WHERE Trigger_Action = 'OnRecordLoad' AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY File_Name, Script_Name
) _summary;
