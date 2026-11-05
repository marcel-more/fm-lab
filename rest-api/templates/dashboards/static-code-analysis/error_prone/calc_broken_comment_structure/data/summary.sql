-- Hand-maintained wrapper around the rule core (calc_broken_comment_structure).
WITH slots AS (
    SELECT c.File_Name,
           CASE WHEN c.Owner_Type IN ('CustomFunction', 'Field') THEN c.Owner_UUID END AS nav_uuid,
           c.Owner_UUID AS step_owner,
           c.Owner_Type,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc_text
    FROM CalculationsCatalog c
    WHERE c.Calc_Role IN ('custom_function', 'field_calculation', 'auto_enter', 'validation',
                          'step_parameter', 'step_xslt')
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE calc_text LIKE '%/*/*%') AS nested_open_count,
       COUNT(*) FILTER (WHERE calc_text LIKE '%*/*/%') AS double_close_count,
       COUNT(DISTINCT s.File_Name) AS affected_files
FROM slots s
LEFT JOIN StepsForScripts st ON s.Owner_Type = 'ScriptStep'
     AND st.Step_UUID = s.step_owner AND st.File_Name = s.File_Name
WHERE (s.calc_text LIKE '%/*/*%' OR s.calc_text LIKE '%*/*/%' OR s.calc_text LIKE '%/*//%')
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR COALESCE(s.nav_uuid, st.Script_UUID) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
