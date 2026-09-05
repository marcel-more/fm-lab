-- ============================================================================
-- UUID-Healing — Kaskade (Schema 1.19.0, Stufe H1)
-- ============================================================================
-- Läuft EINMAL auf der fertig gemergten Master-DB: nach Abschluss von P1 (alle
-- Dateien, alle Chunks gemerged), VOR dem ersten P2-Statement (Einhängepunkt:
-- run_phase2() in ingestion/convert_fm_xml.sh — deckt Batch-, Turbo-, partitionierten
-- und Single-File-Modus gleichermaßen ab).
--
-- Zweck: In P1 wurden Intra-File-UUID-Duplikate geheilt (Zwillinge tragen
-- deterministische Ersatz-UUIDs; Mapping im Zensus DuplicateAbsorptionDetails,
-- Heal_Status='healed'). Abhängige P1-Tabellen führen die Eltern-UUID aber als
-- eigene Spalte (z. B. StepsForScripts.Script_UUID) — extrahiert aus dem XML,
-- also noch mit der Original-UUID. Diese Kaskade zieht die Fremd-UUID-Spalten
-- über den (File_Name, interne-ID)-Join nach. Sie MUSS post-merge laufen, weil
-- multi-fed Tabellen (z. B. ScriptTriggers aus Sections main+LayoutCatalog)
-- chunk-lokal kein vollständiges Bild haben.
--
-- Eigenschaften:
--   * Zensus-getrieben: keine 'healed'-Zeilen → jeder Join leer → No-Op
--     (duplikatfreie Korpora bleiben Lauf-zu-Lauf bit-identisch).
--   * Idempotent: nach dem Rewrite matcht Orig_UUID nicht mehr → zweiter Lauf No-Op.
--   * Exakter Diskriminator-Join (String-Gleichheit gegen das P1-Format),
--     kein Regex-Parsing.
--   * Datei-skopiert über hm.File_Name = <tabelle>.File_Name (Single-File-Import
--     in eine Master-DB mit Fremd-Dateien ist damit automatisch sicher).
--
-- BEWUSST NICHT kaskadiert (kein interner-ID-Begleiter am Verweis — Referenz
-- bleibt beim Survivor, dokumentierte Restgrenze, kein Rückschritt):
--   Layouts.L_TO_UUID · LayoutParts.Break_Field_UUID/Break_TO_UUID ·
--   FieldsForTables.Lookup_Field_UUID/Lookup_TO_UUID/Summary_Field_UUID ·
--   RelationshipCatalog Sort-Listen-Spalten (Left/Right_Sort_*_UUIDs[]) ·
--   PrivilegeSetRecordAccess.Context_TO_UUID ·
--   ScriptTriggers.Owner_UUID (PK-Bestandteil; Owner-Kataloge Layout/LayoutObject
--   sind sub-gechunkt und werden erst in Stufe H2 geheilt).

CREATE OR REPLACE TEMP TABLE _heal_map AS
SELECT File_Name, Catalog, Object_UUID AS Orig_UUID, Healed_UUID, Discriminator
FROM DuplicateAbsorptionDetails
WHERE Heal_Status = 'healed' AND Healed_UUID IS NOT NULL;

-- ---------------------------------------------------------------------------
-- ScriptCatalog geheilt → Script_UUID-Träger
-- ---------------------------------------------------------------------------
UPDATE StepsForScripts s
SET Script_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'ScriptCatalog'
  AND hm.File_Name = s.File_Name
  AND hm.Orig_UUID = s.Script_UUID
  AND hm.Discriminator = 'script_id=' || s.Script_ID::VARCHAR;

UPDATE ScriptTriggers t
SET Script_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'ScriptCatalog'
  AND hm.File_Name = t.File_Name
  AND hm.Orig_UUID = t.Script_UUID
  AND hm.Discriminator = 'script_id=' || t.Script_ID::VARCHAR;

-- ---------------------------------------------------------------------------
-- ExternalDataSourceCatalog geheilt → DS_UUID-Träger
-- ---------------------------------------------------------------------------
UPDATE TableOccurrenceCatalog o
SET DS_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'ExternalDataSourceCatalog'
  AND hm.File_Name = o.File_Name
  AND hm.Orig_UUID = o.DS_UUID
  AND hm.Discriminator = 'ds_id=' || o.DS_ID::VARCHAR;

UPDATE OptionsForValueLists o
SET External_DS_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'ExternalDataSourceCatalog'
  AND hm.File_Name = o.File_Name
  AND hm.Orig_UUID = o.External_DS_UUID
  AND hm.Discriminator = 'ds_id=' || o.External_DS_ID::VARCHAR;

-- ---------------------------------------------------------------------------
-- BaseTableCatalog geheilt → BT_UUID-/Table_UUID-Träger
-- ---------------------------------------------------------------------------
UPDATE TableOccurrenceCatalog o
SET BT_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'BaseTableCatalog'
  AND hm.File_Name = o.File_Name
  AND hm.Orig_UUID = o.BT_UUID
  AND hm.Discriminator = 'table_id=' || o.BT_ID::VARCHAR;

UPDATE FieldsForTables f
SET Table_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'BaseTableCatalog'
  AND hm.File_Name = f.File_Name
  AND hm.Orig_UUID = f.Table_UUID
  AND hm.Discriminator = 'table_id=' || f.Table_ID::VARCHAR;

UPDATE PrivilegeSetRecordAccess p
SET BaseTable_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'BaseTableCatalog'
  AND hm.File_Name = p.File_Name
  AND hm.Orig_UUID = p.BaseTable_UUID
  AND hm.Discriminator = 'table_id=' || p.BaseTable_ID::VARCHAR;

