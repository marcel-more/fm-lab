-- Hand-maintained COUNT wrapper embedding the findings core of rule (sort_records_in_loop).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'warning'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT
    'sort-records-in-loop'   AS rule_id,
    'warning' AS severity,
    File_Name     AS file_name,
    Script_UUID   AS nav_uuid,
    Script_Name   AS script_name,
    Step_Index + 1    AS step_no,
    Step_UUID     AS step_uuid,
    CAST(loop_depth_before AS INTEGER) AS loop_depth,
    'Sort Records at step ' || (Step_Index + 1) || ' runs inside a loop (depth '
      || CAST(loop_depth_before AS INTEGER) || ') - executed once per iteration' AS message,
    row_number() OVER (ORDER BY File_Name, Script_Name, Step_Index) AS row_key
FROM v_script_block_tree
WHERE Step_ID = 39 AND loop_depth_before >= 1
  AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY File_Name, Script_Name, Step_Index
) _summary;
