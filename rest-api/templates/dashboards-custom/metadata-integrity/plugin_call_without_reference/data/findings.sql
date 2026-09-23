-- Plug-in calls that never became a reference although the file was exported
-- WITH DDR info: the formula text calls a plug-in, yet the calculation
-- instance carries no calls_pluginfunction link (v_calculation_links — per
-- instance, derived from the owner edges at import), or one of its calls has
-- a dynamic function name. These calls are invisible to where-used, the
-- plug-in inventory, the platform tests and the docs counters — and nothing
-- else points at them.
--
-- Files exported WITHOUT DDR info are excluded on purpose: every plug-in call
-- in such a file is unresolved for the same file-level reason, which the
-- companion rule export_ddr_missing reports once per file (with the number of
-- affected formulas). Listing them here per formula would repeat that one
-- finding hundreds of times and bury the real hits; the summary shows the
-- excluded files as a counter instead.
--
-- Cause classification (chip `cause`):
--   dynamic-name  MBS($name; …) — the function name is not a literal, so the
--                 converter cannot pair a target (MBS_SubnameMap.SubName IS
--                 NULL) and drops the call from objects AND edges. The formula
--                 may still carry a link from a sibling literal call; it is
--                 listed because one of its calls is lost. info — a code
--                 style the static analysis cannot follow, not an export
--                 defect.
--   unresolved    DDR info present, no usage row, not dynamic — the chunk
--                 pairing failed. Converter blind spot: report the formula.
--                 warning.
--
-- Vocabulary: the MBS literal plus every plug-in prefix the catalog itself
-- knows (PluginFunctionUsages) — deliberately without plugin_spec, so the rule
-- never skips for a missing reference DB. Calls inside /* … */ or // comments
-- do not count (measured false-positive class, reported as comment_only). A
-- plug-in call inside a string literal (Evaluate("MBS(…")) matches the text
-- pattern but is no call — the one known residual false-positive class.
--
-- Navigation as in plugin_function_missing_export: ScriptStep-owned formulas
-- open the script with `step_uuid`/`marks`, other owners open directly.
WITH prefixes AS (
    SELECT 'MBS' AS p
    UNION
    SELECT DISTINCT split_part(Plugin_Function_Name, ':', 1)
    FROM PluginFunctionUsages
    WHERE Plugin_Function_Name IS NOT NULL AND Plugin_Function_Name <> ''
),
calc AS (
    SELECT c.Calculation_UUID, c.Owner_UUID, c.Owner_Type, c.Owner_Name, c.Calc_Role,
           c.File_Name, c.Formula_Text, c.DDR_Calc_UUID,
           regexp_replace(regexp_replace(c.Formula_Text, '(?s)/\*.*?\*/', '', 'g'),
                          '//[^\n]*', '', 'g') AS code_text
    FROM CalculationsCatalog c
    JOIN FilesCatalog f USING (File_Name)
    WHERE COALESCE(f.Has_DDR_INFO, FALSE)                       -- DDR-less files → export_ddr_missing
      AND c.Formula_Text NOT LIKE '%<Function Missing>%'        -- → plugin_function_missing_export
      AND EXISTS (SELECT 1 FROM prefixes p
                  WHERE regexp_matches(c.Formula_Text, '\b' || p.p || '\s*\('))
),
classified AS (
    SELECT k.*,
           EXISTS (SELECT 1 FROM prefixes p
                   WHERE regexp_matches(k.code_text, '\b' || p.p || '\s*\(')) AS in_code,
           EXISTS (SELECT 1 FROM v_calculation_links l
                   WHERE l.Calculation_UUID = k.Calculation_UUID
                     AND l.Target_Type = 'PluginFunction') AS has_link,
           EXISTS (SELECT 1 FROM PluginFunctionUsages u
                   LEFT JOIN MBS_SubnameMap m
                          ON m.Calc_UUID = u.Calc_UUID AND m.File_Name = u.File_Name
                         AND m.Plugin_Chunk_Index = u.Plugin_Chunk_Index
                   WHERE u.Calc_UUID = k.DDR_Calc_UUID AND u.File_Name = k.File_Name
                     AND u.Plugin_Function_Name = 'MBS' AND m.SubName IS NULL) AS has_dynamic
    FROM calc k
),
owner AS (
    SELECT k.*,
           COALESCE(s.Script_UUID, k.Owner_UUID) AS nav_uuid,
           CASE WHEN s.Step_UUID IS NOT NULL THEN 'Script' ELSE k.Owner_Type END AS nav_type,
           COALESCE(s.Script_Name, k.Owner_Name) AS nav_name,
           s.Step_Index + 1 AS step_no,
           s.Step_UUID AS step_uuid,
           CASE WHEN k.has_dynamic THEN 'dynamic-name' ELSE 'unresolved' END AS cause
    FROM classified k
    LEFT JOIN StepsForScripts s ON s.Step_UUID = k.Owner_UUID AND s.File_Name = k.File_Name
    WHERE k.in_code AND (NOT k.has_link OR k.has_dynamic)
)
SELECT
    'plugin-call-without-reference' AS rule_id,
    CASE o.cause WHEN 'dynamic-name' THEN 'info' ELSE 'warning' END AS severity,
    o.nav_uuid,
    o.nav_type AS type,
    o.nav_name AS name,
    o.File_Name AS file,
    o.cause,
    o.Owner_Type AS owner_type,
    o.Calc_Role AS calc_role,
    o.step_no,
    o.step_uuid,
    o.step_uuid AS marks,
    substr(regexp_replace(o.Formula_Text, '\s+', ' ', 'g'), 1, 120) AS formula_excerpt,
    CASE o.cause
      WHEN 'dynamic-name' THEN 'Plug-in call with a dynamic function name (MBS($name; …)) — the target cannot be resolved, the call is missing from the object graph'
      ELSE 'Plug-in call in the formula text but no reference in the catalog although DDR info exists — converter blind spot, please report the formula'
    END || CASE WHEN o.step_no IS NOT NULL THEN ' (' || o.Calc_Role || ', step ' || o.step_no || ')' ELSE ' (' || o.Calc_Role || ')' END AS message,
    row_number() OVER (ORDER BY o.cause DESC, o.File_Name, o.nav_name, o.step_no, o.Calc_Role) AS row_key
FROM owner o
WHERE (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR o.nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY o.cause DESC, o.File_Name, o.nav_name, o.step_no, o.Calc_Role
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
