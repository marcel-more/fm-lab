SELECT
    'open-url-in-loop'   AS rule_id,
    'warning' AS severity,
    File_Name     AS file_name,
    Script_UUID   AS nav_uuid,
    Script_Name   AS script_name,
    Step_Index + 1    AS step_no,
    Step_UUID     AS step_uuid,
    CAST(loop_depth_before AS INTEGER) AS loop_depth,
    'Open URL at step ' || (Step_Index + 1) || ' runs inside a loop (depth '
      || CAST(loop_depth_before AS INTEGER) || ') - executed once per iteration' AS message,
    row_number() OVER (ORDER BY File_Name, Script_Name, Step_Index) AS row_key
FROM v_script_block_tree
WHERE Step_ID = 111 AND loop_depth_before >= 1
  AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY File_Name, Script_Name, Step_Index
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
