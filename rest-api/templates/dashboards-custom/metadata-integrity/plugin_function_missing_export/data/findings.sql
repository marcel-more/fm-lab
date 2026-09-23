-- Formulas that lost a plug-in function at EXPORT time. When a plug-in is not
-- loaded on the client that saves the XML, FileMaker replaces the function name
-- in the formula text itself with the placeholder <Function Missing> (and tags
-- the DDR chunk as VariableReference 'Function Missing'). The call is gone from
-- the export: no PluginFunction object, no calls_pluginfunction edge, and the
-- formula text no longer says which plug-in it was.
--
-- Detection reads the formula TEXT (CalculationsCatalog.Formula_Text), so the
-- rule works with and without DDR info — the DDR-chunk view of the same defect
-- (P6 v_check_function_missing) is blind on files exported without DDR info.
--
-- Navigation: a ScriptStep-owned calculation navigates to its SCRIPT
-- (Owner_UUID is the Step_UUID; StepsForScripts resolves Script_UUID and the
-- 1-based step number; `step_uuid`/`marks` anchor the step in the detail view).
-- Other owners (custom function, field, layout object, …) navigate directly.
-- formula_excerpt keeps the surrounding arguments — often the only hint which
-- plug-in it was ("-Encoding=ASCII_Windows", "enable", …).
--
-- No fix inside fm-lab: re-export on a client with the plug-in installed.
WITH calc AS (
    SELECT c.Calculation_UUID, c.Owner_UUID, c.Owner_Type, c.Owner_Name, c.Calc_Role,
           c.File_Name, c.Formula_Text,
           (length(c.Formula_Text) - length(replace(c.Formula_Text, '<Function Missing>', '')))
             // length('<Function Missing>') AS missing_count
    FROM CalculationsCatalog c
    WHERE c.Formula_Text LIKE '%<Function Missing>%'
),
owner AS (
    SELECT k.*,
           COALESCE(s.Script_UUID, k.Owner_UUID) AS nav_uuid,
           CASE WHEN s.Step_UUID IS NOT NULL THEN 'Script' ELSE k.Owner_Type END AS nav_type,
           COALESCE(s.Script_Name, k.Owner_Name) AS nav_name,
           s.Step_Index + 1 AS step_no,
           s.Step_UUID AS step_uuid
    FROM calc k
    LEFT JOIN StepsForScripts s ON s.Step_UUID = k.Owner_UUID AND s.File_Name = k.File_Name
)
SELECT
    'plugin-function-missing-export' AS rule_id,
    'warning' AS severity,
    o.nav_uuid,
    o.nav_type AS type,
    o.nav_name AS name,
    o.File_Name AS file,
    o.Owner_Type AS owner_type,
    o.Calc_Role AS calc_role,
    o.step_no,
    o.step_uuid,
    o.step_uuid AS marks,
    o.missing_count,
    substr(regexp_replace(o.Formula_Text, '\s+', ' ', 'g'), 1, 120) AS formula_excerpt,
    'Plug-in function missing at export time — ' || o.missing_count
      || ' call(s) replaced by <Function Missing> in ' || o.Calc_Role
      || CASE WHEN o.step_no IS NOT NULL THEN ' (step ' || o.step_no || ')' ELSE '' END
      || '; the plug-in was not loaded on the exporting client — re-export with the plug-in installed' AS message,
    row_number() OVER (ORDER BY o.File_Name, o.nav_name, o.step_no, o.Calc_Role) AS row_key
FROM owner o
WHERE (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR o.nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY o.File_Name, o.nav_name, o.step_no, o.Calc_Role
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
