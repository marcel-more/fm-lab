-- @template_type: report
-- @description: Custom Menu Item calculations (Install condition, calculated name) as tokenized DDR chunks
-- @params: uuid (required)
-- @output_format: tokens
-- @author: Marcel
-- @version: 1.0
-- @tags: custommenuitem, ddr, tokens, calculations
-- @note: Liefert die Calc-Tokens eines einzelnen Custom-Menu-Items (Install-Bedingung,
--        berechneter Name). Ein Block pro Anker (block_id). Triviale statische
--        Install-Bedingungen ("1"/leer) werden ausgelassen. Ausgabe-Schema und
--        Formatter (kind='custommenu') identisch zu object_details_custommenu_tokens.sql.

WITH item_match AS (
  SELECT i.Item_UUID, i.Item_Index, i.Command_Name, i.Command_ID, i.File_Name
  FROM CustomMenuItemCatalog i
  WHERE i.Item_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR i.File_Name = getvariable('file'))
  LIMIT 1
),
anchors AS (
  SELECT va.Calc_UUID, va.Kind_Label, va.Is_Static, va.Display_Text
  FROM v_calc_anchors va, item_match im
  WHERE va.Owner_Type = 'CustomMenuItem'
    AND va.Owner_UUID = im.Item_UUID
    AND va.Owner_File = im.File_Name
    AND NOT (va.Is_Static AND trim(COALESCE(va.Display_Text, '')) IN ('1', ''))
),
blocks AS (
  SELECT *, DENSE_RANK() OVER (ORDER BY Kind_Label) AS block_id
  FROM anchors
)
SELECT
  im.Item_UUID   AS object_uuid,
  im.Command_Name AS object_name,
  im.File_Name   AS object_file,
  b.block_id     AS block_id,
  CAST(NULL AS VARCHAR) AS block_prefix,
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
CROSS JOIN item_match im
LEFT JOIN DDR_Calculations d
  ON d.Calc_UUID = b.Calc_UUID AND d.File_Name = im.File_Name
LEFT JOIN MBS_SubnameMap msn
  ON msn.Calc_UUID = d.Calc_UUID
 AND msn.File_Name = d.File_Name
 AND msn.Plugin_Chunk_Index = d.Chunk_Index
LEFT JOIN ObjectHomes cfh
  ON d.Chunk_Type    = 'CustomFunctionRef'
 AND cfh.Object_Type = 'CustomFunction'
 AND cfh.Home_File   = im.File_Name
 AND cfh.Object_Name = replace(replace(replace(replace(replace(
       regexp_extract(d.Chunk_Content, '<Chunk[^>]*>(.*)</Chunk>', 1),
       '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&apos;', ''''), '&amp;', '&')
ORDER BY b.block_id, d.Chunk_Index NULLS FIRST;
