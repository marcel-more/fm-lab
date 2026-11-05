-- Feeds the KPI strip and the scope filter chips (true totals, uncapped).
-- count_active = enabled dialog steps inside a loop; count_all also counts
-- disabled (inactive) ones. finding_count / affected_files follow the chip.
WITH f AS (
    SELECT t.File_Name, s.Is_Enabled
    FROM v_script_block_tree t
    JOIN StepsForScripts s ON s.Step_UUID = t.Step_UUID AND s.File_Name = t.File_Name
    WHERE t.Step_ID = 87 AND t.loop_depth_before >= 1
      AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR t.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
sel AS (SELECT COALESCE(getvariable('scope'), 'active') = 'all' AS want_all)
SELECT
    COUNT(*) FILTER (WHERE Is_Enabled) AS count_active,
    COUNT(*)                           AS count_all,
    CASE WHEN (SELECT want_all FROM sel) THEN COUNT(*)
         ELSE COUNT(*) FILTER (WHERE Is_Enabled) END AS finding_count,
    'warning' AS severity,
    CASE WHEN (SELECT want_all FROM sel) THEN COUNT(DISTINCT File_Name)
         ELSE COUNT(DISTINCT File_Name) FILTER (WHERE Is_Enabled) END AS affected_files
FROM f;
