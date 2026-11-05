-- Hand-maintained COUNT wrapper for rule (freeze_window_then_pause).
-- Keep filters (file filter + scope block) in sync with data/findings.sql.
WITH freezes AS (
    SELECT File_Name, Script_UUID, min(Step_Index) AS freeze_index
    FROM StepsForScripts
    WHERE Step_ID = 79 AND Is_Enabled
    GROUP BY 1, 2
)
SELECT
    COUNT(*) AS finding_count,
    'warning' AS severity,
    COUNT(DISTINCT f.File_Name) AS affected_files
FROM freezes f
WHERE EXISTS (
        SELECT 1 FROM StepsForScripts p
        WHERE p.File_Name = f.File_Name AND p.Script_UUID = f.Script_UUID
          AND p.Step_ID = 62 AND p.Is_Enabled AND p.Step_Index > f.freeze_index
      )
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR f.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
