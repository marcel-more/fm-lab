-- @template_type: content
-- @description: Detailed view of a FileMaker Custom Menu Item - command, install/name calculations, parent menu, references
-- @params: uuid (required)
-- @output_format: content
-- @author: Marcel
-- @version: 1.0
-- @tags: custommenuitem, details, calculations
-- @note: Shows CustomMenuItem properties, attached calculations (Install/Name via v_calc_anchors),
--        parent menu, and derived references (AP-3/D-2)

WITH item_match AS (
  SELECT i.Item_UUID, i.Item_Index, i.Command_Name, i.Command_ID,
    i.Is_SubMenuItem, i.Is_SeparatorItem, i.Menu_UUID, i.Menu_Name, i.File_Name
  FROM CustomMenuItemCatalog i
  WHERE i.Item_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR i.File_Name = getvariable('file'))
  LIMIT 1
),
calc_anchors AS (
  SELECT va.Kind_Label, va.Calc_Kind, va.Is_Static, va.Display_Text,
    ROW_NUMBER() OVER (ORDER BY va.Is_Static, va.Calc_Kind) AS ord
  FROM v_calc_anchors va
  WHERE va.Owner_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR va.Owner_File = getvariable('file'))
    AND va.Owner_Type = 'CustomMenuItem'
),
calc_lines AS (
  SELECT ord, Kind_Label, Is_Static,
    string_split(replace(COALESCE(Display_Text, ''), chr(13), chr(10)), chr(10)) AS arr
  FROM calc_anchors
),
child_refs AS (
  SELECT oc.Object_Type as Target_Type, oc.Object_Name as Target_Name,
    oc.File_Name as Target_File, ol.Link_Role, ol.Link_Subrole, ol.Is_Cross_File
  FROM ObjectLinks ol
  JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID AND oc.File_Name = ol.Target_File
  WHERE ol.Source_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR ol.Source_File = getvariable('file'))
    AND ol.Link_Type = 'operational'
  ORDER BY oc.Object_Type, oc.Object_Name
)

SELECT content FROM (
  SELECT 1 as sort_key, 0 as sub_key, '=== CustomMenuItem Details ===' as content FROM item_match
  UNION ALL
  SELECT 2, 0, '' FROM item_match
  UNION ALL
  SELECT 3, 1, 'Command:      ' || CASE WHEN im.Is_SeparatorItem THEN '(Separator)'
      WHEN im.Command_Name IS NULL OR im.Command_Name = '' THEN '(calculated / submenu)'
      ELSE im.Command_Name END
  FROM item_match im
  UNION ALL
  SELECT 3, 2, 'Parent Menu:  ' || im.Menu_Name FROM item_match im
  UNION ALL
  SELECT 3, 3, 'Index:        ' || CAST(im.Item_Index AS VARCHAR) FROM item_match im
  UNION ALL
  SELECT 3, 4, 'Kind:         '
    || CASE WHEN im.Is_SeparatorItem THEN 'Separator '
            WHEN im.Is_SubMenuItem THEN 'Submenu item ' ELSE 'Command item ' END
    || COALESCE('(FM command id ' || im.Command_ID || ')', '')
  FROM item_match im
  UNION ALL
  SELECT 3, 5, 'File:         ' || im.File_Name FROM item_match im
  UNION ALL
  SELECT 3, 6, 'UUID:         ' || im.Item_UUID FROM item_match im

  UNION ALL

  -- Calculations block (generic, Install/Name)
  SELECT 5, 0, '' WHERE (SELECT COUNT(*) FROM calc_anchors) > 0
  UNION ALL
  SELECT 5, 1, '--- Calculations (' || CAST((SELECT COUNT(*) FROM calc_anchors) AS VARCHAR) || ') ---'
  WHERE (SELECT COUNT(*) FROM calc_anchors) > 0
  UNION ALL
  SELECT 5, CAST(ca.ord * 1000 AS INTEGER),
    '  ' || ca.Kind_Label || CASE WHEN ca.Is_Static THEN '  [static]:' ELSE '  [formula]:' END
  FROM calc_anchors ca
  UNION ALL
  SELECT 5, CAST(cl.ord * 1000 + line_no AS INTEGER), '      ' || line
  FROM (
    SELECT ord, unnest(arr) AS line, unnest(range(1, length(arr) + 1)) AS line_no FROM calc_lines
  ) cl

  UNION ALL

  -- References
  SELECT 10, 0, '' WHERE (SELECT COUNT(*) FROM child_refs) > 0
  UNION ALL
  SELECT 10, 1, '--- References (' || CAST((SELECT COUNT(*) FROM child_refs) AS VARCHAR) || ') ---'
  WHERE (SELECT COUNT(*) FROM child_refs) > 0
  UNION ALL
  SELECT 11, CAST(ROW_NUMBER() OVER (ORDER BY Target_Type, Target_Name) AS INTEGER),
    '  -> ' || Target_Type || ': ' || Target_Name
    || CASE WHEN Is_Cross_File THEN ' [' || Target_File || ']' ELSE '' END
    || ' (' || Link_Role || COALESCE(' · ' || Link_Subrole, '') || ')'
  FROM child_refs
) details
ORDER BY sort_key, sub_key;
