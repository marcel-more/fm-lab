-- @template_type: report
-- @description: Custom Menu calculations (menu-level + per-item) as tokenized DDR chunks
-- @params: uuid (required)
-- @output_format: tokens
-- @author: Marcel
-- @version: 1.0
-- @tags: custommenu, ddr, tokens, calculations
-- @note: Liefert die Calc-Tokens aller Berechnungen eines Custom Menus — die Menü-eigenen
--        (Install/Title) UND die pro-Item-Berechnungen (Install-Bedingung, berechneter Name).
--        Ein Block pro Anker (block_id). Triviale statische Item-Bedingungen ("1"/leer)
--        werden ausgelassen, damit nur aussagekräftige Formeln/Texte erscheinen.
--        Chunk-Auflösung analog object_details_field_tokens.sql (FieldRef-UUID im Chunk,
--        CustomFunctionRef file-lokal via ObjectHomes).

WITH menu_match AS (
  SELECT m.Menu_UUID, m.Menu_Name, m.File_Name
  FROM CustomMenuCatalog m
  WHERE m.Menu_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR m.File_Name = getvariable('file'))
  LIMIT 1
),
item_meta AS (
  SELECT Item_UUID, Item_Index, Command_Name, Command_ID
  FROM CustomMenuItemCatalog
  WHERE Menu_UUID = (SELECT Menu_UUID FROM menu_match)
    AND File_Name = (SELECT File_Name FROM menu_match)
),
anchors AS (
  -- Menü-eigene Berechnungen (Install/Title …)
  SELECT va.Calc_UUID, va.Kind_Label, va.Is_Static, va.Display_Text,
         0 AS scope_order, CAST(NULL AS BIGINT) AS item_index,
         'Menü' AS block_prefix
  FROM v_calc_anchors va, menu_match mm
  WHERE va.Owner_Type = 'CustomMenu'
    AND va.Owner_UUID = mm.Menu_UUID AND va.Owner_File = mm.File_Name
  UNION ALL
  -- Pro-Item-Berechnungen (Install-Bedingung, berechneter Name), triviale statische weg
  SELECT va.Calc_UUID, va.Kind_Label, va.Is_Static, va.Display_Text,
         1 AS scope_order, im.Item_Index,
         '[' || CAST(im.Item_Index AS VARCHAR) || '] '
           || COALESCE(NULLIF(im.Command_Name, ''), 'FM-Befehl ' || CAST(im.Command_ID AS VARCHAR)) AS block_prefix
  FROM v_calc_anchors va
  JOIN item_meta im ON im.Item_UUID = va.Owner_UUID
  WHERE va.Owner_Type = 'CustomMenuItem'
    AND NOT (va.Is_Static AND trim(COALESCE(va.Display_Text, '')) IN ('1', ''))
),
blocks AS (
  SELECT *,
    DENSE_RANK() OVER (ORDER BY scope_order, item_index NULLS FIRST, Kind_Label) AS block_id
  FROM anchors
)
SELECT
  mm.Menu_UUID   AS object_uuid,
  mm.Menu_Name   AS object_name,
  mm.File_Name   AS object_file,
  b.block_id     AS block_id,
  b.block_prefix AS block_prefix,
  b.Kind_Label   AS calc_label,
  b.Is_Static    AS calc_is_static,
  b.Display_Text AS plain_text,
  d.Chunk_Index  AS chunk_index,
  d.Chunk_Type   AS chunk_type,
  d.Chunk_Content AS chunk_content,
  cfh.Object_UUID AS chunk_ref_uuid,
  -- Fachlicher MBS-Funktionsname, positionsgenau aus MBS_SubnameMap (inkl.
  -- P3.5-Klartext-Recovery) — autoritativ gegenüber der Nachbar-Chunk-Heuristik.
  msn.SubName     AS sub_function
FROM blocks b
CROSS JOIN menu_match mm
LEFT JOIN DDR_Calculations d
  ON d.Calc_UUID = b.Calc_UUID AND d.File_Name = mm.File_Name
LEFT JOIN MBS_SubnameMap msn
  ON msn.Calc_UUID = d.Calc_UUID
 AND msn.File_Name = d.File_Name
 AND msn.Plugin_Chunk_Index = d.Chunk_Index
LEFT JOIN ObjectHomes cfh
  ON d.Chunk_Type    = 'CustomFunctionRef'
 AND cfh.Object_Type = 'CustomFunction'
 AND cfh.Home_File   = mm.File_Name
 AND cfh.Object_Name = replace(replace(replace(replace(replace(
       regexp_extract(d.Chunk_Content, '<Chunk[^>]*>(.*)</Chunk>', 1),
       '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&apos;', ''''), '&amp;', '&')
ORDER BY b.block_id, d.Chunk_Index NULLS FIRST;