UPDATE PrivilegeSetFieldAccess p
SET BaseTable_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'BaseTableCatalog'
  AND hm.File_Name = p.File_Name
  AND hm.Orig_UUID = p.BaseTable_UUID
  AND hm.Discriminator = 'table_id=' || p.BaseTable_ID::VARCHAR;

-- ---------------------------------------------------------------------------
-- TableOccurrenceCatalog geheilt → TO_UUID-Träger
-- ---------------------------------------------------------------------------
UPDATE RelationshipCatalog r
SET Left_TO_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'TableOccurrenceCatalog'
  AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.Left_TO_UUID
  AND hm.Discriminator = 'to_id=' || r.Left_TO_ID::VARCHAR;

UPDATE RelationshipCatalog r
SET Right_TO_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'TableOccurrenceCatalog'
  AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.Right_TO_UUID
  AND hm.Discriminator = 'to_id=' || r.Right_TO_ID::VARCHAR;

UPDATE OptionsForValueLists o
SET TO_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'TableOccurrenceCatalog'
  AND hm.File_Name = o.File_Name
  AND hm.Orig_UUID = o.TO_UUID
  AND hm.Discriminator = 'to_id=' || o.TO_ID::VARCHAR;

UPDATE OptionsForValueLists o
SET Secondary_TO_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'TableOccurrenceCatalog'
  AND hm.File_Name = o.File_Name
  AND hm.Orig_UUID = o.Secondary_TO_UUID
  AND hm.Discriminator = 'to_id=' || o.Secondary_TO_ID::VARCHAR;

-- ---------------------------------------------------------------------------
-- FieldsForTables geheilt → Field_UUID-Träger (zweistufig: Feld-IDs sind
-- tabellen-lokal → Tabellen-Kontext über den TO- bzw. BaseTable-ID-Begleiter)
-- ---------------------------------------------------------------------------
UPDATE RelationshipCatalog r
SET Left_Field_UUID = hm.Healed_UUID
FROM TableOccurrenceCatalog t, _heal_map hm
WHERE t.File_Name = r.File_Name AND t.TO_ID = r.Left_TO_ID
  AND hm.Catalog = 'FieldsForTables'
  AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.Left_Field_UUID
  AND hm.Discriminator = 'table_id=' || t.BT_ID::VARCHAR || '·field_id=' || r.Left_Field_ID::VARCHAR;

UPDATE RelationshipCatalog r
SET Right_Field_UUID = hm.Healed_UUID
FROM TableOccurrenceCatalog t, _heal_map hm
WHERE t.File_Name = r.File_Name AND t.TO_ID = r.Right_TO_ID
  AND hm.Catalog = 'FieldsForTables'
  AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.Right_Field_UUID
  AND hm.Discriminator = 'table_id=' || t.BT_ID::VARCHAR || '·field_id=' || r.Right_Field_ID::VARCHAR;

UPDATE OptionsForValueLists o
SET Field_UUID = hm.Healed_UUID
FROM TableOccurrenceCatalog t, _heal_map hm
WHERE t.File_Name = o.File_Name AND t.TO_ID = o.TO_ID
  AND hm.Catalog = 'FieldsForTables'
  AND hm.File_Name = o.File_Name
  AND hm.Orig_UUID = o.Field_UUID
  AND hm.Discriminator = 'table_id=' || t.BT_ID::VARCHAR || '·field_id=' || o.Field_ID::VARCHAR;

UPDATE OptionsForValueLists o
SET Secondary_Field_UUID = hm.Healed_UUID
FROM TableOccurrenceCatalog t, _heal_map hm
WHERE t.File_Name = o.File_Name AND t.TO_ID = o.Secondary_TO_ID
  AND hm.Catalog = 'FieldsForTables'
  AND hm.File_Name = o.File_Name
  AND hm.Orig_UUID = o.Secondary_Field_UUID
  AND hm.Discriminator = 'table_id=' || t.BT_ID::VARCHAR || '·field_id=' || o.Secondary_Field_ID::VARCHAR;

UPDATE PrivilegeSetFieldAccess p
SET Field_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'FieldsForTables'
  AND hm.File_Name = p.File_Name
  AND hm.Orig_UUID = p.Field_UUID
  AND hm.Discriminator = 'table_id=' || p.BaseTable_ID::VARCHAR || '·field_id=' || p.Field_ID::VARCHAR;

-- ---------------------------------------------------------------------------
-- ValueListCatalog geheilt → VL_UUID-Träger (OptionsForValueLists.VL_UUID ist
-- PK und wird bereits INLINE in P1 mit identischer Formel geheilt — hier nur
-- die Nicht-PK-Träger)
-- ---------------------------------------------------------------------------
UPDATE FieldsForTables f
SET Validation_VL_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'ValueListCatalog'
  AND hm.File_Name = f.File_Name
  AND hm.Orig_UUID = f.Validation_VL_UUID
  AND hm.Discriminator = 'vl_id=' || f.Validation_VL_ID::VARCHAR;

-- ---------------------------------------------------------------------------
-- Layouts geheilt (H2) → L_UUID-Träger. ScriptTriggers.Owner_UUID (PK-Bestandteil)
-- und Layouts.L_TO_UUID (kein ID-Begleiter) bleiben bewusst außen vor (s. Kopf).
-- ---------------------------------------------------------------------------
UPDATE FileOptionsCatalog f
SET Default_Layout_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE hm.Catalog = 'Layouts'
  AND hm.File_Name = f.File_Name
  AND hm.Orig_UUID = f.Default_Layout_UUID
  AND hm.Discriminator = 'layout_id=' || f.Default_Layout_ID::VARCHAR;

DROP TABLE _heal_map;
