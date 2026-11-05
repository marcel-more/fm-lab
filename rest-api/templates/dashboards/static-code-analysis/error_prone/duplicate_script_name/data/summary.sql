-- Hand-maintained COUNT wrapper embedding the findings core of rule (duplicate_script_name).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'warning'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
WITH dup AS (
    SELECT File_Name, Script_Name FROM ScriptCatalog
    WHERE (Folder_Type IS NULL OR Folder_Type = 'False') AND NOT Is_Separator
    GROUP BY File_Name, Script_Name HAVING COUNT(*) > 1
)
SELECT 'duplicate-script-name' AS rule_id, 'warning' AS severity,
    sc.File_Name AS file_name, sc.Script_UUID AS nav_uuid, sc.Script_Name AS script_name,
    'Script name occurs more than once in this file' AS message,
    row_number() OVER (ORDER BY sc.File_Name, sc.Script_Name, sc.Script_ID) AS row_key
FROM ScriptCatalog sc
JOIN dup ON dup.File_Name = sc.File_Name AND dup.Script_Name = sc.Script_Name
WHERE (sc.Folder_Type IS NULL OR sc.Folder_Type = 'False') AND NOT sc.Is_Separator
  AND (getvariable('file') IS NULL OR sc.File_Name = getvariable('file'))
ORDER BY file_name, script_name
) _summary;
