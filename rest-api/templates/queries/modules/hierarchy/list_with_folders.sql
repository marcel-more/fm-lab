-- @template_type: object
-- @description: Flat, hierarchically sorted list of all items + folders + separators of a subtype for the tree view
-- @params: subtype (required, 'ScriptCatalog' | 'Layouts' | 'CustomFunctionsCatalog'), file (optional)
-- @output_format: uuid, name, type, subtype, nesting_level, file, sequence
-- @author: Marcel
-- @version: 1.0
-- @tags: folder, hierarchy, tree, scripts, layouts
-- @note: Frontend baut den Baum per JS-Stack-Algorithmus aus nesting_level + Reihenfolge.

SELECT
    fh.Source_UUID  AS uuid,
    fh.Item_Name    AS name,
    -- Frontend-freundlicher Type: leitet sich aus subtype + Source_Table ab
    CASE
        WHEN fh.subtype = 'Folder'    THEN 'Folder'
        WHEN fh.subtype = 'Separator' THEN 'Separator'
        WHEN fh.Source_Table = 'ScriptCatalog'          THEN 'Script'
        WHEN fh.Source_Table = 'Layouts'                THEN 'Layout'
        WHEN fh.Source_Table = 'CustomFunctionsCatalog' THEN 'CustomFunction'
        ELSE                                                 'Item'
    END             AS type,
    fh.subtype                       AS subtype,
    CAST(fh.nesting_level AS INTEGER) AS nesting_level,
    fh.File_Name                     AS file,
    CAST(fh.seq AS INTEGER)          AS sequence
FROM FolderHierarchy fh
WHERE fh.Source_Table = getvariable('subtype')
  AND fh.subtype != 'FolderEnd'  -- Marker dienen nur intern der Stack-Berechnung
  AND (getvariable('file') IS NULL OR fh.File_Name = getvariable('file'))
ORDER BY fh.File_Name, fh.seq;
