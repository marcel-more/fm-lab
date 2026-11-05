-- Hand-maintained wrapper around the rule core (calc_comment_todo).
-- Keep the slot list, the detector and the filters in sync with
-- data/findings.sql.
WITH slots AS (
    SELECT c.File_Name,
           CASE c.Calc_Role
                WHEN 'custom_function' THEN 'custom_function'
                WHEN 'field_calculation' THEN 'field_calc'
                WHEN 'auto_enter' THEN 'field_autoenter'
                WHEN 'validation' THEN 'field_validation'
                ELSE 'script_step' END AS slot,
           CASE WHEN c.Owner_Type IN ('CustomFunction', 'Field') THEN c.Owner_UUID END AS nav_uuid,
           c.Owner_UUID AS step_owner,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc
    FROM CalculationsCatalog c
    WHERE c.Calc_Role IN ('custom_function', 'field_calculation', 'auto_enter', 'validation',
                          'step_parameter', 'step_xslt')
),
marked AS (
    SELECT *, list_filter(regexp_extract_all(calc, '(?s)/\*.*?\*/|//[^\n\r]*'),
                          lambda seg: regexp_matches(seg, '(?i)(\bto[\s\-_]?do|\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)')) AS segments
    FROM slots
)
SELECT
    COUNT(*) AS finding_count,
    COUNT(*) FILTER (WHERE m.slot = 'custom_function') AS custom_function_count,
    COUNT(*) FILTER (WHERE m.slot IN ('field_calc', 'field_autoenter', 'field_validation')) AS field_count,
    COUNT(*) FILTER (WHERE m.slot = 'script_step') AS script_step_count,
    COUNT(DISTINCT m.File_Name) AS affected_files
FROM marked m
LEFT JOIN StepsForScripts st ON m.slot = 'script_step'
     AND st.Step_UUID = m.step_owner AND st.File_Name = m.File_Name
WHERE len(m.segments) > 0
  AND (getvariable('file') IS NULL OR m.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR COALESCE(m.nav_uuid, st.Script_UUID) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
