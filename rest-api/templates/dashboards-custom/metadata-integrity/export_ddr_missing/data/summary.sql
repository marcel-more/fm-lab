-- Hand-maintained COUNT wrapper embedding the findings core of rule
-- (export_ddr_missing). Keep filters (file filter + scope block) in sync with
-- data/findings.sql. SUM() yields HUGEINT — cast to BIGINT for the JSON layer.
WITH prefixes AS (
    SELECT 'MBS' AS p
    UNION
    SELECT DISTINCT split_part(Plugin_Function_Name, ':', 1)
    FROM PluginFunctionUsages
    WHERE Plugin_Function_Name IS NOT NULL AND Plugin_Function_Name <> ''
),
impact AS (
    SELECT c.File_Name,
           COUNT(*) AS formulas_total,
           -- comments stripped (/* … */ and // …) — same vocabulary and same
           -- exclusion as plugin_call_without_reference / plugin_reference_census
           COUNT(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM prefixes p
               WHERE regexp_matches(
                   regexp_replace(regexp_replace(c.Formula_Text, '(?s)/\*.*?\*/', '', 'g'), '//[^\n]*', '', 'g'),
                   '\b' || p.p || '\s*\('))) AS plugin_text_formulas
    FROM CalculationsCatalog c
    GROUP BY c.File_Name
)
SELECT
    COUNT(*) AS finding_count,
    'warning' AS severity,
    CAST(COALESCE(SUM(i.formulas_total), 0) AS BIGINT) AS affected_formulas,
    CAST(COALESCE(SUM(i.plugin_text_formulas), 0) AS BIGINT) AS affected_plugin_formulas,
    (SELECT COUNT(*) FROM FilesCatalog) AS files_total
FROM FilesCatalog f
LEFT JOIN ObjectCatalog o ON o.Object_Type = 'File' AND o.File_Name = f.File_Name
LEFT JOIN impact i ON i.File_Name = f.File_Name
WHERE NOT COALESCE(f.Has_DDR_INFO, FALSE)
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR o.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
