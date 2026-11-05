-- @template_type: content
-- @description: Detailansicht eines Folders (Script-/Layout-/CustomFunction-Folder) mit Children und Parent
-- @params: uuid (required)
-- @output_format: content
-- @author: Marcel
-- @version: 1.0
-- @tags: folder, hierarchy, scripts, layouts
-- @note: Der Subtyp wird über Source_Table unterschieden (ScriptCatalog, Layouts, CustomFunctionsCatalog).

WITH folder_match AS (
  SELECT
    fh.Source_UUID,
    fh.Item_Name,
    fh.File_Name,
    fh.Source_Table,
    fh.nesting_level,
    fh.Parent_Folder_UUID
  FROM FolderHierarchy fh
  WHERE fh.subtype = 'Folder'
    AND fh.Source_UUID = getvariable('uuid')
    -- Clone-Scoping: Identität ist (Source_UUID, File_Name); auf die kanonisch aufgelöste Datei einschränken
    AND (getvariable('file') IS NULL OR fh.File_Name = getvariable('file'))
  LIMIT 1
),
subtype_label AS (
  SELECT
    CASE Source_Table
      WHEN 'ScriptCatalog'          THEN 'Script Folder'
      WHEN 'Layouts'                THEN 'Layout Folder'
      WHEN 'CustomFunctionsCatalog' THEN 'CustomFunction Folder'
      ELSE                               Source_Table
    END AS label,
    Source_UUID, Item_Name, File_Name, Source_Table, nesting_level, Parent_Folder_UUID
  FROM folder_match
),
parent_info AS (
  SELECT
    fh.Item_Name AS parent_name,
    fh.Source_UUID AS parent_uuid
  FROM FolderHierarchy fh
  -- Clone-Scoping: Parent-Folder-UUIDs sind nur dateiweit eindeutig → gleiche Datei erzwingen
  JOIN folder_match fm ON fh.Source_UUID = fm.Parent_Folder_UUID AND fh.File_Name = fm.File_Name
  WHERE fh.subtype = 'Folder'
  LIMIT 1
),
-- Direkte Children: Items + Sub-Folder mit Parent_Folder_UUID = aktuellem Folder
children AS (
  SELECT
    fh.Source_UUID  AS child_uuid,
    fh.Item_Name    AS child_name,
    fh.subtype      AS child_subtype,
    fh.Source_Table AS child_source_table,
    fh.seq          AS child_seq
  FROM FolderHierarchy fh
  -- Clone-Scoping: Parent/Child-Folder-IDs sind nur dateiweit eindeutig → Children derselben Datei
  JOIN folder_match fm ON fh.Parent_Folder_UUID = fm.Source_UUID AND fh.File_Name = fm.File_Name
  WHERE fh.subtype IN ('Folder', 'Item')
),
child_stats AS (
  SELECT
    COUNT(*) FILTER (WHERE child_subtype = 'Folder') AS sub_folders,
    COUNT(*) FILTER (WHERE child_subtype = 'Item')   AS items,
    COUNT(*)                                          AS total
  FROM children
)

SELECT content FROM (
  -- Header
  SELECT 1 AS sort_key, 0 AS sub_key,
    '=== Folder Details ===' AS content
  FROM folder_match

  UNION ALL
  SELECT 2, 0, '' FROM folder_match

  UNION ALL

  -- Folder Properties
  SELECT 3, 1, 'Name:          ' || sl.Item_Name FROM subtype_label sl
  UNION ALL
  SELECT 3, 2, 'Type:          ' || sl.label    FROM subtype_label sl
  UNION ALL
  SELECT 3, 3, 'File:          ' || sl.File_Name FROM subtype_label sl
  UNION ALL
  SELECT 3, 4, 'UUID:          ' || sl.Source_UUID FROM subtype_label sl
  UNION ALL
  SELECT 3, 5, 'Nesting Level: ' || CAST(sl.nesting_level AS VARCHAR) FROM subtype_label sl

  UNION ALL

  -- Parent
  SELECT 4, 0, '' FROM folder_match
  UNION ALL
  SELECT 4, 1,
    'Parent Folder: ' || COALESCE(pi.parent_name, '(root)')
  FROM folder_match fm
  LEFT JOIN parent_info pi ON TRUE

  UNION ALL

  -- Children-Statistik
  SELECT 5, 0, '' FROM child_stats
  UNION ALL
  SELECT 5, 1,
    '--- Children --- (' || CAST(cs.total AS VARCHAR) || ' total: '
    || CAST(cs.sub_folders AS VARCHAR) || ' sub-folders, '
    || CAST(cs.items AS VARCHAR) || ' items)'
  FROM child_stats cs

  UNION ALL

  -- Children-Liste in XML-Reihenfolge
  SELECT 6, CAST(c.child_seq AS INTEGER),
    CASE c.child_subtype
      WHEN 'Folder' THEN '  [FOLDER] ' || c.child_name
      ELSE              '            ' || c.child_name
    END
  FROM children c
) details
ORDER BY sort_key, sub_key;
