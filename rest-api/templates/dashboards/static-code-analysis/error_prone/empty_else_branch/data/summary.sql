-- Hand-maintained COUNT wrapper embedding the findings core of rule (empty_else_branch).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'warning'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
WITH seq AS (
    SELECT File_Name, Script_ID, Script_UUID, Script_Name, Step_Index, Step_ID, Step_UUID,
        lead(Step_ID) OVER (PARTITION BY File_Name, Script_ID ORDER BY Step_Index) AS next_step
    FROM v_script_block_tree
)
SELECT 'empty-else-branch' AS rule_id, 'warning' AS severity,
    File_Name AS file_name, Script_UUID AS nav_uuid, Script_Name AS script_name,
    Step_Index + 1 AS step_index, Step_UUID AS step_uuid,
    'Empty Else branch at step ' || (Step_Index + 1) AS message,
    row_number() OVER (ORDER BY File_Name, Script_Name, Step_Index) AS row_key
FROM seq
WHERE Step_ID = 69 AND next_step = 70 AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY File_Name, Script_Name, Step_Index
) _summary;
