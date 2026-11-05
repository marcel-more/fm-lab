-- @template_type: report
-- @title: Script complexity per file
-- @description: Aggregated script statistics (count, average / max steps).
-- @icon: chart
-- @display: table
-- @params: none
-- @output_format: file_name, script_count, avg_steps, max_steps, total_steps
-- @object_types: Script
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "file_count", "meaning": "Files with script statistics (inventory — informational, not a defect count)" }
-- @author: Marcel
-- @version: 1.3
-- @tags: scripts, statistics, complexity

SELECT
    sc.File_Name as file_name,
    COUNT(DISTINCT sc.Script_UUID) as script_count,
    CAST(AVG(step_counts.step_count) AS INTEGER) as avg_steps,
    MAX(step_counts.step_count) as max_steps,
    SUM(step_counts.step_count) as total_steps
FROM ScriptCatalog sc
LEFT JOIN (
    SELECT File_Name, Script_UUID, COUNT(*) as step_count
    FROM StepsForScripts
    GROUP BY File_Name, Script_UUID
) step_counts ON sc.Script_UUID = step_counts.Script_UUID AND sc.File_Name = step_counts.File_Name
WHERE sc.Folder_Type IS NULL OR sc.Folder_Type = 'False'
GROUP BY sc.File_Name
ORDER BY total_steps DESC;
