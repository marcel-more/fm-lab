-- Hand-maintained wrapper around the rule core (window_opened_without_close).
SELECT
    COUNT(*)                    AS finding_count,
    'warning'                   AS severity,
    COUNT(DISTINCT o.File_Name) AS affected_files
FROM StepsForScripts o
WHERE o.Opens_Window AND o.Is_Enabled
  AND NOT EXISTS (
      SELECT 1 FROM StepsForScripts c
      WHERE c.File_Name = o.File_Name AND c.Script_ID = o.Script_ID
        AND c.Step_ID = 121 AND c.Is_Enabled AND c.Step_Index > o.Step_Index)
  AND (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR o.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
