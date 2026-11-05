-- Hand-maintained COUNT wrapper embedding the findings core of rule (loop_without_exit_loop_if).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
WITH auto_exit AS (
    SELECT DISTINCT t.File_Name, t.Script_ID
    FROM v_script_block_tree t
    JOIN StepsForScripts s ON s.Step_UUID = t.Step_UUID AND s.File_Name = t.File_Name
    WHERE t.Step_ID IN (16, 99)
      AND t.loop_depth_before >= 1
      AND regexp_matches(s.Step_XML, 'value="[34]">\s*<Boolean[^>]*value="True"')
),
loops AS (
    SELECT File_Name, Script_ID,
        any_value(Script_UUID) AS nav_uuid,
        any_value(Script_Name) AS script_name,
        COUNT(*) FILTER (WHERE Step_ID = 71) AS loop_count,
        COUNT(*) FILTER (WHERE Step_ID = 72) AS exit_if_count
    FROM v_script_block_tree
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY File_Name, Script_ID
)
SELECT 'loop-without-exit-loop-if' AS rule_id, 'info' AS severity,
    l.File_Name AS file_name, l.nav_uuid, l.script_name,
    l.loop_count,
    'Loop(s) with no Exit Loop If and no auto-exit Go to Record/Portal Row' AS message,
    row_number() OVER (ORDER BY l.File_Name, l.script_name) AS row_key
FROM loops l
LEFT JOIN auto_exit a ON a.File_Name = l.File_Name AND a.Script_ID = l.Script_ID
WHERE l.loop_count > 0 AND l.exit_if_count = 0 AND a.Script_ID IS NULL
ORDER BY file_name, script_name
) _summary;
