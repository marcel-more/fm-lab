-- @template_type: report
-- @description: KPI-Übersicht der Plugin-Abhängigkeit — Plugin-Call-Sites gesamt, verschiedene Komponenten und Funktionen, betroffene Dateien, Install-Plug-In-File-Steps.
-- @params: file (optional)

WITH calls AS (
    SELECT
        src.File_Name AS file,
        tc.Object_Name AS fn,
        CASE WHEN tc.Object_Name LIKE 'MBS:%'
             THEN regexp_extract(tc.Object_Name, '(?i)MBS:([A-Za-z]+)\.', 1)
             ELSE 'Other' END AS component
    FROM ObjectLinks ol
    JOIN ObjectCatalog tc ON ol.Target_UUID = tc.Object_UUID AND tc.File_Name IS NOT DISTINCT FROM ol.Target_File
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID AND src.File_Name = ol.Source_File
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND (getvariable('file') IS NULL OR src.File_Name = getvariable('file'))
)
SELECT
    (SELECT COUNT(*) FROM calls)                     AS callsites,
    (SELECT COUNT(DISTINCT component) FROM calls)    AS components,
    (SELECT COUNT(DISTINCT fn) FROM calls)           AS functions,
    (SELECT COUNT(DISTINCT file) FROM calls)         AS files_affected,
    (SELECT COUNT(*) FROM StepsForScripts s WHERE s.Step_ID = 157
       AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))) AS install_plugin_steps;
