-- @template_type: report
-- @description: Meistgenutzte Plugin-Funktionen — Call-Sites und betroffene Dateien je Funktion, optional auf eine Komponente gefiltert. Klick auf eine Zeile öffnet die Plugin-Funktion (Where-used).
-- @params: file (optional), component (optional), limit (optional, default 60)

WITH calls AS (
    SELECT
        src.File_Name                                             AS file,
        tc.Object_Name                                            AS fn,
        tc.Object_UUID                                            AS fn_uuid,
        CASE WHEN tc.Object_Name LIKE 'MBS:%'
             THEN regexp_extract(tc.Object_Name, '(?i)MBS:([A-Za-z]+)\.', 1)
             ELSE 'Other' END                                     AS component
    FROM ObjectLinks ol
    JOIN ObjectCatalog tc ON ol.Target_UUID = tc.Object_UUID AND tc.File_Name IS NOT DISTINCT FROM ol.Target_File
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID AND src.File_Name = ol.Source_File
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND (getvariable('file') IS NULL OR src.File_Name = getvariable('file'))
)
SELECT
    fn                                AS function_name,
    MAX(component)                    AS component,
    COUNT(*)                          AS callsites,
    COUNT(DISTINCT file)             AS files,
    arg_max(fn_uuid, fn)             AS nav_uuid
FROM calls
WHERE (getvariable('component') IS NULL OR getvariable('component') IN ('', 'All', 'Alle')
       OR component = getvariable('component'))
GROUP BY fn
ORDER BY callsites DESC, function_name
LIMIT CAST(COALESCE(getvariable('limit'), '60') AS INTEGER);
