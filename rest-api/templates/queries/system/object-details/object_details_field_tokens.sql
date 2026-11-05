-- @template_type: report
-- @description: Field with metadata, raw calculation text, and tokenized DDR chunks
-- @params: uuid (required)
-- @output_format: tokens
-- @author: Marcel
-- @version: 1.1
-- @tags: fields, ddr, tokens
-- @note: Liefert Calculation-Tokens für Calculated- und AutoEnter-Calculated-Felder.
--        Calc-Instanz robust über v_calc_anchors (Owner-UUID + Owner-Datei) aufgelöst
--        — NICHT über den mehrdeutigen Calc_Hash (siehe Kommentar an der calc_uuid-CTE).
--        Plain-Text aus Calculation_Text bzw. AE_Calc_Text (XML CDATA, vollständig).
--        AE_ConstantData liefert den festen Vorgabewert bei AutoEnter „ConstantData".

WITH fld AS (
  SELECT
    f.Field_UUID,
    f.Field_Name,
    f.File_Name,
    f.Table_Name,
    f.Field_Type,
    f.Data_Type,
    f.Is_Global,
    f.Max_Repetitions,
    f.Field_Comment,
    f.AutoEnter_Type,
    f.AE_ConstantData,
    f.AutoEnter_ProhibitMod,
    -- Serial (nur AutoEnter_Type='SerialNumber')
    f.Serial_Generate,
    f.Serial_NextValue,
    f.Serial_Increment,
    -- Lookup / Referenzwert (nur AutoEnter_Type='Looked_up')
    f.Lookup_Field_Name,
    f.Lookup_Field_UUID,
    -- Zieldatei des Lookup-Quellfelds über ObjectCatalog auflösen: Lookups sind
    -- häufig datei-übergreifend (Quellfeld liegt in einer anderen .fmp12), daher
    -- NICHT die aktuelle Datei annehmen. NULL, wenn Quellobjekt nicht im Katalog.
    lkoc.File_Name AS Lookup_Field_File,
    -- Herkunfts-BaseTable des Quellfelds (disambiguiert gleichnamige Felder,
    -- z.B. „Artikel Nr" existiert in vielen Tabellen → Anzeige „Artikel Nr (Artikel)").
    lf.Table_Name AS Lookup_Field_Table,
    f.Lookup_TO_Name,
    f.Lookup_DontCopyIfEmpty,
    f.Lookup_NoMatchOption,
    -- AutoEnter-Calc-Flags (nur AutoEnter_Type='Calculated')
    f.AE_Calc_OverwriteExisting,
    f.AE_Calc_AlwaysEvaluate,
    -- Überprüfung / Validierung
    f.Validation_Type,
    f.Validation_AllowOverride,
    f.Validation_NotEmpty,
    f.Validation_Unique,
    f.Validation_Existing,
    f.Validation_VL_Name,
    f.Validation_VL_UUID,
    -- Validierung (Schema 1.10.0)
    f.Validation_StrictType,
    f.Validation_MaxChars,
    f.Validation_Range_From,
    f.Validation_Range_To,
    f.Validation_Calc_Text,
    f.Validation_Message,
    -- Speicher / Indizierung
    f.Storage_Index,
    f.Storage_AutoIndex,
    f.Storage_StoreCalcResults,
    f.Storage_IndexLanguage,
    -- Statistik (nur Field_Type='Summary')
    f.Summary_Operation,
    f.Summary_Field_Name,
    f.Summary_Field_UUID,
    f.Summary_RestartEachGroup,
    f.Summary_RepetitionMode,
    -- FileMaker 26 (Schema 1.28.0/1.29.0): Anmerkung, Anzeigenamen, dormante Slots
    f.Field_Annotation,
    f.Field_DisplayNames_Enabled,
    f.DisplayNames_Calc_Text,
    f.AE_Calc_Enabled,
    f.Lookup_Enabled,
    f.Validation_Calc_Enabled,
    f.Validation_Message_Calc_Enabled,
    -- Calculation-Instanz der Anzeigenamen-Formel (Rolle display_names, nur DDR-verankert)
    (SELECT cc.Calculation_UUID FROM CalculationsCatalog cc
      WHERE cc.Owner_UUID = f.Field_UUID AND cc.File_Name = f.File_Name
        AND cc.Calc_Role = 'display_names' AND cc.DDR_Calc_UUID IS NOT NULL
      LIMIT 1) AS DisplayNames_Calc_UUID,
    -- JSON-Elemente der Anzeigenamen-Formel (P3 FieldDisplayNames) als JSON-Liste
    (SELECT to_json(list(struct_pack(seq := dn.Element_Seq, key := dn.Element_Key,
                                     value := dn.Value_Text, kind := dn.Value_Kind,
                                     jsonType := dn.Json_Type) ORDER BY dn.Element_Seq))
       FROM FieldDisplayNames dn
      WHERE dn.Field_UUID = f.Field_UUID AND dn.File_Name = f.File_Name) AS Display_Name_Elements,
    -- Calculation-Instanz-UUIDs der Validierungs-Slots (CalculationsCatalog):
    -- nur DDR-verankerte Instanzen (get-calc?uuid liefert sonst 404) — ohne
    -- Tokens bleibt der Klartext-Fallback (Validation_Calc_Text bzw. der
    -- strukturelle Text der validation_message-Instanz).
    (SELECT cc.Calculation_UUID FROM CalculationsCatalog cc
      WHERE cc.Owner_UUID = f.Field_UUID AND cc.File_Name = f.File_Name
        AND cc.Calc_Role = 'validation' AND cc.DDR_Calc_UUID IS NOT NULL
      LIMIT 1) AS Validation_Calc_UUID,
    (SELECT cc.Calculation_UUID FROM CalculationsCatalog cc
      WHERE cc.Owner_UUID = f.Field_UUID AND cc.File_Name = f.File_Name
        AND cc.Calc_Role = 'validation_message' AND cc.DDR_Calc_UUID IS NOT NULL
      LIMIT 1) AS Validation_Message_Calc_UUID,
    (SELECT COALESCE(cc.Formula_Text, cc.Display_Text) FROM CalculationsCatalog cc
      WHERE cc.Owner_UUID = f.Field_UUID AND cc.File_Name = f.File_Name
        AND cc.Calc_Role = 'validation_message'
      LIMIT 1) AS Validation_Message_Calc_Text,
    COALESCE(f.Calculation_Text, f.AE_Calc_Text) AS Effective_Text
  FROM FieldsForTables f
  JOIN ObjectCatalog oc ON f.Field_UUID = oc.Object_UUID AND f.File_Name = oc.File_Name
  LEFT JOIN ObjectCatalog lkoc ON lkoc.Object_UUID = f.Lookup_Field_UUID AND lkoc.Object_Type = 'Field'
  LEFT JOIN FieldsForTables lf ON lf.Field_UUID = f.Lookup_Field_UUID AND lf.File_Name = lkoc.File_Name
  WHERE oc.Object_UUID = getvariable('uuid')
    -- Klon-Disambiguierung: LIMIT 1 würde sonst einen beliebigen Klon liefern.
    AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  LIMIT 1
),
-- Robuste Calc-Auflösung über den CalculationsCatalog (Instanz = Owner × Rolle).
-- NICHT über Calc_Hash: der Hash ist NICHT eindeutig — semantisch-triviale Formeln
-- (z.B. Auto-Enter-„Konto-Name") teilen sich einen Hash über viele fremde Owner
-- (~16 % der Calc-Felder betroffen); ein MIN(Calc_UUID) pro Hash lieferte die
-- Chunks eines FREMDEN Felds → falsche Formel. Auch Calc_UUID/Field_UUID allein
-- genügt nicht, weil Field_UUID bei Klonen mehrfach (über Dateien) vorkommt.
-- Erst die robuste Kombination Owner-UUID + Owner-Datei löst eindeutig auf (1:1),
-- und der DDR-JOIN wird ebenfalls datei-skopiert (analog custommenu-Templates).
-- Rollen-Präferenz spiegelt Effective_Text: Haupt-Calculation vor AutoEnter.
calc_uuid AS (
  SELECT cc.DDR_Calc_UUID AS Calc_UUID, cc.File_Name
  FROM CalculationsCatalog cc, fld
  WHERE cc.Owner_UUID = fld.Field_UUID
    AND cc.File_Name = fld.File_Name
    AND cc.Calc_Role IN ('field_calculation', 'auto_enter')
    AND cc.DDR_Calc_UUID IS NOT NULL
  ORDER BY CASE cc.Calc_Role WHEN 'field_calculation' THEN 0 ELSE 1 END
  LIMIT 1
)
SELECT
  fld.Field_UUID         AS object_uuid,
  fld.Field_Name         AS object_name,
  fld.File_Name          AS object_file,
  fld.Table_Name         AS table_name,
  fld.Field_Type         AS field_type,
  fld.Data_Type          AS data_type,
  fld.Is_Global          AS is_global,
  fld.Max_Repetitions    AS max_repetitions,
  fld.Field_Comment      AS field_comment,
  fld.AutoEnter_Type     AS auto_enter_type,
  fld.AE_ConstantData    AS ae_constant_data,
  fld.AutoEnter_ProhibitMod    AS auto_enter_prohibit_mod,
  fld.Serial_Generate          AS serial_generate,
  fld.Serial_NextValue         AS serial_next_value,
  fld.Serial_Increment         AS serial_increment,
  fld.Lookup_Field_Name        AS lookup_field_name,
  fld.Lookup_Field_UUID        AS lookup_field_uuid,
  fld.Lookup_Field_File        AS lookup_field_file,
  fld.Lookup_Field_Table       AS lookup_field_table,
  fld.Lookup_TO_Name           AS lookup_to_name,
  fld.Lookup_DontCopyIfEmpty   AS lookup_dont_copy_if_empty,
  fld.Lookup_NoMatchOption     AS lookup_no_match_option,
  fld.AE_Calc_OverwriteExisting AS ae_calc_overwrite_existing,
  fld.AE_Calc_AlwaysEvaluate   AS ae_calc_always_evaluate,
  fld.Validation_Type          AS validation_type,
  fld.Validation_AllowOverride AS validation_allow_override,
  fld.Validation_NotEmpty      AS validation_not_empty,
  fld.Validation_Unique        AS validation_unique,
  fld.Validation_Existing      AS validation_existing,
  fld.Validation_VL_Name       AS validation_vl_name,
  fld.Validation_VL_UUID       AS validation_vl_uuid,
  fld.Validation_StrictType    AS validation_strict_type,
  fld.Validation_MaxChars      AS validation_max_chars,
  fld.Validation_Range_From    AS validation_range_from,
  fld.Validation_Range_To      AS validation_range_to,
  fld.Validation_Calc_Text     AS validation_calc_text,
  fld.Validation_Message       AS validation_message,
  fld.Validation_Calc_UUID     AS validation_calc_uuid,
  fld.Validation_Message_Calc_UUID AS validation_message_calc_uuid,
  fld.Validation_Message_Calc_Text AS validation_message_calc_text,
  fld.Storage_Index            AS storage_index,
  fld.Storage_AutoIndex        AS storage_auto_index,
  fld.Storage_StoreCalcResults AS storage_store_calc_results,
  fld.Storage_IndexLanguage    AS storage_index_language,
  fld.Summary_Operation        AS summary_operation,
  fld.Summary_Field_Name       AS summary_field_name,
  fld.Summary_Field_UUID       AS summary_field_uuid,
  fld.Summary_RestartEachGroup AS summary_restart_each_group,
  fld.Summary_RepetitionMode   AS summary_repetition_mode,
  fld.Field_Annotation         AS field_annotation,
  fld.Field_DisplayNames_Enabled AS display_names_enabled,
  fld.DisplayNames_Calc_Text   AS display_names_calc_text,
  fld.DisplayNames_Calc_UUID   AS display_names_calc_uuid,
  fld.Display_Name_Elements    AS display_name_elements,
  fld.AE_Calc_Enabled          AS ae_calc_enabled,
  fld.Lookup_Enabled           AS lookup_enabled,
  fld.Validation_Calc_Enabled  AS validation_calc_enabled,
  fld.Validation_Message_Calc_Enabled AS validation_message_calc_enabled,
  fld.Effective_Text     AS plain_text,
  d.Chunk_Index          AS chunk_index,
  d.Chunk_Type           AS chunk_type,
  d.Chunk_Content        AS chunk_content,
  cfh.Object_UUID        AS chunk_ref_uuid,
  -- Fachlicher MBS-Funktionsname, positionsgenau aus MBS_SubnameMap (inkl.
  -- P3.5-Klartext-Recovery) — autoritativ gegenüber der Nachbar-Chunk-Heuristik.
  msn.SubName            AS sub_function
FROM fld
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
 AND cfh.Home_File   = fld.File_Name
 AND cfh.Object_Name = replace(replace(replace(replace(replace(
       regexp_extract(d.Chunk_Content, '<Chunk[^>]*>(.*)</Chunk>', 1),
       '&lt;', '<'), '&gt;', '>'), '&quot;', '"'), '&apos;', ''''), '&amp;', '&')
ORDER BY d.Chunk_Index NULLS FIRST;
