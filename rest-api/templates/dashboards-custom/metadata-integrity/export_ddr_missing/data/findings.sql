-- Files exported without DDR info — "Include details for analysis tools" was
-- off when the XML was saved (root attribute Has_DDR_INFO="False", stored as
-- FilesCatalog.Has_DDR_INFO by P1). Such a file imports without error and looks
-- complete: scripts, fields, layouts and even every formula TEXT are there. But
-- the DDR chunk stream is the ONLY source of formula references — no field
-- reads/writes from calculations, no calls_function, no calls_customfunction,
-- no calls_pluginfunction for anything defined in that file. Where-used, the
-- plug-in inventory and the object graph are silently blind for it.
--
-- One finding per file. nav_uuid = the catalog's File object (same UUID as
-- FilesCatalog.File_UUID) — opens the file detail. Impact columns count the
-- formulas whose references are lost; plugin_text_formulas uses the same text
-- vocabulary as plugin_call_without_reference (the MBS literal plus every
-- plug-in prefix the catalog itself knows) — a lower bound, not a census of
-- every plug-in on the market.
--
-- No fix inside fm-lab: the information is absent from the export. Re-export
-- with the option and import again.
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
    'export-ddr-missing' AS rule_id,
    'warning' AS severity,
    o.Object_UUID AS nav_uuid,
    'File' AS type,
    f.File_Name AS name,
    f.File_Name AS file,
    f.FileMaker_Version AS filemaker_version,
    f.SaXML_Profile AS saxml_profile,
    COALESCE(i.formulas_total, 0) AS formulas_total,
    COALESCE(i.plugin_text_formulas, 0) AS plugin_text_formulas,
    'File exported without DDR info — the references of its ' || COALESCE(i.formulas_total, 0)
      || ' formulas (' || COALESCE(i.plugin_text_formulas, 0)
      || ' with plug-in calls) are invisible; re-export with "Include details for analysis tools"' AS message,
    row_number() OVER (ORDER BY f.File_Name) AS row_key
FROM FilesCatalog f
LEFT JOIN ObjectCatalog o ON o.Object_Type = 'File' AND o.File_Name = f.File_Name
LEFT JOIN impact i ON i.File_Name = f.File_Name
WHERE NOT COALESCE(f.Has_DDR_INFO, FALSE)
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR o.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY f.File_Name
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
