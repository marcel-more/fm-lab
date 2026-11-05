-- @template_type: report
-- @title: Top custom functions
-- @description: Custom functions with the most operational references (via ObjectLinks).
-- @icon: function
-- @display: table
-- @params: limit (optional, default 100), file (optional)
-- @click_action: openObject
-- @click_args: uuid={{uuid}}&type=CustomFunction
-- @output_format: uuid, name, file, reference_count
-- @object_types: CustomFunction
-- @author: fm-lab core
-- @version: 1.1
-- @tags: custom-functions, top, ranking

SELECT
    cf.CF_UUID                AS uuid,
    cf.CF_Name                AS name,
    cf.File_Name              AS file,
    COUNT(ol.Source_UUID)     AS reference_count
FROM CustomFunctionsCatalog cf
LEFT JOIN ObjectLinks ol
       ON ol.Target_UUID = cf.CF_UUID
      AND ol.Link_Type   = 'operational'
WHERE (getvariable('file') IS NULL OR cf.File_Name = getvariable('file'))
  -- Ordner und Trenner des "Manage Custom Functions"-Dialogs stehen als
  -- CustomFunction-Records im Katalog; ohne diesen Filter erschienen sie hier
  -- als Funktionen mit 0 Referenzen (Schema 1.15.0).
  AND (cf.Folder_Type IS NULL OR cf.Folder_Type = 'False')
  AND NOT COALESCE(cf.Is_Separator, FALSE)
GROUP BY ALL
ORDER BY reference_count DESC, name, file, uuid   -- tie-breakers: stable rows at the LIMIT
LIMIT CAST(COALESCE(getvariable('limit'), '100') AS INTEGER);
