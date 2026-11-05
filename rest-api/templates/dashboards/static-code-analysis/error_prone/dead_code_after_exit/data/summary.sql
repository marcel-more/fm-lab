-- Hand-maintained wrapper around the rule core (dead_code_after_exit).
SELECT
    COUNT(*)                  AS finding_count,
    'warning'                 AS severity,
    COUNT(DISTINCT file_name) AS affected_files
FROM (
SELECT File_Name AS file_name
FROM (
    SELECT File_Name, Script_UUID, Step_Index, Step_ID,
           lead(Step_ID) OVER w AS dead_id
    FROM v_script_block_tree
    WHERE Is_Enabled AND Step_ID <> 89
    WINDOW w AS (PARTITION BY File_Name, Script_ID ORDER BY Step_Index)
) t
WHERE Step_ID IN (103, 90)
  AND dead_id IS NOT NULL
  AND dead_id NOT IN (69, 70, 73, 125)
  AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
) _summary;
