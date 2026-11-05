-- Hand-maintained COUNT wrapper embedding the findings core of rule
-- (find_mode_after_layout_switch). Keep filters (file filter + scope block)
-- in sync with data/findings.sql.
WITH enabled AS (
    SELECT File_Name, Script_UUID, Step_Index, Step_ID,
           row_number() OVER (PARTITION BY File_Name, Script_UUID ORDER BY Step_Index) AS seq
    FROM StepsForScripts
    WHERE Is_Enabled AND Step_ID <> 89
)
SELECT
    COUNT(*) AS finding_count,
    'warning' AS severity,
    COUNT(DISTINCT g.Script_UUID) AS affected_scripts,
    COUNT(DISTINCT g.File_Name) AS affected_files
FROM enabled g
JOIN enabled e
  ON g.File_Name = e.File_Name AND g.Script_UUID = e.Script_UUID AND e.seq = g.seq + 1
WHERE g.Step_ID = 6 AND e.Step_ID = 22
  AND (getvariable('file') IS NULL OR g.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR g.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
