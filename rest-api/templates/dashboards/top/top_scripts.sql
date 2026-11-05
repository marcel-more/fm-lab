-- @template_type: report
-- @title: Top scripts
-- @description: Scripts with the most steps.
-- @icon: script
-- @display: table
-- @params: limit (optional, default 100), file (optional)
-- @click_action: openObject
-- @click_args: uuid={{uuid}}&type=Script
-- @output_format: uuid, name, file, step_count
-- @object_types: Script
-- @author: fm-lab core
-- @version: 1.2
-- @tags: scripts, top, ranking

WITH scored AS (
    SELECT
        s.Script_UUID            AS uuid,
        s.Script_Name            AS name,
        s.File_Name              AS file,
        COUNT(st.Step_UUID)      AS step_count
    FROM ScriptCatalog s
    LEFT JOIN StepsForScripts st
           ON st.Script_UUID = s.Script_UUID AND st.File_Name = s.File_Name
    WHERE (s.Folder_Type IS NULL)
      AND NOT s.Is_Separator
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
    GROUP BY ALL
)
SELECT uuid, name, file, step_count
FROM scored
WHERE step_count > 0
ORDER BY step_count DESC, name, file, uuid   -- tie-breakers: stable rows at the LIMIT
LIMIT CAST(COALESCE(getvariable('limit'), '100') AS INTEGER);
