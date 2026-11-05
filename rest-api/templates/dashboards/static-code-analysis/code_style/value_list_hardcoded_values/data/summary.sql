-- Hand-maintained COUNT wrapper embedding the findings core of rule (value_list_hardcoded_values).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'value-list-hardcoded-values' AS rule_id, 'info' AS severity,
    File_Name AS file_name, VL_UUID AS nav_uuid, VL_Name AS vl_name,
    'Value list uses hard-coded custom values' AS message,
    row_number() OVER (ORDER BY File_Name, VL_Name) AS row_key
FROM (SELECT DISTINCT File_Name, VL_Name, VL_UUID FROM OptionsForValueLists WHERE Source_Type = 'Custom')
WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
ORDER BY File_Name, VL_Name
) _summary;
