-- Hand-maintained COUNT wrapper embedding the findings core of rule (empty_script).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'empty-script' AS rule_id, 'info' AS severity,
    sc.File_Name AS file_name, sc.Script_UUID AS nav_uuid, sc.Script_Name AS object_name,
    'Script has no steps' AS message,
    row_number() OVER (ORDER BY sc.File_Name, sc.Script_Name) AS row_key
FROM ScriptCatalog sc
WHERE (sc.Folder_Type IS NULL OR sc.Folder_Type = 'False') AND NOT sc.Is_Separator
  AND NOT EXISTS (SELECT 1 FROM StepsForScripts s WHERE s.Script_UUID = sc.Script_UUID AND s.File_Name = sc.File_Name)
  AND (getvariable('file') IS NULL OR sc.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR sc.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY sc.File_Name, sc.Script_Name
) _summary;
