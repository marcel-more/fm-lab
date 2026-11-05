-- Hand-maintained COUNT wrapper embedding the findings core of rule (find_without_error_capture).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'find-without-error-capture' AS rule_id, 'info' AS severity,
    File_Name AS file_name, any_value(Script_UUID) AS nav_uuid, any_value(Script_Name) AS script_name,
    COUNT(*) FILTER (WHERE Step_ID = 28) AS find_count,
    'Perform Find without Set Error Capture' AS message,
    row_number() OVER (ORDER BY File_Name, any_value(Script_Name)) AS row_key
FROM StepsForScripts
WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
GROUP BY File_Name, Script_ID
HAVING COUNT(*) FILTER (WHERE Step_ID = 28) > 0 AND COUNT(*) FILTER (WHERE Step_ID = 86) = 0
ORDER BY file_name, script_name
) _summary;
