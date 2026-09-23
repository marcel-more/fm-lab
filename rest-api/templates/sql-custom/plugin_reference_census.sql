-- @template_type: report
-- @title: Plug-in reference census
-- @description: One row per file — the plug-in evidence of the catalog side by side: formulas whose TEXT calls a plug-in, formulas with the export placeholder <Function Missing>, PluginFunctionRef chunks in the DDR, resolved usages (and how many of them carry a dynamic function name), calls_pluginfunction edges and the distinct plug-in objects they reach — plus a verdict per file: ok · no-ddr-info · function-missing · dynamic-only · mismatch. The one-glance answer to "why does this solution show no plug-in references?" — text > 0 with chunks = 0 is an export without DDR info, placeholders > 0 an export with the plug-in not loaded, usages > 0 with edges = 0 a dynamic-only file, text > 0 with DDR info but edges = 0 a converter blind spot. Inventory, not a defect count; the three companion rules in the Plug-in Reference Integrity test turn the verdicts into findings.
-- @icon: plug
-- @category: Metadata Integrity
-- @display: table
-- @params: file (optional), limit (optional, default 500)
-- @click_action: openObject
-- @click_args: uuid={{_nav_uuid}}&type=File&file={{file}}
-- @output_format: file, has_ddr_info, saxml_profile, plugin_text_formulas, function_missing_formulas, plugin_ref_chunks, plugin_usages, dynamic_usages, plugin_edges, plugin_objects, verdict, _message, _nav_uuid
-- @object_types:
-- @output_types: count, inventory-table
-- @scope: solution, file
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "files", "meaning": "Files in scope with their plug-in reference census (inventory — the verdict column classifies each file, it is not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: plugins, mbs, ddr, export, inventory, import-census
--
-- Text vocabulary: the MBS literal plus every plug-in prefix the catalog itself
-- knows (PluginFunctionUsages) — deliberately without plugin_spec, so the
-- census never depends on a reference DB. Calls inside /* … */ or // comments
-- are not counted as plug-in text (measured false-positive class).
--
-- Verdict order: no-ddr-info beats function-missing beats dynamic-only beats
-- mismatch — the first applicable cause explains the file. A file with DDR
-- info, plug-in text and edges is `ok` even when single formulas are dynamic;
-- that granularity is the rule plugin_call_without_reference.
WITH prefixes AS (
    SELECT 'MBS' AS p
    UNION
    SELECT DISTINCT split_part(Plugin_Function_Name, ':', 1)
    FROM PluginFunctionUsages
    WHERE Plugin_Function_Name IS NOT NULL AND Plugin_Function_Name <> ''
),
txt AS (
    SELECT c.File_Name,
           COUNT(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM prefixes p
               WHERE regexp_matches(
                   regexp_replace(regexp_replace(c.Formula_Text, '(?s)/\*.*?\*/', '', 'g'), '//[^\n]*', '', 'g'),
                   '\b' || p.p || '\s*\('))) AS plugin_text_formulas,
           COUNT(*) FILTER (WHERE c.Formula_Text LIKE '%<Function Missing>%') AS function_missing_formulas
    FROM CalculationsCatalog c
    GROUP BY c.File_Name
),
chunks AS (
    SELECT File_Name, COUNT(*) AS plugin_ref_chunks
    FROM DDR_Calculations
    WHERE Chunk_Type = 'PluginFunctionRef'
    GROUP BY File_Name
),
usages AS (
    SELECT u.File_Name,
           COUNT(*) AS plugin_usages,
           COUNT(*) FILTER (WHERE u.Plugin_Function_Name = 'MBS' AND m.SubName IS NULL) AS dynamic_usages
    FROM PluginFunctionUsages u
    LEFT JOIN MBS_SubnameMap m
           ON m.Calc_UUID = u.Calc_UUID AND m.File_Name = u.File_Name
          AND m.Plugin_Chunk_Index = u.Plugin_Chunk_Index
    GROUP BY u.File_Name
),
edges AS (
    SELECT Source_File AS File_Name,
           COUNT(*) AS plugin_edges,
           COUNT(DISTINCT Target_UUID) AS plugin_objects
    FROM ObjectLinks
    WHERE Link_Role = 'calls_pluginfunction'
    GROUP BY Source_File
),
census AS (
    SELECT f.File_Name AS file,
           COALESCE(f.Has_DDR_INFO, FALSE) AS has_ddr_info,
           f.SaXML_Profile AS saxml_profile,
           COALESCE(t.plugin_text_formulas, 0)     AS plugin_text_formulas,
           COALESCE(t.function_missing_formulas, 0) AS function_missing_formulas,
           COALESCE(k.plugin_ref_chunks, 0)        AS plugin_ref_chunks,
           COALESCE(u.plugin_usages, 0)            AS plugin_usages,
           COALESCE(u.dynamic_usages, 0)           AS dynamic_usages,
           COALESCE(e.plugin_edges, 0)             AS plugin_edges,
           COALESCE(e.plugin_objects, 0)           AS plugin_objects,
           o.Object_UUID                           AS _nav_uuid
    FROM FilesCatalog f
    LEFT JOIN txt t    ON t.File_Name = f.File_Name
    LEFT JOIN chunks k ON k.File_Name = f.File_Name
    LEFT JOIN usages u ON u.File_Name = f.File_Name
    LEFT JOIN edges e  ON e.File_Name = f.File_Name
    LEFT JOIN ObjectCatalog o ON o.Object_Type = 'File' AND o.File_Name = f.File_Name
    WHERE (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
),
judged AS (
    SELECT c.*,
           CASE WHEN NOT c.has_ddr_info                                   THEN 'no-ddr-info'
                WHEN c.function_missing_formulas > 0                      THEN 'function-missing'
                WHEN c.plugin_text_formulas > 0 AND c.plugin_edges = 0
                     AND c.dynamic_usages > 0                             THEN 'dynamic-only'
                WHEN c.plugin_text_formulas > 0 AND c.plugin_edges = 0    THEN 'mismatch'
                ELSE 'ok' END AS verdict
    FROM census c
)
SELECT j.file, j.has_ddr_info, j.saxml_profile,
       j.plugin_text_formulas, j.function_missing_formulas, j.plugin_ref_chunks,
       j.plugin_usages, j.dynamic_usages, j.plugin_edges, j.plugin_objects,
       j.verdict,
       CASE j.verdict
         WHEN 'no-ddr-info'      THEN 'Exported without DDR info — ' || j.plugin_text_formulas || ' plug-in formula(s) without any reference; re-export with "Include details for analysis tools"'
         WHEN 'function-missing' THEN j.function_missing_formulas || ' formula(s) with <Function Missing> — a plug-in was not loaded on the exporting client'
         WHEN 'dynamic-only'     THEN 'Plug-in calls resolved only with dynamic function names — no plug-in object or edge'
         WHEN 'mismatch'         THEN j.plugin_text_formulas || ' plug-in formula(s) in the text but no edge although DDR info exists — converter blind spot'
         ELSE 'Plug-in evidence consistent: ' || j.plugin_edges || ' edge(s) to ' || j.plugin_objects || ' plug-in object(s)'
       END AS _message,
       j._nav_uuid
FROM judged j
ORDER BY (j.verdict <> 'ok') DESC, j.verdict, j.file
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
