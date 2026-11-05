-- Hand-maintained COUNT wrapper embedding the findings core of rule
-- (plugin_call_without_reference). Keep filters (file filter + scope block)
-- in sync with data/findings.sql. finding_count = every listed row (dynamic
-- names are info, unresolved pairings warning — the per-row severity decides
-- the member state); comment_only = formulas whose plug-in call sits in a
-- comment (never a finding); no_ddr_files = files excluded here because they
-- were exported without DDR info (their finding is export_ddr_missing).
-- Params are normalised ONCE (each getvariable appears exactly once so the
-- M5a copy-sync check stays green; '' and NULL both mean "no filter").
WITH params AS (
    SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '') AS file_filter,
           NULLIF(CAST(getvariable('scope_uuids') AS VARCHAR), '') AS scope_csv
),
prefixes AS (
    SELECT 'MBS' AS p
    UNION
    SELECT DISTINCT split_part(Plugin_Function_Name, ':', 1)
    FROM PluginFunctionUsages
    WHERE Plugin_Function_Name IS NOT NULL AND Plugin_Function_Name <> ''
),
calc AS (
    SELECT c.Calculation_UUID, c.Owner_UUID, c.File_Name, c.DDR_Calc_UUID,
           regexp_replace(regexp_replace(c.Formula_Text, '(?s)/\*.*?\*/', '', 'g'),
                          '//[^\n]*', '', 'g') AS code_text
    FROM CalculationsCatalog c
    JOIN FilesCatalog f USING (File_Name)
    WHERE COALESCE(f.Has_DDR_INFO, FALSE)
      AND c.Formula_Text NOT LIKE '%<Function Missing>%'
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
    SELECT k.*, COALESCE(s.Script_UUID, k.Owner_UUID) AS nav_uuid
    FROM classified k
    LEFT JOIN StepsForScripts s ON s.Step_UUID = k.Owner_UUID AND s.File_Name = k.File_Name
    CROSS JOIN params p
    WHERE (p.file_filter IS NULL OR k.File_Name = p.file_filter)
      AND (p.scope_csv IS NULL
           OR COALESCE(s.Script_UUID, k.Owner_UUID) IN (SELECT unnest(string_split(p.scope_csv, ','))))
)
SELECT
    COUNT(*) FILTER (WHERE in_code AND (NOT has_link OR has_dynamic)) AS finding_count,
    'warning' AS severity,
    COUNT(*) FILTER (WHERE in_code AND has_dynamic) AS dynamic_count,
    COUNT(*) FILTER (WHERE in_code AND NOT has_link AND NOT has_dynamic) AS unresolved_count,
    COUNT(*) FILTER (WHERE NOT in_code) AS comment_only,
    (SELECT COUNT(*) FROM FilesCatalog f CROSS JOIN params p
      WHERE NOT COALESCE(f.Has_DDR_INFO, FALSE)
        AND (p.file_filter IS NULL OR f.File_Name = p.file_filter)) AS no_ddr_files,
    COUNT(DISTINCT File_Name) FILTER (WHERE in_code AND (NOT has_link OR has_dynamic)) AS affected_files
FROM owner;
