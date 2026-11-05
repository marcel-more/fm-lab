-- @template_type: content
-- @description: Detailed view of a FileMaker Custom Menu - properties, install/title calculations, menu items, references
-- @params: uuid (required)
-- @output_format: content
-- @author: Marcel
-- @version: 1.1
-- @tags: custommenu, details, calculations, menuitems
-- @note: Shows CustomMenu properties, attached calculations (Install/Title via v_calc_anchors),
--        the list of menu items, and derived references (AP-3)

WITH menu_match AS (
  SELECT m.Menu_ID, m.Menu_Name, m.Menu_UUID, m.File_Name
  FROM CustomMenuCatalog m
  WHERE m.Menu_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR m.File_Name = getvariable('file'))
  LIMIT 1
),
calc_anchors AS (
  SELECT va.Kind_Label, va.Calc_Kind, va.Is_Static, va.Display_Text,
    ROW_NUMBER() OVER (ORDER BY va.Is_Static, va.Calc_Kind) AS ord
  FROM v_calc_anchors va
  WHERE va.Owner_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR va.Owner_File = getvariable('file'))
    AND va.Owner_Type = 'CustomMenu'
),
calc_lines AS (
  SELECT ord, Kind_Label, Is_Static,
    string_split(replace(COALESCE(Display_Text, ''), chr(13), chr(10)), chr(10)) AS arr
  FROM calc_anchors
),
items AS (
  SELECT i.Item_Index, i.Command_Name, i.Command_ID, i.Is_SubMenuItem, i.Is_SeparatorItem, i.Item_UUID,
    -- Berechneter/überschriebener Anzeigename (Calculated-Name-Anker), umschließende " entfernt.
    (SELECT trim(BOTH '"' FROM va.Display_Text) FROM v_calc_anchors va
       WHERE va.Owner_UUID = i.Item_UUID AND va.Owner_Type = 'CustomMenuItem'
         AND va.Kind_Label = 'Calculated Name' LIMIT 1) AS Calc_Name,
    -- Nicht-triviale Install-Bedingung (alles außer statisch "1"/leer = bedingte Sichtbarkeit),
    -- einzeilig gemacht und auf 80 Zeichen gekürzt.
    (SELECT LEFT(regexp_replace(replace(replace(va.Display_Text, chr(13), ' '), chr(10), ' '), '\s+', ' ', 'g'), 80)
       FROM v_calc_anchors va
       WHERE va.Owner_UUID = i.Item_UUID AND va.Owner_Type = 'CustomMenuItem'
         AND va.Kind_Label = 'Install Condition'
         AND NOT (va.Is_Static AND trim(COALESCE(va.Display_Text, '')) IN ('1', '')) LIMIT 1) AS Install_Cond,
    -- Submenu-Ziel (CustomMenuReference/@name) aus dem Item-Roh-XML.
    NULLIF(regexp_extract(i.Item_XML, 'CustomMenuReference[^>]*name="([^"]+)"', 1), '') AS Submenu_Name
  FROM CustomMenuItemCatalog i
  WHERE i.Menu_UUID = (SELECT Menu_UUID FROM menu_match)
    AND i.File_Name = (SELECT File_Name FROM menu_match)
  ORDER BY i.Item_Index
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
  SELECT 1 as sort_key, 0 as sub_key, '=== CustomMenu Details ===' as content FROM menu_match
  UNION ALL
  SELECT 2, 0, '' FROM menu_match
  UNION ALL
  SELECT 3, 1, 'Menu:         ' || mm.Menu_Name FROM menu_match mm
  UNION ALL
  SELECT 3, 2, 'File:         ' || mm.File_Name FROM menu_match mm
  UNION ALL
  SELECT 3, 3, 'Items:        ' || CAST((SELECT COUNT(*) FROM items) AS VARCHAR) FROM menu_match mm
  UNION ALL
  SELECT 3, 4, 'UUID:         ' || mm.Menu_UUID FROM menu_match mm

  UNION ALL

  -- Calculations block (generic, Install/Title)
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

  -- Menu items list (angereichert: berechneter Name, Install-Bedingung, Submenu-Ziel)
  SELECT 7, 0, '' WHERE (SELECT COUNT(*) FROM items) > 0
  UNION ALL
  SELECT 7, 1, '--- Menu Items (' || CAST((SELECT COUNT(*) FROM items) AS VARCHAR)
    || CASE WHEN (SELECT COUNT(*) FROM items WHERE Install_Cond IS NOT NULL) > 0
         THEN ' · ' || CAST((SELECT COUNT(*) FROM items WHERE Install_Cond IS NOT NULL) AS VARCHAR) || ' bedingt' ELSE '' END
    || CASE WHEN (SELECT COUNT(*) FROM items WHERE Calc_Name IS NOT NULL) > 0
         THEN ' · ' || CAST((SELECT COUNT(*) FROM items WHERE Calc_Name IS NOT NULL) AS VARCHAR) || ' umbenannt' ELSE '' END
    || CASE WHEN (SELECT COUNT(*) FROM items WHERE Submenu_Name IS NOT NULL) > 0
         THEN ' · ' || CAST((SELECT COUNT(*) FROM items WHERE Submenu_Name IS NOT NULL) AS VARCHAR) || ' Submenu' ELSE '' END
    || ') ---'
  WHERE (SELECT COUNT(*) FROM items) > 0
  UNION ALL
  SELECT 7, CAST(2 + ROW_NUMBER() OVER (ORDER BY Item_Index) AS INTEGER),
    '  [' || LPAD(CAST(Item_Index AS VARCHAR), 3, ' ') || '] '
    || CASE
         WHEN Is_SeparatorItem THEN '——— (Separator)'
         WHEN Submenu_Name IS NOT NULL THEN '▸ Submenu: ' || Submenu_Name
         -- Reines Custom-Item (kein Basisbefehl) → nur der berechnete Name.
         WHEN Calc_Name IS NOT NULL AND (Command_Name IS NULL OR Command_Name = '')
              AND (Command_ID IS NULL OR Command_ID = 0)
           THEN '"' || Calc_Name || '"'
         -- Echter Basisbefehl mit abweichendem berechnetem Anzeigenamen.
         WHEN Calc_Name IS NOT NULL
           THEN COALESCE(NULLIF(Command_Name, ''), '(FM-Befehl ' || CAST(Command_ID AS VARCHAR) || ')') || ' → "' || Calc_Name || '"'
         WHEN Command_Name IS NULL OR Command_Name = ''
           THEN COALESCE('(FM-Befehl ' || CAST(Command_ID AS VARCHAR) || ')', '(berechnet)')
         ELSE Command_Name END
    || CASE WHEN Install_Cond IS NOT NULL THEN '   ⚙ nur wenn: ' || Install_Cond ELSE '' END
  FROM items

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
