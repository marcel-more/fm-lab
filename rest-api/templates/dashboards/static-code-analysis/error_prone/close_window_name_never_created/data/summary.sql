-- Hand-maintained wrapper around the rule core (close_window_name_never_created).
WITH closes AS (
    SELECT c.File_Name, s.Script_UUID, s.Step_Index,
           COALESCE(c.Formula_Text, c.Display_Text) AS Calc_Text,
           regexp_full_match(COALESCE(c.Formula_Text, c.Display_Text), '"[^"]*"') AS is_literal
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Step_ID = 121 AND c.Source_Path = 'Step/Name' AND s.Is_Enabled
),
producers AS (
    SELECT DISTINCT COALESCE(c.Formula_Text, c.Display_Text) AS Calc_Text
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Is_Enabled
      AND ((s.Step_ID IN (122, 74) AND c.Source_Path = 'Step/Name')
           OR (s.Step_ID = 124 AND c.Source_Path = 'Step/Rename'))
)
SELECT
    COUNT(*)                                  AS finding_count,
    COUNT(*) FILTER (WHERE c.is_literal)      AS dead_cleanup_count,
    COUNT(DISTINCT c.File_Name)               AS affected_files
FROM closes c
LEFT JOIN producers p ON p.Calc_Text = c.Calc_Text
WHERE p.Calc_Text IS NULL
  AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR c.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
