-- @title: Bounded plain-text step dump of one script (R2 anchor scripts)
-- @description: Cookbook "Script dump" pattern with a hard cap — DDR text where the export
--               carries DDR-Info, else the (localised) step name; nesting from v_script_block_tree.
-- @version: 1.1.0
-- @tags: script, steps, report
-- @note: read-only. Variables: file, script (required) · max_steps (default 25 — a pattern is recognisable after ~10 steps).
--        Locale caveat: never gate logic on Step_Name literals (use Step_ID).
SELECT lpad(CAST(s.Step_Index + 1 AS VARCHAR), 3, ' ')
       || ' ' || repeat('   ', CAST(COALESCE(t.block_depth_before, 0) AS INT))
       || COALESCE(d.Step_Text, s.Step_Name)
       || CASE WHEN s.Is_Enabled = false THEN '   <<disabled>>' ELSE '' END AS step
FROM StepsForScripts s
LEFT JOIN DDR_ScriptSteps     d ON d.Step_UUID = s.Step_UUID
LEFT JOIN v_script_block_tree t ON t.Step_UUID = s.Step_UUID
WHERE s.File_Name = getvariable('file') AND s.Script_Name = getvariable('script')
ORDER BY s.Step_Index
LIMIT (COALESCE(getvariable('max_steps'), 25));
