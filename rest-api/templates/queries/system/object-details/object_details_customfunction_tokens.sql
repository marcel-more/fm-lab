-- @template_type: report
-- @description: Custom function with parameter list, raw code, and tokenized chunks
-- @params: uuid (required)
-- @output_format: tokens
-- @author: Marcel
-- @version: 1.1
-- @tags: customfunctions, ddr, tokens

WITH cf AS (
  SELECT
    cf.CF_UUID,
    cf.CF_Name,
    cf.File_Name,
    cf.Parameters,
    ccf.Calculation_Code
  FROM CustomFunctionsCatalog cf
  LEFT JOIN CalcsForCustomFunctions ccf
    ON cf.CF_UUID = ccf.CF_UUID
   AND cf.File_Name = ccf.File_Name
  WHERE cf.CF_UUID = getvariable('uuid')
    -- Klon-Disambiguierung: LIMIT 1 würde sonst einen beliebigen Klon liefern.
    AND (getvariable('file') IS NULL OR cf.File_Name = getvariable('file'))
  LIMIT 1
),
-- Robuste Calc-Auflösung über den CalculationsCatalog (Instanz = Owner × Rolle).
-- NICHT über Calc_Hash: der Hash ist NICHT eindeutig — mehrere Calc_UUIDs teilen
-- sich einen Hash. Meist sind das identische Mehrdatei-Kopien derselben CF (harmlos),
-- vereinzelt aber ECHTE Kollisionen unterschiedlicher Formeln → ein MIN(Calc_UUID)
-- pro Hash lieferte dann fremde Chunks. Zudem ist CF_UUID bei Klonen dateiübergreifend
-- nicht eindeutig. Erst die robuste Kombination Owner-UUID + Owner-Datei löst
-- eindeutig auf (1:1); der DDR-JOIN wird ebenfalls datei-skopiert.
calc_uuid AS (
  SELECT cc.DDR_Calc_UUID AS Calc_UUID, cc.File_Name
  FROM CalculationsCatalog cc, cf
  WHERE cc.Calc_Role = 'custom_function'
    AND cc.Owner_UUID = cf.CF_UUID
    AND cc.File_Name = cf.File_Name
    AND cc.DDR_Calc_UUID IS NOT NULL
  LIMIT 1
)
SELECT
  cf.CF_UUID AS object_uuid,
  cf.CF_Name AS object_name,
  cf.File_Name AS object_file,
  cf.Parameters AS parameters,
  cf.Calculation_Code AS plain_text,
  d.Chunk_Index AS chunk_index,
  d.Chunk_Type AS chunk_type,
  d.Chunk_Content AS chunk_content,
  cfh.Object_UUID AS chunk_ref_uuid,
  -- Fachlicher MBS-Funktionsname, positionsgenau aus MBS_SubnameMap (inkl.
  -- P3.5-Klartext-Recovery) — autoritativ gegenüber der Nachbar-Chunk-Heuristik.
  msn.SubName     AS sub_function
FROM cf
LEFT JOIN calc_uuid ON TRUE
LEFT JOIN DDR_Calculations d
  ON d.Calc_UUID = calc_uuid.Calc_UUID
 AND d.File_Name = calc_uuid.File_Name
LEFT JOIN MBS_SubnameMap msn
  ON msn.Calc_UUID = d.Calc_UUID
 AND msn.File_Name = d.File_Name
 AND msn.Plugin_Chunk_Index = d.Chunk_Index
-- CustomFunctionRef-Chunks tragen anders als FieldRef nur den CF-Namen, keine
-- UUID. Für Cross-Navigation (klickbarer Link) UND Cross-Reference-Highlight
-- lösen wir den Namen file-lokal über ObjectHomes auf (CF-Namen sind je Datei
-- eindeutig — analog object_references_script.sql). Inner-Name wird aus dem
-- Chunk-Wrapper extrahiert und die Standard-XML-Entities werden dekodiert.
LEFT JOIN ObjectHomes cfh
  ON d.Chunk_Type    = 'CustomFunctionRef'
 AND cfh.Object_Type = 'CustomFunction'
 AND cfh.Home_File   = cf.File_Name
 AND cfh.Object_Name = replace(replace(replace(replace(replace(
       regexp_extract(d.Chunk_Content, '<Chunk[^>]*>(.*)</Chunk>', 1),
       '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&apos;', ''''), '&amp;', '&')
ORDER BY d.Chunk_Index NULLS FIRST;
