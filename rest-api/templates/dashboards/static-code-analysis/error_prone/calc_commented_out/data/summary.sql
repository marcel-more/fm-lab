-- Hand-maintained wrapper around the rule core (calc_commented_out).
-- The calc_slot filter is deliberately NOT applied here — the per-slot counts
-- feed the chip badges, which must always show the true per-slot totals.
WITH slots AS (
    SELECT c.File_Name,
           CASE WHEN c.Owner_Type IN ('CustomFunction', 'Field') THEN c.Owner_UUID END AS nav_uuid,
           CASE c.Calc_Role
                WHEN 'custom_function' THEN 'custom-function'
                WHEN 'field_calculation' THEN 'field-calculation'
                WHEN 'auto_enter' THEN 'auto-enter'
                WHEN 'validation' THEN 'validation'
                ELSE 'script-step' END AS calc_slot,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc_text,
           c.Owner_UUID AS step_owner
    FROM CalculationsCatalog c
    WHERE c.Calc_Role IN ('custom_function', 'field_calculation', 'auto_enter', 'validation',
                          'step_parameter', 'step_xslt')
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'custom-function')   AS custom_function_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'field-calculation') AS field_calculation_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'auto-enter')        AS auto_enter_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'validation')        AS validation_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'script-step')       AS script_step_count,
       COUNT(DISTINCT s.File_Name) AS affected_files
FROM slots s
LEFT JOIN StepsForScripts st ON s.calc_slot = 'script-step'
     AND st.Step_UUID = s.step_owner AND st.File_Name = s.File_Name
WHERE trim(s.calc_text) LIKE '/*%' AND trim(s.calc_text) LIKE '%*/'
  AND (length(trim(s.calc_text)) - length(replace(trim(s.calc_text), '/*', ''))) / 2 = 1
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR COALESCE(s.nav_uuid, st.Script_UUID) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
