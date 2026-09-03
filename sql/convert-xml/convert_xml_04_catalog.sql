/*
-- convert_xml_04_catalog.sql — Phase 4 der XML-Konvertierungs-Pipeline.
-- Generischer ObjektKatalog + Links:
-- ObjectCatalog (alle Objekttypen) und ObjectLinks (operational + structural,
-- cross-file). TABLE-ONLY (liest nur P1–P3-Tabellen, kein read_xml). Läuft nach
-- Phase 3, datei-übergreifend, einmal am Schluss.
-- Ausgekoppelt aus create_universal_catalogs.sql (Phase B/C/D, Logik unverändert).
*/

-- ############################################################
-- Phase A: Cross-File-Auflösung leerer Step-Referenz-UUIDs
-- ############################################################
-- Bei datei-übergreifenden Bezügen schreibt FileMaker KEINE Ziel-UUID, sondern nur den
-- <DataSourceReference> (Zieldatei) + die datei-lokale id (+ Name):
--   <LayoutReferenceContainer External="True">
--     <DataSourceReference name="Artikel Einkauf"/>
--     <LayoutReference id="1" name="Stammdaten" UUID=""/>     ← UUID leer
-- P2 liefert dann Ref_UUID='' → der Graph-Link (navigates_to_layout/calls_script/
-- sets_field …) dangelt (Target_UUID='') und das Ziel erscheint im Where-used als
-- ungenutzt. Hier — NACH dem batch-weiten P2-Merge, vor dem ObjectLinks-Aufbau — lösen
-- wir die echte UUID auf. Bewusst in P4 (nicht P2): P2 läuft datei-PARTITIONIERT (je Slice
-- nur die eigenen Dateien), die Auflösung ist aber DATEI-ÜBERGREIFEND und braucht die
-- volle Master-XMLStepReferences + alle Kataloge.
-- xml_extract_text läuft auf der Step_XML-SPALTE (KEIN read_xml/DOM → minimaler Peak; nur
-- ~1,5k External-Step-Zeilen), daher die webbed-Last vernachlässigbar.
INSTALL webbed FROM community;
LOAD webbed;

-- Layout: External GTRR / Go to Layout — DataSourceReference-Name → Zieldatei
-- (Strip '.fmp12') + lokale LayoutReference-id → Layouts.L_UUID. Pro Step genau EINE
-- Layout-Zeile (//…@UUID[1]) → UPDATE über Step_UUID eindeutig. ≈97 % auflösbar
-- (Rest = referenzierte Datei nicht importiert → bleibt leer, korrekt nicht-navigierbar).
-- Greift nicht nur bei LEERER UUID, sondern auch bei vorhandener-aber-nicht-auflösbarer
-- (synthetische Proxy-UUID einer cross-file-Referenz — steht in keinem Layouts-Katalog).
UPDATE XMLStepReferences x
SET Ref_UUID = r.resolved_uuid
FROM (
    SELECT x2.Step_UUID, lay.L_UUID AS resolved_uuid
    FROM XMLStepReferences x2
    JOIN StepsForScripts st ON st.Step_UUID = x2.Step_UUID
    JOIN Layouts lay
      ON lay.File_Name = regexp_replace(
             NULLIF(xml_extract_text(st.Step_XML, '//DataSourceReference/@name')[1], ''),
             '\.fmp12$', '')
     AND lay.L_ID = TRY_CAST(
             NULLIF(xml_extract_text(st.Step_XML, '//LayoutReferenceContainer/LayoutReference/@id')[1], '')
             AS BIGINT)
    WHERE x2.Ref_Type = 'layout'
      AND (x2.Ref_UUID IS NULL OR x2.Ref_UUID = ''
           OR x2.Ref_UUID NOT IN (SELECT L_UUID FROM Layouts WHERE L_UUID IS NOT NULL))
) r
WHERE x.Step_UUID = r.Step_UUID
  AND x.Ref_Type = 'layout'
  AND (x.Ref_UUID IS NULL OR x.Ref_UUID = ''
       OR x.Ref_UUID NOT IN (SELECT L_UUID FROM Layouts WHERE L_UUID IS NOT NULL));

-- Script: External Perform Script — DataSourceReference-Name → Zieldatei + lokale
-- ScriptReference-id → ScriptCatalog.Script_UUID. ≈99 % auflösbar. Wie oben auch für
-- vorhandene-aber-synthetische UUIDs (cross-file Perform Script trägt eine Proxy-UUID,
-- die nicht im ScriptCatalog steht → calls_script-Kante ging sonst verloren).
UPDATE XMLStepReferences x
SET Ref_UUID = r.resolved_uuid
FROM (
    SELECT x2.Step_UUID, scr.Script_UUID AS resolved_uuid
    FROM XMLStepReferences x2
    JOIN StepsForScripts st ON st.Step_UUID = x2.Step_UUID
    JOIN ScriptCatalog scr
      ON scr.File_Name = regexp_replace(
             NULLIF(xml_extract_text(st.Step_XML, '//DataSourceReference/@name')[1], ''),
             '\.fmp12$', '')
     AND scr.Script_ID = TRY_CAST(
             NULLIF(xml_extract_text(st.Step_XML, '//ScriptReference/@id')[1], '')
             AS BIGINT)
    WHERE x2.Ref_Type = 'script'
      AND (x2.Ref_UUID IS NULL OR x2.Ref_UUID = ''
           OR x2.Ref_UUID NOT IN (SELECT Script_UUID FROM ScriptCatalog WHERE Script_UUID IS NOT NULL))
) r
WHERE x.Step_UUID = r.Step_UUID
  AND x.Ref_Type = 'script'
  AND (x.Ref_UUID IS NULL OR x.Ref_UUID = ''
       OR x.Ref_UUID NOT IN (SELECT Script_UUID FROM ScriptCatalog WHERE Script_UUID IS NOT NULL));

-- Feld: TO-relativ ausgelassene ODER kontext-synthetische UUID (Set Field / Sort /
-- Go to Field / Import / Export / Find …). FileMaker lässt die Feld-UUID entweder weg
-- ODER liefert eine pro Feld×TableOccurrence synthetische UUID (nur über die Home-TO =
-- Katalog-UUID; über related TOs in keinem Katalog) — beide Fälle liefern aber den
-- TO-Kontext mit. Die TO zeigt ggf. auf eine Basistabelle in einer ANDEREN Datei
-- (TableOccurrenceCatalog.BT_UUID NULL, aber BT_Name + DS_Name gesetzt) → Heimat der
-- Basistabelle: DS_Name → Datei (sonst die TO-eigene Datei) + BT_Name + Feldname →
-- FieldsForTables.Field_UUID. Reine Tabellen-Auflösung (kein XML). (TO_UUID, Feldname) ist
-- eindeutig (durch BT_Name-Skopierung kollisionsfrei); Match über (TO_UUID, Ref_Name), da
-- ein Step mehrere Feldzeilen haben kann. Ohne diese Auflösung verlöre der reads_field-/
-- sets_field-/sorts_by_field-INNER-JOIN die Kante still → Feld erschiene ungenutzt.
UPDATE XMLStepReferences x
SET Ref_UUID = r.field_uuid
FROM (
    -- File-Scope wie die Calc-Variante unten — ohne toc.File_Name im Join
    -- band ein Klon-Korpus (geteilte TO_UUIDs über Dateien) nichtdeterministisch
    -- eine potenziell datei-fremde Feld-UUID.
    SELECT toc.TO_UUID, toc.File_Name, f.Field_Name, f.Field_UUID AS field_uuid
    FROM TableOccurrenceCatalog toc
    JOIN FieldsForTables f
      ON f.Table_Name = toc.BT_Name
     AND f.File_Name = regexp_replace(
             COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
    WHERE toc.TO_UUID IN (
        SELECT DISTINCT TO_UUID FROM XMLStepReferences
        WHERE Ref_Type = 'field' AND TO_UUID IS NOT NULL
          AND (Ref_UUID IS NULL OR Ref_UUID = ''
               OR Ref_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL))
    )
) r
WHERE x.Ref_Type = 'field' AND x.TO_UUID IS NOT NULL
  AND (x.Ref_UUID IS NULL OR x.Ref_UUID = ''
       OR x.Ref_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL))
  AND x.TO_UUID = r.TO_UUID AND x.Ref_Name = r.Field_Name
  AND x.File_Name = r.File_Name;

-- Calc-FieldRef: kontext-spezifische UUID → kanonische Feld-UUID.
-- FileMaker vergibt in DDR-Calc-Chunks auf <FieldReference> eine pro Feld×TableOccurrence
-- eigene UUID. Nur über die Home-TO (TO-Name = Basistabelle) stimmt sie mit der Katalog-
-- UUID überein; über jede related TO ist sie synthetisch und steht in KEINEM Katalog.
-- Block 30 (Calc-Source → Field) joint per INNER JOIN auf ObjectCatalog → solche Referenzen
-- verlieren still ihre reads_field-Kante (~37 % der Calc-FieldRefs, reine Where-used-Lücke:
-- ein Feld, das nur über eine related TO in einer Berechnung referenziert wird, erscheint
-- sonst als ungenutzt). Fix analog zum Leer-UUID-Resolver oben, aber für den Fall
-- vorhandene-aber-nicht-auflösbare UUID: über die mitgelieferte TO_UUID (+ Feldname) auf die
-- kanonische Feld-UUID umschreiben. (TO_UUID, Feldname) ist durch BT_Name-Skopierung
-- eindeutig. Der Rest (~4 %) sind entity-kodierte Feldnamen (webbed-Serializer) — dort
-- separat behoben, hier bewusst unangetastet gelassen.
UPDATE XMLCalcReferences x
SET Ref_UUID = r.field_uuid
FROM (
    SELECT toc.TO_UUID, toc.File_Name, f.Field_Name, f.Field_UUID AS field_uuid
    FROM TableOccurrenceCatalog toc
    JOIN FieldsForTables f
      ON f.Table_Name = toc.BT_Name
     AND f.File_Name = regexp_replace(
             COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
) r
WHERE x.Ref_Type = 'field'
  AND x.TO_UUID IS NOT NULL
  AND x.TO_UUID = r.TO_UUID
  AND x.File_Name = r.File_Name
  AND x.Ref_Name = r.Field_Name
  AND x.Ref_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL);

-- LayoutObject-Feld-Anzeige (displays_field): dieselbe kontext-synthetische FieldReference-
-- UUID wie in Steps/Calcs, hier auf Layout-Objekten. XMLLayoutReferences trägt keinen
-- TO-Kontext → direkt aus LayoutObjects.Object_XML auflösen (TO-UUID + Feld-id → kanonische
-- Feld-UUID via TableOccurrenceCatalog + Home-Datei). Ein LayoutObject zeigt genau EIN Feld
-- (ein FieldReference) → Object_UUID eindeutig. Scan nur über die betroffenen Objekte
-- (Phantom-UUID, gefiltert über die Object_UUID-SPALTE) → geringer webbed-Footprint.
-- Feld-id (statt -name) ist entity-frei. Ohne die Auflösung fehlt das Feld in der
-- Where-used-Analyse „auf welchen Layouts wird Feld X angezeigt?".
UPDATE XMLLayoutReferences x
SET Ref_UUID = r.field_uuid
FROM (
    SELECT lo.Object_UUID AS lo_uuid, f.Field_UUID AS field_uuid
    FROM (
        SELECT
            Object_UUID, File_Name,
            NULLIF(xml_extract_text(Object_XML, '/LayoutObject/Field/FieldReference/TableOccurrenceReference/@UUID')[1], '') AS to_uuid,
            TRY_CAST(xml_extract_text(Object_XML, '/LayoutObject/Field/FieldReference/@id')[1] AS BIGINT) AS field_id
        FROM LayoutObjects
        WHERE Object_XML LIKE '%FieldReference%'
          AND Object_UUID IN (
              SELECT Object_UUID FROM XMLLayoutReferences
              WHERE Ref_Type = 'field'
                AND (Ref_UUID IS NULL   -- Leere UUID jetzt NULL (statt ''); Kandidat für TO+Feld-id-Auflösung bleiben
                     OR Ref_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL))
          )
    ) lo
    JOIN TableOccurrenceCatalog toc ON toc.TO_UUID = lo.to_uuid AND toc.File_Name = lo.File_Name
    JOIN FieldsForTables f
      ON f.Table_Name = toc.BT_Name
     AND f.File_Name = regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
     AND f.Field_ID = lo.field_id
) r
WHERE x.Ref_Type = 'field'
  AND x.Object_UUID = r.lo_uuid
  AND (x.Ref_UUID IS NULL   -- Leere UUID jetzt NULL (statt '') → weiterhin auflösbar
       OR x.Ref_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL));

-- Empty-String-Hygiene: unaufgelöste Referenzen müssen NULL sein, nie ''. Externe-TO-
-- Feldrefs mit UUID="" (DDR-Calc-Chunks: regexp_extract liefert '' bei leerem Attribut;
-- Step-Refs: xml_extract auf leerem @UUID) überleben die Resolver oben, wenn TO+Feld-id
-- nicht auflösbar ist (z. B. Feld liegt in einer nicht-importierten Datei). NACH den
-- Resolvern normalisieren (davor bräuchten diese die ''-Werte zum Matchen). Der Feldname
-- (Ref_Name) bleibt für spätere Name-/ID-Auflösung erhalten. Downstream reads_field joint
-- per INNER JOIN auf ObjectCatalog (+ Ref_UUID IS NOT NULL) → NULL erzeugt keinen Link,
-- '' erzeugte auch keinen (kein Feld hat UUID '') — nur die Empty-String-Invariante.
-- XMLLayoutReferences ist bereits an der P2-Quelle genullt (NULLIF); hier belt-and-suspenders.
UPDATE XMLCalcReferences   SET Ref_UUID = NULL WHERE Ref_UUID = '';
UPDATE XMLCalcReferences   SET Ref_Name = NULL WHERE Ref_Name = '';
UPDATE XMLStepReferences   SET Ref_UUID = NULL WHERE Ref_UUID = '';
UPDATE XMLStepReferences   SET Ref_Name = NULL WHERE Ref_Name = '';
UPDATE XMLLayoutReferences SET Ref_UUID = NULL WHERE Ref_UUID = '';
UPDATE XMLLayoutReferences SET Ref_Name = NULL WHERE Ref_Name = '';

-- ============================================
-- UUID-Healing — Stufe (1) der kanonischen Ziel-Auflösungs-Reihenfolge:
-- Ref_ID-Rewrite intra-file (Schema 1.19.0)
-- ============================================
-- Intra-File-UUID-Duplikate wurden in P1 geheilt (Zwillinge tragen deterministische
-- Ersatz-UUIDs, Mapping im Zensus DuplicateAbsorptionDetails). Die XML-Referenzen
-- tragen aber weiterhin die ORIGINAL-UUID — ohne Rewrite liefen alle eingehenden
-- Kanten auf den Survivor (Graph-Insel-Problem). Das SaXML referenziert als Tripel
-- id+name+UUID; die in P2 mitextrahierte Ref_ID disambiguiert den richtigen Zwilling.
--
-- Realisierung VOR dem ObjectLinks-CTAS an den P2-Referenztabellen selbst (statt
-- nachträglich an ObjectLinks): so greifen CTAS UND alle Folge-INSERTs uniform,
-- kein Resolver muss angefasst werden, und die Doktrin-Reihenfolge bleibt gewahrt —
-- Stufe (1) läuft physisch vor Block-6-Scoping (2), prefer-local (3), keep (4).
--
-- Schlüssel je Referenz-Rolle: flache Referenzen (Script/Layout/TO/ValueList) über
-- (File_Name, Ref_ID); Feld-Referenzen ZWEISTUFIG (FieldReference/@id ist tabellen-
-- lokal): TO_Ref_ID → TableOccurrenceCatalog.TO_ID → BT_ID → (table_id, field_id).
-- Der Discriminator-Join ist exakt (String-Gleichheit gegen das P1-Format), kein
-- Regex-Parsing. Scope bleibt intra-file: hm.File_Name = Quelldatei der Referenz.
-- Refs ohne Ref_ID oder auf den Survivor (kept-original) bleiben unverändert —
-- kein Rückschritt. Duplikatfreie Korpora: _heal_map leer → alle UPDATEs No-Op.
CREATE OR REPLACE TEMP TABLE _heal_map AS
SELECT File_Name, Catalog, Object_UUID AS Orig_UUID, Healed_UUID, Discriminator
FROM DuplicateAbsorptionDetails
WHERE Heal_Status = 'healed' AND Healed_UUID IS NOT NULL;

-- Kontext-TO der Feld-Referenzen (TO selbst geheilt): TO_UUID nachziehen, damit die
-- TO-basierten Feld-Resolver (Phase A oben ist bereits gelaufen; Kontext-Nutzung
-- unten) den richtigen Zwilling treffen.
UPDATE XMLStepReferences r
SET TO_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE r.TO_Ref_ID IS NOT NULL AND r.TO_UUID IS NOT NULL
  AND hm.Catalog = 'TableOccurrenceCatalog' AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.TO_UUID
  AND hm.Discriminator = 'to_id=' || r.TO_Ref_ID::VARCHAR;

UPDATE XMLCalcReferences r
SET TO_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE r.TO_Ref_ID IS NOT NULL AND r.TO_UUID IS NOT NULL
  AND hm.Catalog = 'TableOccurrenceCatalog' AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.TO_UUID
  AND hm.Discriminator = 'to_id=' || r.TO_Ref_ID::VARCHAR;

-- Flache Referenzen: XMLStepReferences (script/layout/tableOccurrence/valuelist)
UPDATE XMLStepReferences r
SET Ref_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE r.Ref_ID IS NOT NULL AND r.Ref_UUID IS NOT NULL
  AND hm.File_Name = r.File_Name AND hm.Orig_UUID = r.Ref_UUID
  AND ((r.Ref_Type = 'script'          AND hm.Catalog = 'ScriptCatalog'          AND hm.Discriminator = 'script_id=' || r.Ref_ID::VARCHAR
        AND r.Data_Source_Name IS NULL)  -- Cross-File-Aufrufe bleiben beim Survivor (Doktrin: Scope intra-file)
    OR (r.Ref_Type = 'layout'          AND hm.Catalog = 'Layouts'                AND hm.Discriminator = 'layout_id=' || r.Ref_ID::VARCHAR)
    OR (r.Ref_Type = 'tableOccurrence' AND hm.Catalog = 'TableOccurrenceCatalog' AND hm.Discriminator = 'to_id='     || r.Ref_ID::VARCHAR)
    OR (r.Ref_Type = 'valuelist'       AND hm.Catalog = 'ValueListCatalog'       AND hm.Discriminator = 'vl_id='     || r.Ref_ID::VARCHAR));

-- Flache Referenzen: XMLLayoutReferences (script/layout_step/table_occurrence[_step]/valuelist[_sort])
UPDATE XMLLayoutReferences r
SET Ref_UUID = hm.Healed_UUID
FROM _heal_map hm
WHERE r.Ref_ID IS NOT NULL AND r.Ref_UUID IS NOT NULL
  AND hm.File_Name = r.File_Name AND hm.Orig_UUID = r.Ref_UUID
  AND ((r.Ref_Type = 'script'                                        AND hm.Catalog = 'ScriptCatalog'          AND hm.Discriminator = 'script_id=' || r.Ref_ID::VARCHAR)
    OR (r.Ref_Type = 'layout_step'                                   AND hm.Catalog = 'Layouts'                AND hm.Discriminator = 'layout_id=' || r.Ref_ID::VARCHAR)
    OR (r.Ref_Type IN ('table_occurrence', 'table_occurrence_step')  AND hm.Catalog = 'TableOccurrenceCatalog' AND hm.Discriminator = 'to_id='     || r.Ref_ID::VARCHAR)
    OR (r.Ref_Type IN ('valuelist', 'valuelist_sort')                AND hm.Catalog = 'ValueListCatalog'       AND hm.Discriminator = 'vl_id='     || r.Ref_ID::VARCHAR));

-- Feld-Referenzen (zweistufig über den TO-Kontext) — alle drei P2-Quellen uniform.
-- TO_Ref_ID ist die interne TO-@id (heilungs-immun); TOs sind stets datei-lokal,
-- externe Basistabellen matchen mangels lokaler table_id im Zensus nicht (No-Op).
UPDATE XMLStepReferences r
SET Ref_UUID = hm.Healed_UUID
FROM TableOccurrenceCatalog t, _heal_map hm
WHERE r.Ref_Type = 'field' AND r.Ref_ID IS NOT NULL AND r.TO_Ref_ID IS NOT NULL AND r.Ref_UUID IS NOT NULL
  AND t.File_Name = r.File_Name AND t.TO_ID = r.TO_Ref_ID
  AND hm.Catalog = 'FieldsForTables' AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.Ref_UUID
  AND hm.Discriminator = 'table_id=' || t.BT_ID::VARCHAR || '·field_id=' || r.Ref_ID::VARCHAR;

UPDATE XMLLayoutReferences r
SET Ref_UUID = hm.Healed_UUID
FROM TableOccurrenceCatalog t, _heal_map hm
WHERE r.Ref_Type IN ('field', 'field_step') AND r.Ref_ID IS NOT NULL AND r.TO_Ref_ID IS NOT NULL AND r.Ref_UUID IS NOT NULL
  AND t.File_Name = r.File_Name AND t.TO_ID = r.TO_Ref_ID
  AND hm.Catalog = 'FieldsForTables' AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.Ref_UUID
  AND hm.Discriminator = 'table_id=' || t.BT_ID::VARCHAR || '·field_id=' || r.Ref_ID::VARCHAR;

UPDATE XMLCalcReferences r
SET Ref_UUID = hm.Healed_UUID
FROM TableOccurrenceCatalog t, _heal_map hm
WHERE r.Ref_Type = 'field' AND r.Ref_ID IS NOT NULL AND r.TO_Ref_ID IS NOT NULL AND r.Ref_UUID IS NOT NULL
  AND t.File_Name = r.File_Name AND t.TO_ID = r.TO_Ref_ID
  AND hm.Catalog = 'FieldsForTables' AND hm.File_Name = r.File_Name
  AND hm.Orig_UUID = r.Ref_UUID
  AND hm.Discriminator = 'table_id=' || t.BT_ID::VARCHAR || '·field_id=' || r.Ref_ID::VARCHAR;

DROP TABLE _heal_map;

-- LayoutObjects.Object_Type-Locale-Normalisierung. `Object_Type` kommt aus dem
-- LOKALISIERTEN `/LayoutObject/@type`-String (dt. Exporte wie Shopschnittstelle/Bilder
-- Schnittstelle tragen „Bearbeitungsfeld" statt „Edit Box" etc.) → typ-gefilterte Analysen,
-- Dashboards UND die P4-Link-Blöcke unten (die Object_Type-Literale wie 'Popover Button'
-- prüfen) zählen sie sonst falsch. Es gibt KEINEN locale-unabhängigen Voll-Diskriminator:
-- das `kind`-Attribut (P1-Spalte Object_Kind) ist zu grob (kind=1 = ALLE Feld-Controls:
-- Edit Box, Checkbox Set, Drop-down List …; kind=8 = Group + Grouped Button). Daher ein
-- kuratiertes DE→EN-Namens-Mapping. Jede Zeile gegen `kind` cross-validiert (identisch für
-- DE-Name und EN-Ziel): Bearbeitungsfeld/Edit Box=1, Linie/Line=4, Rechteck/Rectangle=5,
-- Gruppierte Taste/Grouped Button=8, Ausschnitt/Portal=9, Taste/Button=10,
-- Registersteuerelement/Tab Control=11, Markierungsfelder/Checkbox Set=1, Einblendliste/
-- Drop-down List=1. Muss VOR den Object_Type-prüfenden Link-Blöcken laufen. Neue Locale-
-- Namen künftiger Exporte meldet P6 v_check_unknown_object_types (unten). Erweiterbar (FR/…).
UPDATE LayoutObjects lo
SET Object_Type = m.canonical
FROM (VALUES
    ('Bearbeitungsfeld',      'Edit Box'),
    ('Markierungsfelder',     'Checkbox Set'),
    ('Einblendliste',         'Drop-down List'),
    ('Linie',                 'Line'),
    ('Rechteck',              'Rectangle'),
    ('Gruppierte Taste',      'Grouped Button'),
    ('Ausschnitt',            'Portal'),
    ('Taste',                 'Button'),
    ('Registersteuerelement', 'Tab Control')
) AS m(localized, canonical)
WHERE lo.Object_Type = m.localized;

-- LayoutParts.Part_Type-Locale-Normalisierung (dieselbe Klasse wie Object_Type).
-- `Part_Type` = lokalisierter /Part/@type-String → der breaks_on_field-Filter unten
-- (`Part_Type LIKE '%Sub-summary%'`) verpasst „Vorangestelltes Zwischenergebnis" (=Leading
-- Sub-summary), und Part_Type-gefilterte Analysen + Link_Subrole zählen dt. Parts falsch.
-- Mapping gegen das locale-unabhängige `/Part/@kind` (P1-Spalte Part_Kind) cross-validiert:
-- Kopfbereich/Header=1, Datenbereich/Body=4, Fußbereich/Footer=7, Obere Nav./Top Nav.=12,
-- Vorangestelltes Zwischenergebnis/Leading Sub-summary=3. Muss VOR dem breaks_on_field-Block
-- laufen; danach greift dessen `LIKE '%Sub-summary%'` locale-robust (+3 auflösbare Links).
-- (Anomalie außerhalb dieses Scopes: 273 kind=5-Parts tragen @type „Trailing Grand Summary"
--  MIT Break-Feld — Verhalten bewusst unverändert.) Neue Locale-Namen meldet P6.
UPDATE LayoutParts lp
SET Part_Type = m.canonical
FROM (VALUES
    ('Kopfbereich',                      'Header'),
    ('Datenbereich',                     'Body'),
    ('Fußbereich',                       'Footer'),
    ('Obere Navigation',                 'Top Navigation'),
    ('Vorangestelltes Zwischenergebnis', 'Leading Sub-summary')
) AS m(localized, canonical)
WHERE lp.Part_Type = m.localized;

-- Relationship-Prädikatfelder (left_field/right_field): die Join-Feld-UUID im
-- RelationshipCatalog ist ebenfalls kontext-synthetisch (das Feld wird über die Seiten-TO
-- referenziert). Über den mitgelieferten Feld-TO-Kontext (Left/Right_Field_TO_UUID) +
-- Feld-id auf die kanonische Feld-UUID korrigieren — behebt sowohl den left_field-/
-- right_field-Graph-Link als auch die Feld-Navigation in der Beziehungs-Detailansicht.
-- Feld-id ist entity-frei. Zwei Fälle werden angefasst:
--   (a) synthetische Nicht-NULL-UUID (Feld liegt in DIESER Datei, aber die Referenz-UUID
--       ist kontext-synthetisch), und
--   (b) NULL-UUID (F-1b): externe TO-Seite → die Feld-Entität gehört einer anderen Datei,
--       FieldReference@UUID war "" → in P1 zu NULL normalisiert. Auflösung über den
--       externen TO (DS_Name → Zieldatei) + Feld-id. Bleibt NULL, wenn die Zieldatei nicht
--       im Korpus ist (→ kein Link, konsistent mit der übrigen Cross-File-Behandlung).
-- Bereits kanonische UUIDs (in FieldsForTables) bleiben unangetastet.
UPDATE RelationshipCatalog rc
SET Left_Field_UUID = r.field_uuid
FROM (
    SELECT toc.TO_UUID, toc.File_Name, f.Field_ID, f.Field_UUID AS field_uuid
    FROM TableOccurrenceCatalog toc
    JOIN FieldsForTables f
      ON f.Table_Name = toc.BT_Name
     AND f.File_Name = regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
) r
WHERE (rc.Left_Field_UUID IS NULL
       OR rc.Left_Field_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL))
  AND rc.Left_Field_TO_UUID = r.TO_UUID AND rc.File_Name = r.File_Name AND rc.Left_Field_ID = r.Field_ID;

UPDATE RelationshipCatalog rc
SET Right_Field_UUID = r.field_uuid
FROM (
    SELECT toc.TO_UUID, toc.File_Name, f.Field_ID, f.Field_UUID AS field_uuid
    FROM TableOccurrenceCatalog toc
    JOIN FieldsForTables f
      ON f.Table_Name = toc.BT_Name
     AND f.File_Name = regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
) r
WHERE (rc.Right_Field_UUID IS NULL
       OR rc.Right_Field_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL))
  AND rc.Right_Field_TO_UUID = r.TO_UUID AND rc.File_Name = r.File_Name AND rc.Right_Field_ID = r.Field_ID;

-- Lookup-Quellfeld (lookup_source): die Lookup_Field_UUID zeigt über die Lookup-TO auf das
-- Quellfeld und ist ebenfalls kontext-synthetisch. Über Lookup_TO_UUID → Basistabelle +
-- Heimatdatei + Lookup_Field_Name auf die kanonische Feld-UUID korrigieren. (FieldsForTables
-- führt keine Lookup-Feld-id → Auflösung per Name; Lookup-Feldnamen sind hier entity-frei.)
UPDATE FieldsForTables tf
SET Lookup_Field_UUID = r.field_uuid
FROM (
    SELECT toc.TO_UUID, toc.File_Name, f.Field_Name, f.Field_UUID AS field_uuid
    FROM TableOccurrenceCatalog toc
    JOIN FieldsForTables f
      ON f.Table_Name = toc.BT_Name
     AND f.File_Name = regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
) r
WHERE tf.Lookup_Field_UUID IS NOT NULL AND tf.Lookup_Field_UUID <> ''
  AND tf.Lookup_Field_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL)
  AND tf.Lookup_TO_UUID = r.TO_UUID AND tf.File_Name = r.File_Name AND tf.Lookup_Field_Name = r.Field_Name;

-- Werteliste-Feld-UUIDs (Primär + Zweitfeld): die FieldReference-UUID der Werteliste ist
-- ebenfalls kontext-synthetisch (Feld über die Werteliste-TO referenziert). Über
-- (TO_UUID, Feld-ID) auf die kanonische Feld-UUID korrigieren → die source_field-Links
-- (Block 12/12b) treffen. Feld-ID entity-frei.
UPDATE OptionsForValueLists ovl
SET Field_UUID = r.field_uuid
FROM (
    SELECT toc.TO_UUID, toc.File_Name, f.Field_ID, f.Field_UUID AS field_uuid
    FROM TableOccurrenceCatalog toc
    JOIN FieldsForTables f
      ON f.Table_Name = toc.BT_Name
     AND f.File_Name = regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
) r
WHERE ovl.Field_UUID IS NOT NULL
  AND ovl.Field_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL)
  AND ovl.TO_UUID = r.TO_UUID AND ovl.File_Name = r.File_Name AND ovl.Field_ID = r.Field_ID;

UPDATE OptionsForValueLists ovl
SET Secondary_Field_UUID = r.field_uuid
FROM (
    SELECT toc.TO_UUID, toc.File_Name, f.Field_ID, f.Field_UUID AS field_uuid
    FROM TableOccurrenceCatalog toc
    JOIN FieldsForTables f
      ON f.Table_Name = toc.BT_Name
     AND f.File_Name = regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
) r
WHERE ovl.Secondary_Field_UUID IS NOT NULL
  AND ovl.Secondary_Field_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL)
  AND ovl.Secondary_TO_UUID = r.TO_UUID AND ovl.File_Name = r.File_Name AND ovl.Secondary_Field_ID = r.Field_ID;

-- Step_UUID-Index für die REST-API (pro ScriptStep-Detailaufruf werden die step-eigenen
-- Referenzen direkt aus XMLStepReferences gelesen). Hier statt in P2, weil der P2-Merge
-- (CREATE TABLE AS … LIMIT 0) keine Indizes der Slice-DBs überträgt.
CREATE INDEX IF NOT EXISTS idx_xmlstepref_step ON XMLStepReferences(Step_UUID);

-- ############################################################
-- Phase B: ObjectCatalog
-- ############################################################

-- ========================================
-- ObjectCatalog - Universelle Objektsuche
-- ========================================
-- Aggregiert ALLE Objekte aus allen 25 Tabellen
-- Ermöglicht schnelle Suche über alle Objekttypen hinweg

CREATE OR REPLACE TABLE ObjectCatalog AS

-- 1. BaseTableCatalog (Base Tables)
SELECT
    BT_UUID as Object_UUID,
    'BaseTable' as Object_Type,
    BT_Name as Object_Name,
    File_Name,
    'BaseTableCatalog' as Source_Table,
    BT_ID as Object_ID
FROM BaseTableCatalog

UNION ALL

-- 2. TableOccurrenceCatalog (Table Occurrences)
SELECT
    TO_UUID as Object_UUID,
    'TableOccurrence' as Object_Type,
    TO_Name as Object_Name,
    File_Name,
    'TableOccurrenceCatalog' as Source_Table,
    TO_ID as Object_ID
FROM TableOccurrenceCatalog

UNION ALL

-- 3. RelationshipCatalog (Relationships)
-- HINWEIS: Relationships haben keine UUID, verwenden Rel_ID + File_Name als Composite Key.
-- DISTINCT, weil RelationshipCatalog seit Schema 1.2.0 eine Zeile pro Join-Prädikat führt
-- (Mehrfeld-Joins) — als Objekt zählt die Relation aber genau einmal.
SELECT DISTINCT
    'rel_' || Rel_ID::VARCHAR || '_' || File_Name as Object_UUID,  -- Namespace-Präfix
    'Relationship' as Object_Type,
    Left_TO_Name || ' → ' || Right_TO_Name as Object_Name,
    File_Name,
    'RelationshipCatalog' as Source_Table,
    Rel_ID as Object_ID
FROM RelationshipCatalog

UNION ALL

-- 4. FieldsForTables (Fields)
SELECT
    Field_UUID as Object_UUID,
    'Field' as Object_Type,
    Table_Name || '::' || Field_Name as Object_Name,
    File_Name,
    'FieldsForTables' as Source_Table,
    Field_ID as Object_ID
FROM FieldsForTables

UNION ALL

-- 5. ValueListCatalog (Value Lists)
SELECT
    VL_UUID as Object_UUID,
    'ValueList' as Object_Type,
    VL_Name as Object_Name,
    File_Name,
    'ValueListCatalog' as Source_Table,
    VL_ID as Object_ID
FROM ValueListCatalog

UNION ALL

-- 6. CustomFunctionsCatalog (Custom Functions - ohne Folders und Separators)
-- Folder/Marker-Records werden als 'Folder' separat aufgenommen (siehe Block 24).
-- Ohne diesen Filter zählten Ordnernamen und Trenner ('--') als Custom Function —
-- und sind, weil sie wie eine parameterlose CF Parameters = NULL tragen, auch für
-- Signatur-Prüfungen von einer echten CF ununterscheidbar.
SELECT
    CF_UUID as Object_UUID,
    'CustomFunction' as Object_Type,
    CF_Name as Object_Name,
    File_Name,
    'CustomFunctionsCatalog' as Source_Table,
    CF_ID as Object_ID
FROM CustomFunctionsCatalog
WHERE (Folder_Type IS NULL OR Folder_Type = 'False')
  AND NOT COALESCE(Is_Separator, FALSE)

UNION ALL

-- 7. ScriptCatalog (Scripts - ohne Folders und Separators)
SELECT
    Script_UUID as Object_UUID,
    'Script' as Object_Type,
    Script_Name as Object_Name,
    File_Name,
    'ScriptCatalog' as Source_Table,
    Script_ID as Object_ID
FROM ScriptCatalog
WHERE (Folder_Type IS NULL OR Folder_Type = 'False')
  AND NOT Is_Separator

UNION ALL

-- 8. StepsForScripts (Script Steps)
SELECT
    Step_UUID as Object_UUID,
    'ScriptStep' as Object_Type,
    Script_Name || ' [' || Step_Index || '] ' || Step_Name as Object_Name,
    File_Name,
    'StepsForScripts' as Source_Table,
    Step_ID as Object_ID
FROM StepsForScripts

UNION ALL

-- 9. Layouts (Layouts - ohne Folders und Separators)
-- Folder/Marker-Records werden als 'Folder' separat aufgenommen (siehe Block 24)
SELECT
    L_UUID as Object_UUID,
    'Layout' as Object_Type,
    L_Name as Object_Name,
    File_Name,
    'Layouts' as Source_Table,
    L_ID as Object_ID
FROM Layouts
WHERE (Folder_Type IS NULL OR Folder_Type = 'False')
  AND NOT COALESCE(Is_Separator, FALSE)

UNION ALL

-- 10. LayoutParts (Layout Parts)
-- HINWEIS: LayoutParts haben keine UUID — Composite-UUID mit 'part_'-Präfix
-- (kollisionsfrei zu anderen Composite-Schemata) aus Layout_ID + Part_Kind +
-- Part_Seq + File_Name. Part_Seq (Schema 1.5.1) hält mehrere Parts gleicher
-- Art (z.B. 3× Leading Sub-summary) auseinander. Formel identisch in der
-- parent_layout- und breaks_on_field-Kante unten.
SELECT
    'part_' || Layout_ID::VARCHAR || '_' || Part_Kind::VARCHAR || '_' || Part_Seq::VARCHAR || '_' || File_Name as Object_UUID,
    'LayoutPart' as Object_Type,
    -- Sub-Summary-Parts tragen ihr Umbruchfeld im Namen (mehrere Parts gleicher
    -- Art wären sonst gleichnamig)
    Layout_Name || ' [' || Part_Type
        || CASE WHEN Break_Field_Name IS NOT NULL THEN ' · ' || Break_Field_Name ELSE '' END
        || ']' as Object_Name,
    File_Name,
    'LayoutParts' as Source_Table,
    Layout_ID as Object_ID
FROM LayoutParts

UNION ALL

-- 11. LayoutObjects (Layout Objects)
-- Display-Name-Default für unnamed LayoutObjects: 'Object_Type @ (Top,Left)',
-- z.B. 'Edit Box @ (123,45)'. Bounds machen das Element auf dem Layout
-- lokalisierbar; der vorherige Default 'Type #ID' war abstrakt.
SELECT
    Object_UUID as Object_UUID,
    'LayoutObject' as Object_Type,
    COALESCE(
        NULLIF(Object_Name, ''),
        Object_Type || ' @ (' || COALESCE(Bounds_Top, 0) || ',' || COALESCE(Bounds_Left, 0) || ')'
    ) as Object_Name,
    File_Name,
    'LayoutObjects' as Source_Table,
    Object_ID as Object_ID
FROM LayoutObjects

UNION ALL

-- 12. AccountsCatalog (Accounts)
SELECT
    Account_UUID as Object_UUID,
    'Account' as Object_Type,
    COALESCE(Account_Name, Description) as Object_Name,
    File_Name,
    'AccountsCatalog' as Source_Table,
    Account_ID as Object_ID
FROM AccountsCatalog

UNION ALL

-- 13. PrivilegeSetsCatalog (Privilege Sets)
SELECT
    PrivilegeSet_UUID as Object_UUID,
    'PrivilegeSet' as Object_Type,
    PrivilegeSet_Name as Object_Name,
    File_Name,
    'PrivilegeSetsCatalog' as Source_Table,
    PrivilegeSet_ID as Object_ID
FROM PrivilegeSetsCatalog

UNION ALL

-- 14./15. DDR_ScriptSteps und DDR_Calculations:
-- Bewusst NICHT als ObjectCatalog-Einträge geführt. Step_UUID und Calc_UUID
-- sind Rückreferenzen auf den Host (ScriptStep, LayoutObject, Field, CustomFunction),
-- keine eigenständigen Identitäten. Doppelte Catalog-Einträge mit identischer UUID
-- führten zu falsch-positiven Referenz-Anzeigen. Die DDR-Tabellen werden weiterhin
-- direkt über Step_UUID / Calc_Hash in den Detail-Templates referenziert.

-- 16. PasteIndexList (Paste Index Objects)
-- WICHTIG: eigener 'paste_'-UUID-Präfix. Ohne ihn kollidierte das synthetische
-- <Object_ID>_<File_Name>-Schema mit dem IDENTISCHEN Schema der Relationships
-- (Rel_ID overlappt mit Paste-Object_ID je Datei) → doppelte ObjectCatalog-Zeilen
-- pro UUID, die jeden ObjectLinks-JOIN über Source_/Target_UUID auffächern
-- (z.B. eine Relationship-Referenz erscheint zusätzlich als PasteIndexObject).
-- Paste-Objekte haben selbst KEINE ObjectLinks und keine Detail-/Frontend-Nutzung.
SELECT
    'paste_' || Object_ID::VARCHAR || '_' || File_Name as Object_UUID,
    'PasteIndexObject' as Object_Type,
    'Paste Object #' || Object_ID as Object_Name,
    File_Name,
    'PasteIndexList' as Source_Table,
    Object_ID as Object_ID
FROM PasteIndexList

UNION ALL

-- 17. BaseDirectoryCatalog (Base Directories)
SELECT
    BD_UUID as Object_UUID,
    'BaseDirectory' as Object_Type,
    BD_Name as Object_Name,
    File_Name,
    'BaseDirectoryCatalog' as Source_Table,
    BD_ID as Object_ID
FROM BaseDirectoryCatalog

UNION ALL

-- 18. ScriptTriggers (Script Triggers)
SELECT
    'trig_' || Trigger_ID::VARCHAR || '_' || Owner_UUID || '_' || File_Name as Object_UUID,  -- Namespace-Präfix
    'ScriptTrigger' as Object_Type,
    -- COALESCE-Guard: echte Orphan-Trigger (Trigger-Slot ohne zugewiesenes
    -- Ziel-Skript) haben Script_Name=NULL. Ohne Guard wird der String-Konkat
    -- komplett NULL und bricht später den NOT-NULL-Constraint von ObjectHomes
    -- (build_resolutions.sql) ab → Rollback der gesamten Resolution-Erstellung.
    Trigger_Action || ' → ' || COALESCE(Script_Name, '<no script assigned>') as Object_Name,
    File_Name,
    'ScriptTriggers' as Source_Table,
    Trigger_ID as Object_ID
FROM ScriptTriggers

UNION ALL

-- 19. ExtendedPrivilegesCatalog (Extended Privileges)
SELECT
    EP_UUID as Object_UUID,
    'ExtendedPrivilege' as Object_Type,
    EP_Name as Object_Name,
    File_Name,
    'ExtendedPrivilegesCatalog' as Source_Table,
    EP_ID as Object_ID
FROM ExtendedPrivilegesCatalog

UNION ALL

-- 20. CustomMenuCatalog (Custom Menus)
SELECT
    Menu_UUID as Object_UUID,
    'CustomMenu' as Object_Type,
    Menu_Name as Object_Name,
    File_Name,
    'CustomMenuCatalog' as Source_Table,
    Menu_ID as Object_ID
FROM CustomMenuCatalog

UNION ALL

-- 20b. CustomMenuSetCatalog (Menü-Sets)
SELECT
    MenuSet_UUID as Object_UUID,
    'CustomMenuSet' as Object_Type,
    MenuSet_Name as Object_Name,
    File_Name,
    'CustomMenuSetCatalog' as Source_Table,
    MenuSet_ID as Object_ID
FROM CustomMenuSetCatalog

UNION ALL

-- 20c. CustomMenuItemCatalog (Menü-Items, AP-3/D-2)
-- Eigene Objektidentität pro Item → die Install-/Name-Calc-Anker lösen in
-- v_calc_anchors auf und Item-Formel-Bezüge bekommen ein echtes Quell-Objekt.
SELECT
    Item_UUID as Object_UUID,
    'CustomMenuItem' as Object_Type,
    Menu_Name || ' › ' || COALESCE(NULLIF(Command_Name, ''),
        CASE WHEN Is_SeparatorItem THEN '(Separator)' ELSE '(berechnet)' END) as Object_Name,
    File_Name,
    'CustomMenuItemCatalog' as Source_Table,
    Menu_ID as Object_ID
FROM CustomMenuItemCatalog

UNION ALL

-- 21. ThemeCatalog (Themes)
-- Object_Name = lokalisierter Anzeigename (Theme_Display, z.B. „Apex Blau"), wie in
-- der FileMaker-UI; Fallback auf den internen name (com.filemaker.theme.*), falls
-- kein Display-Attribut vorhanden. Wirkt katalogweit (Detail, Referenzen, Graph).
SELECT
    Theme_UUID as Object_UUID,
    'Theme' as Object_Type,
    COALESCE(NULLIF(Theme_Display, ''), Theme_Name) as Object_Name,
    File_Name,
    'ThemeCatalog' as Source_Table,
    Theme_ID as Object_ID
FROM ThemeCatalog

UNION ALL

-- 22. ExternalDataSourceCatalog (External Data Sources)
SELECT
    DS_UUID as Object_UUID,
    'ExternalDataSource' as Object_Type,
    DS_Name as Object_Name,
    File_Name,
    'ExternalDataSourceCatalog' as Source_Table,
    DS_ID as Object_ID
FROM ExternalDataSourceCatalog

UNION ALL

-- 23. VariablesCatalog (alle Variablen)
-- UUID = md5(Scope || Scope_Anchor || Name) — eine Identität pro Scope-Instanz
SELECT
    md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) as Object_UUID,
    'Variable' as Object_Type,
    Display_Name as Object_Name,
    File_Name,
    'VariablesCatalog' as Source_Table,
    NULL as Object_ID
FROM VariablesCatalog
WHERE Variable_Scope IN ('global', 'local', 'superglobal')

UNION ALL

-- 24. FolderHierarchy (Folder für Scripts/Layouts/CustomFunctions)
-- Object_Type='Folder' für ALLE Folder-Arten; Source_Table dient als Subtype-Diskriminator.
-- Separators werden NICHT in ObjectCatalog aufgenommen (reine UI-Marker, siehe FolderHierarchy-View).
SELECT
    Source_UUID as Object_UUID,
    'Folder' as Object_Type,
    Item_Name as Object_Name,
    File_Name,
    Source_Table,
    NULL as Object_ID
FROM FolderHierarchy
WHERE subtype = 'Folder'

UNION ALL

-- 25. BuiltinFunction (synthetisch)
-- Ein Eintrag pro distinct FunctionRef-Token
-- aus XMLCalcReferences (Ref_Type='function'). Built-ins sind lösungs-unabhängig
-- → File_Name = NULL. Bei Get(<SubParameter>) erzeugt jeder SubParameter einen
-- eigenen Eintrag (Object_Name = 'Get(<SubParameter>)'); zusätzlich existiert der
-- nackte 'Get'-Eintrag (Ref_SubName IS NULL).
-- Lokalisierte Token-Schreibweisen erzeugen mehrere Einträge mit unterschiedlicher
-- Object_UUID (Reference-DB-Anreicherung mappt sie zur Query-Zeit auf canonical_name).
SELECT DISTINCT
    md5('BuiltinFunction::' ||
        CASE WHEN Ref_Name = 'Get' AND Ref_SubName IS NOT NULL
             THEN Ref_Name || '::' || Ref_SubName
             ELSE Ref_Name END
    ) as Object_UUID,
    'BuiltinFunction' as Object_Type,
    CASE WHEN Ref_Name = 'Get' AND Ref_SubName IS NOT NULL
         THEN 'Get(' || Ref_SubName || ')'
         ELSE Ref_Name END as Object_Name,
    NULL as File_Name,
    'DDR_Calculations' as Source_Table,
    NULL as Object_ID
FROM XMLCalcReferences
WHERE Ref_Type = 'function'
  AND Ref_Name IS NOT NULL
  AND Ref_Name != ''

UNION ALL

-- 26. PluginFunction (synthetisch)
-- Ein Eintrag pro (Plugin_Function_Name, SubName).
-- Container-Plugins (heute: MBS) erzeugen pro SubName einen Eintrag; Non-Container-Plugins
-- einen Eintrag pro registriertem Calc-Token.
-- Object_Name folgt der Konvention 'Plugin::SubName' für Container-Plugins,
-- 'Plugin' für Non-Container-Plugins.
-- Dynamische MBS-Aufrufe (SubName IS NULL) werden ausgefiltert.
SELECT DISTINCT
    md5('PluginFunction::' || pfu.Plugin_Function_Name || '::' ||
        COALESCE(msm.SubName, '')) as Object_UUID,
    'PluginFunction' as Object_Type,
    CASE WHEN msm.SubName IS NOT NULL
         THEN pfu.Plugin_Function_Name || '::' || msm.SubName
         ELSE pfu.Plugin_Function_Name END as Object_Name,
    NULL as File_Name,
    'PluginFunctionUsages' as Source_Table,
    NULL as Object_ID
FROM PluginFunctionUsages pfu
LEFT JOIN MBS_SubnameMap msm
  ON msm.Calc_UUID = pfu.Calc_UUID
 AND msm.File_Name = pfu.File_Name
 AND msm.Plugin_Chunk_Index = pfu.Plugin_Chunk_Index
WHERE pfu.Plugin_Function_Name IS NOT NULL
  AND pfu.Plugin_Function_Name != ''
  AND (msm.SubName IS NOT NULL OR pfu.Plugin_Function_Name != 'MBS')

UNION ALL

-- 27. ScriptStepType (synthetisch, Token-Aggregat)
-- Ein Eintrag pro distinct Step_Name aus BEIDEN Step-Trägern:
--   StepsForScripts    — Steps echter Scripts
--   LayoutObjectSteps  — button-eingebettete Steps (Button / Grouped Button)
-- Beide Seiten sind nötig: die Step-Tokens der Button-Detailansicht verlinken auf
-- md5('ScriptStepType::'||Step_Name) aus LayoutObjectSteps. Fehlt diese Quelle hier,
-- läuft jeder Step-Typ, den NUR ein Button verwendet, ins Leere ("not found") —
-- in schlanken Lösungen ist das der Normalfall, nicht die Ausnahme.
-- ScriptStepTypes sind lösungs-unabhängig → File_Name = NULL.
-- Die Verwendungs-Anzahl wird im Detail-Template direkt aus den Trägertabellen
-- aggregiert (keine zusätzlichen ObjectLinks).
--
-- UNION (nicht UNION ALL) über die beiden Quellen: ein Step-Typ, den Script UND
-- Button verwenden, ergäbe sonst zwei Zeilen mit identischer Object_UUID → Dup-PK.
SELECT
    md5('ScriptStepType::' || Step_Name) as Object_UUID,
    'ScriptStepType' as Object_Type,
    Step_Name as Object_Name,
    NULL as File_Name,
    'StepsForScripts' as Source_Table,
    NULL as Object_ID
FROM (
    SELECT Step_Name FROM StepsForScripts
    UNION
    SELECT Step_Name FROM LayoutObjectSteps
)
WHERE Step_Name IS NOT NULL
  AND Step_Name != ''

UNION ALL

-- 28. FilesCatalog (File-Knoten als Owner-Anker für File-Level-Trigger)
-- File-Level-Trigger
-- (OnFirstWindowOpen etc.) tragen als Owner_UUID die FMSaveAsXML/@UUID.
-- Damit der trigger_owner-Link (Block 18b) einen Katalog-Eintrag trifft,
-- wird hier je Datei ein File-Knoten registriert. Object_ID = NULL, da
-- Dateien keine FileMaker-interne ID haben.
SELECT
    File_UUID as Object_UUID,
    'File' as Object_Type,
    File_Name as Object_Name,
    File_Name,
    'FilesCatalog' as Source_Table,
    NULL as Object_ID
FROM FilesCatalog;

-- ========================================
-- PluginComponent (synthetisch, Category-Aggregat)
-- ========================================
-- Komponenten-Mapping aus
--   1) reference/mbs_component_exceptions.csv (autoritativ, ~1.021 Mappings)
--   2) Default-Heuristik split_part(SubName, '.', 1)
-- Object_Name folgt der Konvention 'MBS::<Component>' (z.B. 'MBS::XL').
-- Wird als separater INSERT nach dem CREATE eingefügt, weil die Auflösung
-- auf die bereits existierenden PluginFunction-Einträge des ObjectCatalog
-- zugreift. PluginFunction-Namen sind qualifiziert: 'MBS:<Sub>::<Sub>'
-- (AP-5a); der SubName ist der Teil nach '::' — split_part deckt auch das
-- alte 'MBS::<Sub>'-Format ab.
-- File_Name = NULL (lösungs-unabhängig).
--
-- Voraussetzung: convert_fm_xml.sh führt den DuckDB-Lauf im Repo-Root aus,
-- sodass der relative CSV-Pfad auflösbar ist (cd in convert_fm_xml.sh).
-- Falls die CSV nicht existiert, greift die Default-Heuristik (read_csv-Fehler
-- müsste durch existierende CSV vermieden werden).
INSERT INTO ObjectCatalog (Object_UUID, Object_Type, Object_Name, File_Name, Source_Table, Object_ID)
WITH component_map AS (
    SELECT
        Funktionsname AS function_name,
        Component     AS component_name
    FROM read_csv('reference/mbs_component_exceptions.csv', header=true)
),
resolved AS (
    SELECT DISTINCT
        split_part(pf.Object_Name, '::', 2) AS sub_name,
        COALESCE(
            cm.component_name,
            split_part(split_part(pf.Object_Name, '::', 2), '.', 1)
        ) AS component_name
    FROM ObjectCatalog pf
    LEFT JOIN component_map cm
      ON cm.function_name = split_part(pf.Object_Name, '::', 2)
    WHERE pf.Object_Type = 'PluginFunction'
      AND pf.Object_Name LIKE 'MBS:%'
)
SELECT DISTINCT
    md5('PluginComponent::MBS::' || component_name) as Object_UUID,
    'PluginComponent' as Object_Type,
    'MBS::' || component_name as Object_Name,
    NULL as File_Name,
    'reference/mbs_component_exceptions.csv' as Source_Table,
    NULL as Object_ID
FROM resolved
WHERE component_name IS NOT NULL
  AND component_name != '';

-- ========================================
-- CalculationsCatalog — Berechnungs-Instanzen als Objekte (Schema 1.22.0)
-- ========================================
-- Eine Zeile pro Berechnungs-INSTANZ (Verwendungsort), NIE pro Formel-Inhalt:
-- Identität = Owner × Calc_Role × Calc_Index (strukturell aus SaXML), der
-- Formel-Hash ist eine EIGENSCHAFT (SaXML dedupliziert ChunkLists inhaltsbasiert
-- — 1 Hash ↔ bis zu 63k Instanzen; ein Hash-Objekt wäre kein Verwendungsort).
-- Nachfolger/Superset von v_calc_anchors (die in der Analysis-Views-Phase zur
-- materialisierten Fassade über dieser Tabelle wird).
--
-- Zwei Quellklassen, per Anti-Join dedupliziert:
--   (A) DDR-Anker aus DDR_Calculations (_<OwnerUUID>_<Suffix>) — tragen Hash,
--       Chunk-Aggregate und Display_Text; Owner-Auflösung über ObjectCatalog.
--       Suffix-Vokabular (korpus-verifiziert): Feld '0'=Haupt-Calc/'1'=AutoEnter;
--       ScriptStep = Calc-POSITION (137.149/137.149 matchen StepCalculations.
--       Calc_Position exakt) bzw. 'XML'/'XSL' (XSLT-Slots); LayoutObject
--       Hide/Tooltip/Condition_N/action/…; leeres Suffix = CF-Body.
--   (B) strukturelle Slots OHNE eigenen DDR-Anker — Instanzen existieren auch
--       ohne DDR-Info: FieldsForTables-Slots (Validierung/Fehlermeldung ankern
--       NIE, Haupt/AutoEnter nur mit DDR), StepCalculations,
--       CalcsForCustomFunctions, LayoutObjects-Textslots,
--       ScriptTriggers-Parameter (per Trigger, alle drei Owner-Ebenen),
--       PrivilegeSetRecordAccess. Hash-lose Zeilen: Formula_Hash NULL.
--
-- Calc_Index: 1-basiert je (File, Owner, Rolle) in Dokument-/Positions-Ordnung
-- (deterministisch über stabile Eingaben: Calc-Position, Suffix-Nummern,
-- DDR-Anker-UUID — NICHT FileMakers @position allein, die in manchen
-- Parameter-Containern neu startet).
-- Edge_Subrole = der Link_Subrole-Wert, den die owner-projizierten Kanten
-- dieser Instanz tragen (Join-Schlüssel der View v_calculation_links).
--
-- PERFORMANCE (Anti-Muster-Warnung): In den LEFT-JOIN-ON-Klauseln dieses CTAS
-- stehen bewusst KEINE rein linksseitigen Prädikate (a.Owner_Type = '…',
-- i.Owner_Name IS NULL o. ä.) — solche Bedingungen sind Teil der Join-Semantik,
-- nicht als Filter pushbar, und kippen DuckDB in BLOCKWISE_NL_JOIN
-- (Kreuzprodukt: 18 s statt 0,6 s auf einem 187k-Zeilen-Korpus). Der
-- Typ-Dispatch läuft stattdessen über die per Owner_Type gegateten
-- CASE-Konsumenten; die ON-Klauseln bleiben reine Equi-Joins (Step_Pos dafür
-- in a_owner vorberechnet). Beim Erweitern: neue Dispatch-Joins nach demselben
-- Muster bauen.
CREATE OR REPLACE TABLE CalculationsCatalog AS
WITH chunk_pieces AS (
    -- Ein Scan über DDR_Calculations: pro Chunk das lesbare Fragment
    -- (identisch zur bisherigen v_calc_anchors-Mechanik).
    SELECT
        Calc_UUID,
        File_Name,
        Calc_Hash,
        Chunk_Index,
        Chunk_Type,
        CASE Chunk_Type
            WHEN 'FieldRef' THEN
                COALESCE(xml_extract_text(Chunk_Content, '/Chunk/FieldReference/TableOccurrenceReference/@name')[1] || '::', '')
                || COALESCE(xml_extract_text(Chunk_Content, '/Chunk/FieldReference/@name')[1], '?')
            ELSE COALESCE(xml_extract_text(Chunk_Content, '/Chunk')[1], '')
        END AS Piece
    FROM DDR_Calculations
),
ddr_inst AS (
    SELECT
        Calc_UUID,
        File_Name,
        MIN(Calc_Hash)                                                      AS Calc_Hash,
        upper(regexp_extract(Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))          AS Anchor_UUID,
        regexp_replace(Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', '')               AS Calc_Kind_Raw,
        COUNT(*)                                                            AS Chunk_Count,
        COUNT(*) FILTER (WHERE Chunk_Type NOT IN ('NoRef', 'Comment'))      AS Ref_Count,
        string_agg(Piece, '' ORDER BY Chunk_Index)                          AS Display_Text
    FROM chunk_pieces
    GROUP BY Calc_UUID, File_Name
),
-- Hash-Repräsentant je (File, Hash) — Anreicherung der strukturellen B-Zeilen,
-- deren Slot einen Hash trägt, aber keinen eigenen Anker (Feld-Validierung).
hash_rep AS (
    SELECT File_Name, Calc_Hash, Chunk_Count, Ref_Count, Display_Text
    FROM ddr_inst
    QUALIFY ROW_NUMBER() OVER (PARTITION BY File_Name, Calc_Hash ORDER BY Calc_UUID) = 1
),
-- StepCalculations mit deterministischem Vertreter je (Step, Position) —
-- 21 exakte Duplikat-Gruppen im Korpus (Quell-Doppel-Serialisierung).
step_slots AS (
    SELECT Step_UUID, File_Name, Calc_Position, Slot, Slot_Seq, Calc_Text,
           Script_Name, Step_Index, Step_Name,
           ROW_NUMBER() OVER (PARTITION BY Step_UUID, File_Name, Calc_Position
                              ORDER BY Slot, Slot_Seq, Calc_Text) AS pos_rn
    FROM StepCalculations
),
-- PrivilegeSetRecordAccess-Vertreter je (Set, Hash) — derselbe Hash kann
-- mehrere (Tabelle, Operation)-Slots bedienen; deterministischer Erst-Treffer
-- (die exakte Slot-Zuordnung des DDR-Suffix ist nicht dekodierbar,
-- dokumentierte Modellgrenze).
pra_rep AS (
    SELECT PrivilegeSet_UUID, File_Name, DDR_Hash, Operation, BaseTable_Name,
           Context_TO_UUID, Context_TO_Name, Calculation_Text,
           ROW_NUMBER() OVER (PARTITION BY PrivilegeSet_UUID, File_Name, DDR_Hash
                              ORDER BY Operation, BaseTable_Name) AS rn
    FROM PrivilegeSetRecordAccess
),
lo_rep AS (
    SELECT Object_UUID, File_Name, Hide_Calculation_Text, Tooltip_Calculation_Text,
           Label_Calculation_Text, ScriptTrigger_Parameter_Text,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
),
-- (A) DDR-Anker mit Owner-Auflösung. Nicht auflösbare Anker bleiben erhalten
-- (Owner_Type='unresolved', Owner_UUID=Anchor_UUID — P6-überwacht, Soll 0).
a_owner AS (
    SELECT
        di.File_Name,
        di.Calc_UUID                                AS DDR_Calc_UUID,
        di.Calc_Hash,
        di.Calc_Kind_Raw,
        di.Chunk_Count,
        di.Ref_Count,
        di.Display_Text,
        (di.Ref_Count = 0)                          AS Is_Static,
        COALESCE(oc.Object_Type, 'unresolved')      AS Owner_Type,
        COALESCE(oc.Object_UUID, di.Anchor_UUID)    AS Owner_UUID,
        oc.Object_Name                              AS Owner_Name,
        -- vorberechnete Step-Position: Equi-Schlüssel für den step_slots-Join
        -- und den b_step-Anti-Join (hält deren Bedingungen ausdrucks-frei)
        TRY_CAST(regexp_extract(di.Calc_Kind_Raw, '^([0-9]+)', 1) AS BIGINT) AS Step_Pos,
        -- vorberechnete Trigger-ID: Equi-Schlüssel für den ScriptTriggers-Join
        -- (Formula_Text der Trigger-Parameter, Schema 1.26.0). Extraktion NUR
        -- über das Suffix-Muster — NIE über Calc_Index (positions-, nicht
        -- slot-basiert; bekannte Falle aus dem CF-FK).
        TRY_CAST(regexp_extract(di.Calc_Kind_Raw, '^ScriptTrigger_([0-9]+)$', 1) AS BIGINT) AS Trigger_Pos
    FROM ddr_inst di
    LEFT JOIN ObjectCatalog oc
           ON upper(oc.Object_UUID) = di.Anchor_UUID
          AND oc.File_Name          = di.File_Name
    WHERE di.Anchor_UUID <> ''
),
a_rows AS (
    SELECT
        a.File_Name, a.Owner_UUID, a.Owner_Type, a.Owner_Name,
        CAST(NULL AS VARCHAR)          AS Role_Override,
        a.Calc_Kind_Raw,
        a.DDR_Calc_UUID,
        a.Calc_Hash                    AS Formula_Hash,
        -- strukturelle Klartext-Anreicherung je Owner-Typ (NULL, wo die Quelle
        -- keinen Klartext führt — Display_Text bleibt die Chunk-Rekonstruktion)
        CASE
            WHEN a.Owner_Type = 'Field' AND a.Calc_Kind_Raw = '0' THEN ft.Calculation_Text
            WHEN a.Owner_Type = 'Field' AND a.Calc_Kind_Raw = '1' THEN ft.AE_Calc_Text
            WHEN a.Owner_Type = 'ScriptStep'                      THEN ss.Calc_Text
            WHEN a.Owner_Type = 'CustomFunction'                  THEN cfc.Calculation_Code
            WHEN a.Owner_Type = 'PrivilegeSet'                    THEN pra.Calculation_Text
            WHEN a.Owner_Type = 'LayoutObject' AND a.Calc_Kind_Raw = 'Hide'    THEN lo.Hide_Calculation_Text
            WHEN a.Owner_Type = 'LayoutObject' AND a.Calc_Kind_Raw = 'Tooltip' THEN lo.Tooltip_Calculation_Text
            WHEN a.Owner_Type = 'LayoutObject' AND a.Calc_Kind_Raw = 'Label'   THEN lo.Label_Calculation_Text
            -- Trigger-Parameter (alle 3 Owner-Ebenen): Klartext aus
            -- ScriptTriggers.Trigger_Parameter_Text (Schema 1.26.0)
            WHEN a.Calc_Kind_Raw LIKE 'ScriptTrigger\_%' ESCAPE '\'            THEN st.Trigger_Parameter_Text
        END                            AS Formula_Text,
        pra.Context_TO_UUID,
        pra.Context_TO_Name,
        a.Is_Static, a.Chunk_Count, a.Ref_Count, a.Display_Text,
        CASE
            WHEN a.Owner_Type = 'Field' AND a.Calc_Kind_Raw = '0' THEN 'Field/Calculation'
            WHEN a.Owner_Type = 'Field' AND a.Calc_Kind_Raw = '1' THEN 'Field/AutoEnter/Calculated'
            WHEN a.Owner_Type = 'ScriptStep' AND ss.Slot IS NOT NULL THEN 'Step/' || ss.Slot
            WHEN a.Owner_Type = 'ScriptStep'                      THEN 'Step/@position=' || a.Calc_Kind_Raw
            WHEN a.Owner_Type = 'CustomFunction'                  THEN 'CustomFunction/Calculation'
            WHEN a.Owner_Type = 'PrivilegeSet' AND pra.Operation IS NOT NULL
                 THEN 'RecordAccess/' || pra.Operation || ':' || COALESCE(pra.BaseTable_Name, '?')
            WHEN a.Owner_Type = 'PrivilegeSet'                    THEN 'RecordAccess'
            ELSE a.Owner_Type || '/' || NULLIF(a.Calc_Kind_Raw, '')
        END                            AS Source_Path
    FROM a_owner a
    -- Reine Equi-Joins ohne a.Owner_Type-Prädikate (Blockwise-NL-Falle, s. Blockkopf).
    -- Jede Quelltabelle enthält nur Owner EINES Typs und die Vertreter
    -- (pos_rn/rn = 1) sind je Schlüssel eindeutig → kein Fan-out; die
    -- CASE-Konsumenten oben bleiben per Owner_Type gegated.
    LEFT JOIN FieldsForTables ft
           ON ft.Field_UUID = a.Owner_UUID AND ft.File_Name = a.File_Name
    LEFT JOIN step_slots ss
           ON ss.pos_rn = 1
          AND ss.Step_UUID = a.Owner_UUID AND ss.File_Name = a.File_Name
          AND ss.Calc_Position = a.Step_Pos
    LEFT JOIN CalcsForCustomFunctions cfc
           ON cfc.CF_UUID = a.Owner_UUID AND cfc.File_Name = a.File_Name
    LEFT JOIN pra_rep pra
           ON pra.rn = 1
          AND pra.PrivilegeSet_UUID = a.Owner_UUID AND pra.File_Name = a.File_Name
          AND pra.DDR_Hash = a.Calc_Hash
    LEFT JOIN lo_rep lo
           ON lo.rn = 1
          AND lo.Object_UUID = a.Owner_UUID AND lo.File_Name = a.File_Name
    -- Trigger-Parameter-Klartext: PK (Trigger_ID, Owner_UUID, File_Name) →
    -- max. 1 Treffer; Trigger_Pos ist für Nicht-Trigger-Anker NULL (kein Match).
    LEFT JOIN ScriptTriggers st
           ON st.Owner_UUID = a.Owner_UUID AND st.File_Name = a.File_Name
          AND st.Trigger_ID = a.Trigger_Pos
),
-- (B1) Feld-Slots ohne eigenen DDR-Anker. Haupt-/AutoEnter-Slots ankern mit
-- DDR ('0'/'1') — Anti-Join je Slot; Validierung/Fehlermeldung ankern NIE.
b_field AS (
    SELECT * FROM (
        SELECT f.File_Name, f.Field_UUID AS Owner_UUID, 'Field' AS Owner_Type,
               f.Table_Name || '::' || f.Field_Name AS Owner_Name,
               'field_calculation' AS Role_Override, '0' AS Calc_Kind_Raw,
               f.DDR_Hash AS Formula_Hash, f.Calculation_Text AS Formula_Text,
               'Field/Calculation' AS Source_Path
        FROM FieldsForTables f
        WHERE (f.DDR_Hash IS NOT NULL OR NULLIF(f.Calculation_Text, '') IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM a_owner a
                           WHERE a.Owner_UUID = f.Field_UUID AND a.File_Name = f.File_Name
                             AND a.Owner_Type = 'Field' AND a.Calc_Kind_Raw = '0')
        UNION ALL
        SELECT f.File_Name, f.Field_UUID, 'Field',
               f.Table_Name || '::' || f.Field_Name,
               'auto_enter', '1',
               f.AE_Calc_Hash, f.AE_Calc_Text,
               'Field/AutoEnter/Calculated'
        FROM FieldsForTables f
        WHERE (f.AE_Calc_Hash IS NOT NULL OR NULLIF(f.AE_Calc_Text, '') IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM a_owner a
                           WHERE a.Owner_UUID = f.Field_UUID AND a.File_Name = f.File_Name
                             AND a.Owner_Type = 'Field' AND a.Calc_Kind_Raw = '1')
        UNION ALL
        SELECT f.File_Name, f.Field_UUID, 'Field',
               f.Table_Name || '::' || f.Field_Name,
               'validation', NULL,
               f.Validation_Calc_Hash, f.Validation_Calc_Text,
               'Field/Validation/Calculated'
        FROM FieldsForTables f
        WHERE (f.Validation_Calc_Hash IS NOT NULL OR NULLIF(f.Validation_Calc_Text, '') IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM a_owner a
                           WHERE a.Owner_UUID = f.Field_UUID AND a.File_Name = f.File_Name
                             AND a.Owner_Type = 'Field' AND a.Calc_Kind_Raw = '2')
        UNION ALL
        -- Fehlermeldungs-Berechnung: nur der Hash ist strukturell greifbar
        -- (Validation_Message ist die STATISCHE Meldung, nicht die Formel).
        SELECT f.File_Name, f.Field_UUID, 'Field',
               f.Table_Name || '::' || f.Field_Name,
               'validation_message', NULL,
               f.Validation_Message_Calc_Hash, NULL,
               'Field/Validation/MessageCalc'
        FROM FieldsForTables f
        WHERE f.Validation_Message_Calc_Hash IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM a_owner a
                           WHERE a.Owner_UUID = f.Field_UUID AND a.File_Name = f.File_Name
                             AND a.Owner_Type = 'Field' AND a.Calc_Kind_Raw = '4')
    )
),
-- (B2) Step-Slots ohne DDR-Anker (Dateien ohne DDR-Info bzw. anker-lose Slots)
b_step AS (
    SELECT DISTINCT
        sc.File_Name, sc.Step_UUID AS Owner_UUID, 'ScriptStep' AS Owner_Type,
        sc.Script_Name || ' [' || sc.Step_Index || '] ' || sc.Step_Name AS Owner_Name,
        'step_parameter' AS Role_Override,
        sc.Calc_Position::VARCHAR AS Calc_Kind_Raw,
        CAST(NULL AS VARCHAR) AS Formula_Hash,
        sc.Calc_Text AS Formula_Text,
        'Step/' || sc.Slot AS Source_Path
    FROM step_slots sc
    WHERE sc.pos_rn = 1
      AND NOT EXISTS (SELECT 1 FROM a_owner a
                       WHERE a.Owner_UUID = sc.Step_UUID AND a.File_Name = sc.File_Name
                         AND a.Owner_Type = 'ScriptStep'
                         AND a.Step_Pos = sc.Calc_Position)
),
-- (B3) CF-Bodies ohne DDR-Anker
b_cf AS (
    SELECT
        cfc.File_Name, cfc.CF_UUID AS Owner_UUID, 'CustomFunction' AS Owner_Type,
        cfc.CF_Name AS Owner_Name,
        'custom_function' AS Role_Override, '' AS Calc_Kind_Raw,
        cfc.DDR_Hash AS Formula_Hash, cfc.Calculation_Code AS Formula_Text,
        'CustomFunction/Calculation' AS Source_Path
    FROM CalcsForCustomFunctions cfc
    WHERE NULLIF(cfc.Calculation_Code, '') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM a_owner a
                       WHERE a.Owner_UUID = cfc.CF_UUID AND a.File_Name = cfc.File_Name
                         AND a.Owner_Type = 'CustomFunction')
),
-- (B4) LayoutObject-Textslots ohne DDR-Anker (nur die 3 in P1 extrahierten
-- Klartext-Slots Hide/Tooltip/Label; alle übrigen LO-Slots existieren nur mit
-- DDR-Info — Trigger-Parameter kommen per-Trigger aus B4b)
b_lo AS (
    SELECT * FROM (
        SELECT lo.File_Name, lo.Object_UUID AS Owner_UUID, 'LayoutObject' AS Owner_Type,
               CAST(NULL AS VARCHAR) AS Owner_Name,
               'hide' AS Role_Override, 'Hide' AS Calc_Kind_Raw,
               CAST(NULL AS VARCHAR) AS Formula_Hash,
               lo.Hide_Calculation_Text AS Formula_Text,
               'LayoutObject/HideCondition' AS Source_Path
        FROM lo_rep lo
        WHERE lo.rn = 1 AND NULLIF(lo.Hide_Calculation_Text, '') IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM a_owner a
                           WHERE a.Owner_UUID = lo.Object_UUID AND a.File_Name = lo.File_Name
                             AND a.Calc_Kind_Raw = 'Hide')
        UNION ALL
        SELECT lo.File_Name, lo.Object_UUID, 'LayoutObject', NULL,
               'tooltip', 'Tooltip', NULL, lo.Tooltip_Calculation_Text,
               'LayoutObject/Tooltip'
        FROM lo_rep lo
        WHERE lo.rn = 1 AND NULLIF(lo.Tooltip_Calculation_Text, '') IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM a_owner a
                           WHERE a.Owner_UUID = lo.Object_UUID AND a.File_Name = lo.File_Name
                             AND a.Calc_Kind_Raw = 'Tooltip')
        UNION ALL
        SELECT lo.File_Name, lo.Object_UUID, 'LayoutObject', NULL,
               'button_label', 'Label', NULL, lo.Label_Calculation_Text,
               'LayoutObject/Label'
        FROM lo_rep lo
        WHERE lo.rn = 1 AND NULLIF(lo.Label_Calculation_Text, '') IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM a_owner a
                           WHERE a.Owner_UUID = lo.Object_UUID AND a.File_Name = lo.File_Name
                             AND a.Calc_Kind_Raw = 'Label')
    )
),
-- (B4b) Trigger-Parameter ohne DDR-Anker — per Trigger aus ScriptTriggers
-- (Schema 1.26.0), alle drei Owner-Ebenen (LayoutObject/Layout/File; Layout und
-- File hatten zuvor OHNE DDR gar keine Instanz). Calc_Kind_Raw trägt die echte
-- Trigger-ID → Edge_Subrole und damit die Event-Zuordnung der LO-Trigger-
-- Tabelle funktionieren auch ohne DDR-Info; die frühere kollabierte
-- Ein-Instanz-Zeile pro Objekt (Quelle LayoutObjects.ScriptTrigger_Parameter_
-- Text-Aggregat, Calc_Kind_Raw NULL) entfällt. Anti-Join jetzt pro Trigger-ID
-- statt pauschal gegen jeden ScriptTrigger_-Anker des Owners.
b_trig AS (
    SELECT
        st.File_Name, st.Owner_UUID, st.Owner_Type AS Owner_Type,
        CAST(NULL AS VARCHAR) AS Owner_Name,
        'script_trigger_parameter' AS Role_Override,
        'ScriptTrigger_' || st.Trigger_ID AS Calc_Kind_Raw,
        CAST(NULL AS VARCHAR) AS Formula_Hash,
        st.Trigger_Parameter_Text AS Formula_Text,
        st.Owner_Type || '/ScriptTrigger_' || st.Trigger_ID || '/Parameter' AS Source_Path
    FROM ScriptTriggers st
    WHERE NULLIF(st.Trigger_Parameter_Text, '') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM a_owner a
                       WHERE a.Owner_UUID = st.Owner_UUID AND a.File_Name = st.File_Name
                         AND a.Calc_Kind_Raw = 'ScriptTrigger_' || st.Trigger_ID)
),
-- (B5) Record-Access-Calcs ohne DDR-Anker. Anti-Join auf OWNER-Ebene (nicht
-- per Hash): PrivilegeSetRecordAccess.DDR_Hash kann trotz DDR-Info leer sein
-- (am Test-Set verifiziert) — ein Hash-Anti-Join ließe dann dieselben Calcs doppelt
-- entstehen (einmal als Anker-Zeile 131_2, einmal strukturell). Hat ein Set
-- IRGENDEINEN DDR-Anker, deckt die DDR seine Record-Access-Calcs vollständig
-- ab → B5 liefert nur für anker-lose Sets (Dateien ohne DDR-Info).
b_pra AS (
    SELECT
        pra.File_Name, pra.PrivilegeSet_UUID AS Owner_UUID, 'PrivilegeSet' AS Owner_Type,
        CAST(NULL AS VARCHAR) AS Owner_Name,
        'record_access' AS Role_Override, CAST(NULL AS VARCHAR) AS Calc_Kind_Raw,
        pra.DDR_Hash AS Formula_Hash, pra.Calculation_Text AS Formula_Text,
        'RecordAccess/' || pra.Operation || ':' || COALESCE(pra.BaseTable_Name, '?') AS Source_Path
    FROM PrivilegeSetRecordAccess pra
    WHERE NULLIF(pra.Calculation_Text, '') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM a_owner a
                       WHERE a.Owner_UUID = pra.PrivilegeSet_UUID AND a.File_Name = pra.File_Name
                         AND a.Owner_Type = 'PrivilegeSet')
),
-- (B6) Display-Calculations mit LEERER ChunkList (Schema 1.27.0): Bei
-- %X:-typisierten Layoutformeln mit Ausdruck verliert FileMaker die komplette
-- Chunk-Zerlegung (ChunkList leer, Hash = md5('')) — ohne diesen Fallback
-- existierte weder eine Instanz noch irgendeine Kante (lautloser Where-used-
-- Verlust). Anker + Kontext-TO liefert DDR_ChunkListContexts (erfasst auch
-- leere ChunkLists); Formula_Text/Result_Type/Kontext-TO füllt der Display-
-- UPDATE nach dem CTAS, die Feld-Kanten legt P2 A.5.1c an. Join über den
-- Anker-NAMEN — nie über den (dateiweit geteilten) Leerhash. Rollen-
-- Klassifikation läuft über Calc_Kind_Raw ('DisplayCalculations_<i>') wie bei
-- den A-Zeilen; der a_owner-Anti-Join ist defensiv (0 Chunks ⇒ kein Anker).
b_disp AS (
    SELECT
        ctx.File_Name,
        oc_lo.Object_UUID AS Owner_UUID,
        'LayoutObject' AS Owner_Type,
        CAST(NULL AS VARCHAR) AS Owner_Name,
        CAST(NULL AS VARCHAR) AS Role_Override,
        regexp_replace(ctx.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', '') AS Calc_Kind_Raw,
        ctx.Calc_Hash AS Formula_Hash,
        CAST(NULL AS VARCHAR) AS Formula_Text,
        'LayoutObject/DisplayCalculations' AS Source_Path
    FROM DDR_ChunkListContexts ctx
    JOIN ObjectCatalog oc_lo
      ON upper(oc_lo.Object_UUID) = upper(regexp_extract(ctx.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
     AND oc_lo.File_Name   = ctx.File_Name
     AND oc_lo.Object_Type = 'LayoutObject'
    WHERE ctx.Chunk_Count = 0
      AND ctx.Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
      AND NOT EXISTS (SELECT 1 FROM a_owner a
                       WHERE a.Owner_UUID = oc_lo.Object_UUID AND a.File_Name = ctx.File_Name
                         AND a.Calc_Kind_Raw = regexp_replace(ctx.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', ''))
),
b_rows AS (
    SELECT File_Name, Owner_UUID, Owner_Type, Owner_Name, Role_Override,
           Calc_Kind_Raw, CAST(NULL AS VARCHAR) AS DDR_Calc_UUID, Formula_Hash,
           Formula_Text, CAST(NULL AS VARCHAR) AS Context_TO_UUID,
           CAST(NULL AS VARCHAR) AS Context_TO_Name,
           CAST(NULL AS BOOLEAN) AS Is_Static, CAST(NULL AS INTEGER) AS Chunk_Count,
           CAST(NULL AS INTEGER) AS Ref_Count, CAST(NULL AS VARCHAR) AS Display_Text,
           Source_Path
    FROM (
        SELECT * FROM b_field
        UNION ALL SELECT * FROM b_step
        UNION ALL SELECT * FROM b_cf
        UNION ALL SELECT * FROM b_lo
        UNION ALL SELECT * FROM b_trig
        UNION ALL SELECT * FROM b_pra
        UNION ALL SELECT * FROM b_disp
    )
),
-- B-Zeilen mit Hash: Chunk-Aggregate über den Hash-Repräsentanten anreichern
b_enriched AS (
    SELECT
        b.File_Name, b.Owner_UUID, b.Owner_Type, b.Owner_Name, b.Role_Override,
        b.Calc_Kind_Raw, b.DDR_Calc_UUID, b.Formula_Hash, b.Formula_Text,
        b.Context_TO_UUID, b.Context_TO_Name,
        COALESCE(b.Is_Static, (hr.Ref_Count = 0)) AS Is_Static,
        COALESCE(b.Chunk_Count, hr.Chunk_Count)   AS Chunk_Count,
        COALESCE(b.Ref_Count, hr.Ref_Count)       AS Ref_Count,
        COALESCE(b.Display_Text, hr.Display_Text) AS Display_Text,
        b.Source_Path
    FROM b_rows b
    LEFT JOIN hash_rep hr
           ON hr.File_Name = b.File_Name AND hr.Calc_Hash = b.Formula_Hash
),
cand AS (
    SELECT * FROM a_rows
    UNION ALL BY NAME
    SELECT * FROM b_enriched
),
classified AS (
    SELECT
        cand.*,
        -- Rollen-Normalisierung (locale-unabhängig, stabil); unbekannte
        -- Suffixe fallen auf lower(raw) zurück → P6 v_check_calc_roles meldet
        -- Vokabular-Drift statt still zu raten.
        COALESCE(cand.Role_Override,
            CASE
                -- Feld-Slot-Codes (ooe-fm-verifiziert): 0=Haupt-Calc, 1=AutoEnter,
                -- 2=Validierung, 3=Container-Storage-Pfad, 4=Fehlermeldungs-Calc
                WHEN cand.Owner_Type = 'Field' AND cand.Calc_Kind_Raw = '0' THEN 'field_calculation'
                WHEN cand.Owner_Type = 'Field' AND cand.Calc_Kind_Raw = '1' THEN 'auto_enter'
                WHEN cand.Owner_Type = 'Field' AND cand.Calc_Kind_Raw = '2' THEN 'validation'
                WHEN cand.Owner_Type = 'Field' AND cand.Calc_Kind_Raw = '3' THEN 'container_path'
                WHEN cand.Owner_Type = 'Field' AND cand.Calc_Kind_Raw = '4' THEN 'validation_message'
                -- Step-Slots generisch: jedes Suffix außer den XSLT-Slots ist ein
                -- positionierter Parameter (deckt auch benannte Wiederhol-Slots
                -- wie Filter_0/Filter_1 und Text-Slots wie SQL ab)
                WHEN cand.Owner_Type = 'ScriptStep' AND cand.Calc_Kind_Raw IN ('XML', 'XSL') THEN 'step_xslt'
                WHEN cand.Owner_Type = 'ScriptStep' THEN 'step_parameter'
                WHEN cand.Owner_Type = 'PrivilegeSet' THEN 'record_access'
                -- Berechnete Menü-Item-Parameter (numerische Suffixe, ooe-fm)
                WHEN cand.Owner_Type = 'CustomMenuItem'
                     AND cand.Calc_Kind_Raw ~ '^[0-9]+(_[0-9]+)*$' THEN 'menu_item_parameter'
                WHEN cand.Owner_Type = 'LayoutObject'
                     AND cand.Calc_Kind_Raw LIKE 'DisplayCalculations\_%' ESCAPE '\' THEN 'display_calculation'
                WHEN cand.Calc_Kind_Raw = ''                                 THEN 'custom_function'
                WHEN cand.Calc_Kind_Raw LIKE 'ScriptTrigger\_%' ESCAPE '\'   THEN 'script_trigger_parameter'
                WHEN cand.Calc_Kind_Raw LIKE 'Condition\_%'     ESCAPE '\'   THEN 'conditional_format'
                WHEN cand.Calc_Kind_Raw = 'Hide'         THEN 'hide'
                WHEN cand.Calc_Kind_Raw = 'Tooltip'      THEN 'tooltip'
                WHEN cand.Calc_Kind_Raw = 'Placeholder'  THEN 'placeholder'
                WHEN cand.Calc_Kind_Raw = 'Label'        THEN 'button_label'
                WHEN cand.Calc_Kind_Raw = 'action'       THEN 'button_action'
                WHEN cand.Calc_Kind_Raw = 'Portal'       THEN 'portal_filter'
                WHEN cand.Calc_Kind_Raw = 'WebViewer'    THEN 'web_viewer_url'
                WHEN cand.Calc_Kind_Raw = 'TabPanel'     THEN 'panel_title'
                WHEN cand.Calc_Kind_Raw = 'PopoverPanel' THEN 'popover_title'
                WHEN cand.Owner_Type = 'CustomMenu'     AND cand.Calc_Kind_Raw = 'Install' THEN 'menu_install'
                WHEN cand.Owner_Type = 'CustomMenu'     AND cand.Calc_Kind_Raw = 'Title'   THEN 'menu_title'
                WHEN cand.Owner_Type = 'CustomMenuItem' AND cand.Calc_Kind_Raw = 'Install' THEN 'menu_item_install'
                WHEN cand.Owner_Type = 'CustomMenuItem' AND cand.Calc_Kind_Raw = 'Name'    THEN 'menu_item_name'
                WHEN cand.Calc_Kind_Raw = 'Series_Value'
                  OR cand.Calc_Kind_Raw LIKE 'YSeriesList\_%' ESCAPE '\'     THEN 'chart_series'
                -- Chart-Kopf-Slots (Suffixe aus dem SaXML-Chart-Block
                -- External/Chart): 'Title' ist generisch und
                -- kollidiert mit CustomMenu+Title → auf LayoutObject scopen.
                -- Achsen-Titel getrennt kuratiert (die Achse ist analytisch
                -- relevant); YSeriesList_<n>_Title bleibt bewusst bei
                -- chart_series (Label + Wert einer Serie teilen die Rolle,
                -- Calc_Kind_Raw hält sie unterscheidbar).
                WHEN cand.Owner_Type = 'LayoutObject'
                     AND cand.Calc_Kind_Raw = 'Title'           THEN 'chart_title'
                WHEN cand.Owner_Type = 'LayoutObject'
                     AND cand.Calc_Kind_Raw = 'XAxisList_Title' THEN 'chart_xaxis_title'
                WHEN cand.Owner_Type = 'LayoutObject'
                     AND cand.Calc_Kind_Raw = 'YAxisList_Title' THEN 'chart_yaxis_title'
                ELSE COALESCE(NULLIF(lower(cand.Calc_Kind_Raw), ''), 'unknown')
            END
        ) AS Calc_Role,
        -- Sortier-Schlüssel für Calc_Index: führende Nummer (Step-Position,
        -- Condition_N via zweitem Extract), Sub-Nummer ('137_2'), dann stabile
        -- Tiebreaker (Suffix, Anker-UUID, Hash).
        COALESCE(TRY_CAST(regexp_extract(cand.Calc_Kind_Raw, '^([0-9]+)', 1) AS BIGINT),
                 TRY_CAST(regexp_extract(cand.Calc_Kind_Raw, '_([0-9]+)$', 1) AS BIGINT),
                 0) AS sort_n1,
        COALESCE(TRY_CAST(regexp_extract(cand.Calc_Kind_Raw, '^[0-9]+_([0-9]+)$', 1) AS BIGINT), 0) AS sort_n2
    FROM cand
),
indexed AS (
    SELECT
        classified.*,
        ROW_NUMBER() OVER (
            PARTITION BY File_Name, Owner_UUID, Calc_Role
            ORDER BY sort_n1, sort_n2,
                     COALESCE(Calc_Kind_Raw, ''), COALESCE(DDR_Calc_UUID, ''),
                     COALESCE(Formula_Hash, ''), COALESCE(Source_Path, '')
        ) AS Calc_Index
    FROM classified
)
SELECT
    -- Typ-getaggter synthetischer Schlüssel (docs/agents/synthetic-uuids.md);
    -- File_Name im Schlüssel, weil Owner-UUIDs nur je Datei eindeutig sind.
    md5('Calculation::' || i.File_Name || '::' || i.Owner_UUID || '::'
        || i.Calc_Role || '::' || i.Calc_Index)     AS Calculation_UUID,
    i.Owner_UUID,
    i.Owner_Type,
    COALESCE(i.Owner_Name, oc2.Object_Name)         AS Owner_Name,
    i.Calc_Role,
    i.Calc_Kind_Raw,
    i.Calc_Index,
    -- Link_Subrole-Wert der owner-projizierten Kanten dieser Instanz
    -- (Join-Schlüssel für v_calculation_links; NULL = Kanten ohne Subrole)
    CASE
        WHEN i.Owner_Type = 'Field' THEN
            CASE i.Calc_Role
                WHEN 'field_calculation'  THEN NULL
                WHEN 'auto_enter'         THEN 'auto_enter'
                WHEN 'validation'         THEN 'validation'
                WHEN 'validation_message' THEN 'validation_message'
                ELSE NULLIF(i.Calc_Kind_Raw, '')
            END
        WHEN i.Owner_Type = 'CustomFunction' THEN NULL
        ELSE NULLIF(i.Calc_Kind_Raw, '')
    END                                             AS Edge_Subrole,
    i.Formula_Text,
    i.Formula_Hash,
    i.DDR_Calc_UUID,
    i.Context_TO_UUID,
    i.Context_TO_Name,
    i.Is_Static,
    i.Chunk_Count,
    i.Ref_Count,
    i.Display_Text,
    i.Source_Path,
    i.File_Name
FROM indexed i
-- Owner-Name-Fallback als reiner Equi-Join — bewusst OHNE i.Owner_Name-IS-NULL-
-- Guard in der ON-Klausel (linksseitiges Prädikat → Blockwise-NL-Falle, s.
-- Blockkopf). Semantischer Guard bleibt das COALESCE in der Projektion: bei
-- gesetztem Owner_Name ist das Join-Ergebnis irrelevant. Fan-out nur bei
-- Katalog-Duplikaten auf (Object_UUID, File_Name, Object_Type) — durch die
-- Duplikat-Absorption ausgeschlossen und via v_check_catalog_dups überwacht.
LEFT JOIN ObjectCatalog oc2
       ON oc2.Object_UUID = i.Owner_UUID
      AND oc2.File_Name   = i.File_Name
      AND oc2.Object_Type = i.Owner_Type;

CREATE INDEX idx_calculations_owner ON CalculationsCatalog(Owner_UUID, File_Name);
CREATE INDEX idx_calculations_hash  ON CalculationsCatalog(Formula_Hash);
CREATE INDEX idx_calculations_role  ON CalculationsCatalog(Calc_Role);
CREATE INDEX idx_calculations_ddr   ON CalculationsCatalog(DDR_Calc_UUID);

-- LayoutObjectConditions.Calculation_UUID (Schema 1.25.0): FK der CF-Regel auf
-- ihre Berechnungs-Instanz — füllbar erst HIER (P3 legt die Tabelle vor dem
-- CalculationsCatalog-Aufbau an). Join über Calc_Kind_Raw = 'Condition_' ||
-- Rule_Index (DDRREF-Suffix == Serialisierungsposition, korpus-verifiziert 0
-- Abweichungen), NICHT über Calc_Index: DDRREF-lose Regeln erzeugen dort Lücken.
-- Bleibt NULL für Regeln ohne CalculationsCatalog-Zeile (wertbasiert ohne Anker,
-- Dateien ohne DDR-Info, Fremd-Anker-Kopierartefakte) — P6 v_check_cf_rules
-- meldet die Hash-tragenden Fälle darunter.
UPDATE LayoutObjectConditions c
SET Calculation_UUID = (
    SELECT cc.Calculation_UUID
    FROM CalculationsCatalog cc
    WHERE cc.Owner_UUID   = c.Object_UUID
      AND cc.File_Name    = c.File_Name
      AND cc.Calc_Role    = 'conditional_format'
      AND cc.Calc_Kind_Raw = 'Condition_' || c.Rule_Index
);

-- Display-Calculation-Anreicherung (Schema 1.27.0): Formula_Text war bei allen
-- display_calculation-Instanzen NULL (die Original-Formel steht nur im
-- Text_Content des Owners), Kontext-TO ebenso (die ChunkList trägt sie, wurde
-- aber nicht extrahiert). Jetzt: Formula_Text = lokalisierte Rohformel aus
-- Text_Content (i-tes <<ƒ:…>>-Vorkommen, Index aus dem Calc_Kind_Raw-Suffix,
-- (?s) für mehrzeilige Formeln; Wrapper + %X:-Präfix gestrippt), Result_Type
-- aus dem Präfix (kein Präfix = Text; unbekannte Präfixe bleiben roh sichtbar
-- als '%<X>'), Kontext-TO aus DDR_ChunkListContexts (Anker-Join über den
-- NAMEN — nie über den Hash: geteilte Hashes tragen je Anker eigene TOs).
-- Deckt A-Zeilen (DDR-Anker) UND b_disp-Fallback-Zeilen (leere ChunkList) ab.
-- Index-Annahme: DisplayCalculations_<i> ↔ (i+1)-tes <<ƒ:…>>-Vorkommen in
-- Dokumentreihenfolge (membercount>1 im Fixture noch unbelegt).
ALTER TABLE CalculationsCatalog ADD COLUMN Result_Type VARCHAR;

UPDATE CalculationsCatalog cc
SET Formula_Text    = COALESCE(src.formula_stripped, cc.Formula_Text),
    Result_Type     = src.result_type,
    Context_TO_UUID = COALESCE(cc.Context_TO_UUID, src.Context_TO_UUID),
    Context_TO_Name = COALESCE(cc.Context_TO_Name, src.Context_TO_Name)
FROM (
    WITH lo1 AS (
        SELECT Object_UUID, File_Name, Text_Content,
               ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
        FROM LayoutObjects
    ),
    disp AS (
        SELECT
            c.Calculation_UUID, c.Owner_UUID, c.File_Name, c.Calc_Kind_Raw,
            regexp_extract_all(lo.Text_Content, '(?s)<<ƒ:(.*?)>>', 1)
                [TRY_CAST(regexp_extract(c.Calc_Kind_Raw, '_([0-9]+)$', 1) AS BIGINT) + 1] AS raw_formula
        FROM CalculationsCatalog c
        JOIN lo1 lo
          ON lo.Object_UUID = c.Owner_UUID
         AND lo.File_Name   = c.File_Name
         AND lo.rn = 1
        WHERE c.Calc_Role = 'display_calculation'
    )
    SELECT
        d.Calculation_UUID,
        NULLIF(regexp_replace(d.raw_formula, '^%[A-Z]+:', ''), '') AS formula_stripped,
        CASE regexp_extract(d.raw_formula, '^%([A-Z]+):', 1)
            WHEN 'N' THEN 'Number'
            WHEN 'D' THEN 'Date'
            WHEN 'I' THEN 'Time'
            WHEN 'M' THEN 'Timestamp'
            WHEN ''  THEN 'Text'
            ELSE '%' || regexp_extract(d.raw_formula, '^%([A-Z]+):', 1)
        END AS result_type,
        ctx.Context_TO_UUID,
        ctx.Context_TO_Name
    FROM disp d
    LEFT JOIN DDR_ChunkListContexts ctx
           ON upper(ctx.Calc_UUID) = upper('_' || d.Owner_UUID || '_' || d.Calc_Kind_Raw)
          AND ctx.File_Name = d.File_Name
) src
WHERE cc.Calculation_UUID = src.Calculation_UUID;

-- Calculation-Zeilen in den ObjectCatalog (post-CTAS-INSERT, Muster
-- PluginComponent — liest CalculationsCatalog + die Owner-Namen).
-- Object_Name = '<Owner> › <Rollen-Label>[ <Index>]' (Index nur, wenn der
-- Owner mehrere Instanzen derselben Rolle hat). Sichtbarkeits-Entscheid:
-- in Suche/Listen sichtbar wie ScriptStep/LayoutObject (High-Cardinality-
-- Präzedenz); Explorer/Atlas blenden den Typ default aus.
INSERT INTO ObjectCatalog (Object_UUID, Object_Type, Object_Name, File_Name, Source_Table, Object_ID)
SELECT
    c.Calculation_UUID                              AS Object_UUID,
    'Calculation'                                   AS Object_Type,
    COALESCE(c.Owner_Name, '(unresolved)') || ' › '
        || CASE c.Calc_Role
               WHEN 'field_calculation'        THEN 'Calculation'
               WHEN 'auto_enter'               THEN 'Auto-Enter Calculation'
               WHEN 'validation'               THEN 'Validation'
               WHEN 'validation_message'       THEN 'Validation Message'
               WHEN 'container_path'           THEN 'Container Storage Path'
               WHEN 'custom_function'          THEN 'Function Body'
               WHEN 'step_parameter'           THEN 'Step Parameter'
               WHEN 'step_xslt'                THEN 'XSLT'
               WHEN 'record_access'            THEN 'Record Access'
               WHEN 'hide'                     THEN 'Hide Condition'
               WHEN 'tooltip'                  THEN 'Tooltip'
               WHEN 'placeholder'              THEN 'Placeholder Text'
               WHEN 'button_label'             THEN 'Calculated Label'
               WHEN 'button_action'            THEN 'Button Action'
               WHEN 'portal_filter'            THEN 'Portal Filter'
               WHEN 'web_viewer_url'           THEN 'Web Viewer URL'
               WHEN 'panel_title'              THEN 'Tab Title'
               WHEN 'popover_title'            THEN 'Popover Title'
               WHEN 'conditional_format'       THEN 'Conditional Formatting'
               WHEN 'script_trigger_parameter' THEN 'Script Trigger Parameter'
               WHEN 'menu_install'             THEN 'Install Condition'
               WHEN 'menu_item_install'        THEN 'Install Condition'
               WHEN 'menu_title'               THEN 'Menu Title'
               WHEN 'menu_item_name'           THEN 'Calculated Name'
               WHEN 'menu_item_parameter'      THEN 'Item Parameter'
               WHEN 'display_calculation'      THEN 'Display Calculation'
               WHEN 'chart_series'             THEN 'Chart Series'
               WHEN 'chart_title'              THEN 'Chart Title'
               WHEN 'chart_xaxis_title'        THEN 'X-Axis Title'
               WHEN 'chart_yaxis_title'        THEN 'Y-Axis Title'
               ELSE c.Calc_Role
           END
        || CASE WHEN COUNT(*) OVER (PARTITION BY c.File_Name, c.Owner_UUID, c.Calc_Role) > 1
                THEN ' ' || c.Calc_Index ELSE '' END AS Object_Name,
    c.File_Name,
    'CalculationsCatalog'                           AS Source_Table,
    NULL                                            AS Object_ID
FROM CalculationsCatalog c;

-- Indexes für ObjectCatalog
CREATE INDEX idx_objectcatalog_type ON ObjectCatalog(Object_Type);
CREATE INDEX idx_objectcatalog_file ON ObjectCatalog(File_Name);
CREATE INDEX idx_objectcatalog_name ON ObjectCatalog(Object_Name);
CREATE INDEX idx_objectcatalog_composite ON ObjectCatalog(Object_Type, File_Name);


-- ========================================
-- ScriptStepRoleMap — Link-Rolle je Script-Step-Typ (Step-ID-basiert)
-- ========================================
-- Kuratierte Zuordnung Step_ID → Link_Role für den Script→Field-Block (16).
-- LOCALE-UNABHÄNGIG: SaXML schreibt Step/@name in der UI-Sprache des
-- exportierenden FileMaker-Clients (deutsche Exporte im Korpus!) — die frühere
-- Step_Name-CASE-Liste fiel für lokalisierte Exporte komplett auf
-- references_field zurück. Die Step-ID (Step/@id) ist stabil und sprachfrei.
-- IDs verifiziert gegen die Referenz-DB (script_steps.step_id ≙ SaXML Step/@id,
-- 169/169 Korpus-Step-Typen matchen per ID). Die Referenz-DB ist bewusst KEINE
-- Laufzeit-Abhängigkeit des Konverters (Konverter und REST-API können getrennt
-- installiert sein) — sie dient als Kurations-/Verifikationsquelle; Canonical_Name
-- dokumentiert den englischen Referenz-Namen. Volatil (jeder P4-Lauf baut neu),
-- analog LinkRoleRegistry. Nicht gelistete Step-IDs → Fallback 'references_field'
-- (P6-Wächter v_check_step_roles meldet Korpus-Treffer zur Nachkuration).
CREATE OR REPLACE TABLE ScriptStepRoleMap (
    Step_ID INTEGER PRIMARY KEY,
    Canonical_Name VARCHAR NOT NULL,
    Link_Role VARCHAR NOT NULL
);
INSERT INTO ScriptStepRoleMap VALUES
    -- Step schreibt/verändert den Feldinhalt
    (76,  'Set Field',                'sets_field'),
    (91,  'Replace Field Contents',   'sets_field'),
    (77,  'Insert Calculated Result', 'sets_field'),
    (61,  'Insert Text',              'sets_field'),
    (131, 'Insert File',              'sets_field'),
    (160, 'Insert from URL',          'sets_field'),
    (48,  'Paste',                    'sets_field'),
    (49,  'Clear',                    'sets_field'),
    (130, 'Set Selection',            'sets_field'),
    (116, 'Set Next Serial Value',    'sets_field'),
    (40,  'Relookup Field Contents',  'sets_field'),
    (46,  'Cut',                      'sets_field'),
    -- Insert-Familie: der Step schreibt in das Zielfeld (option_type 'target'
    -- bzw. die Feld-Option der Referenz)
    (11,  'Insert from Index',            'sets_field'),
    (12,  'Insert from Last Visited',     'sets_field'),
    (13,  'Insert Current Date',          'sets_field'),
    (14,  'Insert Current Time',          'sets_field'),
    (60,  'Insert Current User Name',     'sets_field'),
    (161, 'Insert from Device',           'sets_field'),
    -- Data-File-API + Konnektoren: Ergebnis landet im Zielfeld
    (188, 'Get File Exists',              'sets_field'),
    (189, 'Get File Size',                'sets_field'),
    (191, 'Open Data File',               'sets_field'),
    (193, 'Read from Data File',          'sets_field'),
    (194, 'Get Data File Position',       'sets_field'),
    (203, 'Execute FileMaker Data API',   'sets_field'),
    (211, 'Trigger Claris Connect Flow',  'sets_field'),
    -- KI-Steps mit genau EINER Feld-Option (Ergebnis-Ziel)
    (214, 'Perform SQL Query by Natural Language', 'sets_field'),
    (215, 'Insert Embedding',             'sets_field'),
    -- Step liest aus dem Feld
    (47,  'Copy',                     'reads_field'),
    (132, 'Export Field Contents',    'reads_field'),
    (18,  'Check Selection',          'reads_field'),
    (157, 'Install Plug-In File',     'reads_field'),
    -- Write to Data File: die Feld-Option heisst 'data_source' ("Data source") —
    -- option_type = 'target' beschreibt die XML-Form, NICHT die Datenrichtung.
    -- Das Feld wird gelesen und in die Datei geschrieben.
    (192, 'Write to Data File',       'reads_field'),
    -- Kalkulations-tragende Steps: Feld-Referenzen aus deren Formeln erscheinen
    -- als Step-Referenzen nur bei Dateien OHNE DDR-Info (mit DDR laufen sie über
    -- XMLCalcReferences) — Lese-Semantik, analog zum DDR-Pfad.
    (68,  'If',                       'reads_field'),
    (125, 'Else If',                  'reads_field'),
    (72,  'Exit Loop If',             'reads_field'),
    (141, 'Set Variable',             'reads_field'),
    (1,   'Perform Script',           'reads_field'),
    -- Cursor-Navigation zum Feld
    (17,  'Go to Field',              'navigates_to_field'),
    (74,  'Go to Related Record',     'navigates_to_field'),
    -- Feld als Such-Kriterium
    (28,  'Perform Find',             'finds_in_field'),
    (126, 'Constrain Found Set',      'finds_in_field'),
    (127, 'Extend Found Set',         'finds_in_field'),
    (22,  'Enter Find Mode',          'finds_in_field'),
    (155, 'Find Matching Records',    'finds_in_field'),
    -- Feld als Sortier-Kriterium
    (39,  'Sort Records',             'sorts_by_field'),
    (154, 'Sort Records by Field',    'sorts_by_field'),
    -- Import-Ziel / Export-Quelle / Dialog-Eingabe
    (35,  'Import Records',           'imports_to_field'),
    (36,  'Export Records',           'exports_from_field'),
    (87,  'Show Custom Dialog',       'inputs_to_field'),
    -- Mehrere Feld-Optionen mit GEGENLÄUFIGER Semantik (Quelle UND Ziel im selben
    -- Step, z. B. 216: source_field + target_field). Diese Tabelle vergibt EINE
    -- Rolle je Step_ID, und XMLStepReferences extrahiert Feldreferenzen flach über
    -- '//FieldReference' ohne Herkunftspfad — welche Option eine Referenz gespeist
    -- hat, ist im Datenmodell derzeit nicht vorhanden. Deshalb bewusst der neutrale
    -- Eimer statt einer erfundenen Hauptrolle: 'references_field' zählt für
    -- Where-used und behauptet keine Richtung. Eine Verfeinerung braucht einen
    -- P2-Umbau (Elternpfad je FieldReference) und ist ein eigener Vorgang.
    (213, 'Fine-Tune Model',               'references_field'),
    (216, 'Insert Embedding in Found Set', 'references_field'),
    (218, 'Perform Semantic Find',         'references_field'),
    (220, 'Generate Response from Model',  'references_field'),
    (222, 'Configure Regression Model',    'references_field');

-- ========================================
-- DataSourceFileMap — deklarierte Datenquelle → importierte Datei
-- ========================================
-- Löst je (File_Name, DS_UUID) auf, WELCHE importierte Datei eine externe
-- FileMaker-Datenquelle meint. Auflösungs-Reihenfolge wie FileMaker selbst:
--   Prio 0: direkter DS_Name-Match gegen FilesCatalog (`.fmp12` gestrippt)
--   Prio n: Pfadliste (Path, newline-separiert) in Deklarations-Reihenfolge —
--           die ERSTE importierte Datei gewinnt. Protokoll-Präfixe
--           (file:/filemac:/filewin:/filelinux:) und Verzeichnisanteile werden
--           gestrippt, verglichen wird der Dateiname (case-insensitiv, wie FM).
-- Schließt die _dev-Suffix-Lücke: `DS_Name='GDB_Mod_RZ'` mit
-- `Path='file:GDB_Mod_RZ\nfile:GDB_Mod_RZ_dev'` → importierte Datei
-- `GDB_Mod_RZ_dev`, die der reine DS_Name-Match nie fände.
-- Nicht importierte Datenquellen (Partial-Korpus) haben KEINE Zeile —
-- Konsumenten (Block 6, prefer-declared-source-Pass, P6-Views) fallen dann
-- konservativ auf das bisherige Verhalten zurück.
CREATE OR REPLACE TABLE DataSourceFileMap AS
WITH ds AS (
    SELECT File_Name, DS_UUID,
           string_split(COALESCE(Path, ''), chr(10)) AS path_list
    FROM ExternalDataSourceCatalog
),
candidates AS (
    SELECT File_Name, DS_UUID, 0 AS prio,
           regexp_replace(DS_Name, '\.fmp12$', '') AS cand
    FROM ExternalDataSourceCatalog
    UNION ALL
    SELECT File_Name, DS_UUID, ord,
           regexp_replace(regexp_replace(regexp_replace(entry,
               '^file(mac|win|linux)?:', ''), '.*/', ''), '\.fmp12$', '')
    FROM (SELECT File_Name, DS_UUID,
                 UNNEST(path_list) AS entry,
                 UNNEST(range(1, len(path_list) + 1)) AS ord
          FROM ds)
)
SELECT c.File_Name, c.DS_UUID,
       arg_min(fc.File_Name, c.prio) AS Resolved_File
FROM candidates c
JOIN FilesCatalog fc ON lower(fc.File_Name) = lower(c.cand)
GROUP BY c.File_Name, c.DS_UUID;


-- ========================================
-- ObjectLinks - Verknüpfungen zwischen Objekten
-- ========================================
-- Extrahiert alle operationalen Links aus den Basis-Tabellen
-- Ermöglicht Cross-File Abhängigkeitsanalyse
--
-- WICHTIG: Is_Cross_File wird durch JOIN mit ObjectCatalog berechnet,
-- um die tatsächlichen File_Names der Source- und Target-Objekte zu vergleichen.

CREATE OR REPLACE TABLE ObjectLinks AS

-- 1. Relationships → Table Occurrences (Left)
SELECT
    'rel_' || rc.Rel_ID::VARCHAR || '_' || rc.File_Name as Source_UUID,
    'Relationship' as Source_Type,
    rc.Left_TO_UUID as Target_UUID,
    'TableOccurrence' as Target_Type,
    'operational' as Link_Type,
    'left_table' as Link_Role,
    NULL as Link_Subrole,
    rc.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (rc.File_Name != oc_target.File_Name) as Is_Cross_File
-- DISTINCT: ein left_table-Link je Relation, nicht je Join-Prädikat (Schema 1.2.0).
FROM (SELECT DISTINCT Rel_ID, File_Name, Left_TO_UUID FROM RelationshipCatalog) rc
LEFT JOIN ObjectCatalog oc_target ON rc.Left_TO_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'TableOccurrence'

UNION ALL

-- 2. Relationships → Table Occurrences (Right)
SELECT
    'rel_' || rc.Rel_ID::VARCHAR || '_' || rc.File_Name as Source_UUID,
    'Relationship' as Source_Type,
    rc.Right_TO_UUID as Target_UUID,
    'TableOccurrence' as Target_Type,
    'operational' as Link_Type,
    'right_table' as Link_Role,
    NULL as Link_Subrole,
    rc.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (rc.File_Name != oc_target.File_Name) as Is_Cross_File
-- DISTINCT: ein right_table-Link je Relation, nicht je Join-Prädikat (Schema 1.2.0).
FROM (SELECT DISTINCT Rel_ID, File_Name, Right_TO_UUID FROM RelationshipCatalog) rc
LEFT JOIN ObjectCatalog oc_target ON rc.Right_TO_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'TableOccurrence'

UNION ALL

-- 3. Relationships → Fields (Left Field)
SELECT
    'rel_' || rc.Rel_ID::VARCHAR || '_' || rc.File_Name as Source_UUID,
    'Relationship' as Source_Type,
    rc.Left_Field_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'left_field' as Link_Role,
    NULL as Link_Subrole,
    rc.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (rc.File_Name != oc_target.File_Name) as Is_Cross_File
-- DISTINCT: ein left_field-Link je (Relation, Feld), nicht je Join-Prädikat. Seit
-- Schema 1.2.0 ist RelationshipCatalog per-Prädikat — ein Feld, das in mehreren
-- Prädikaten derselben Seite vorkommt, ergäbe sonst doppelte (identische) Links.
FROM (SELECT DISTINCT Rel_ID, File_Name, Left_Field_UUID FROM RelationshipCatalog WHERE Left_Field_UUID IS NOT NULL) rc
LEFT JOIN ObjectCatalog oc_target ON rc.Left_Field_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Field'

UNION ALL

-- 4. Relationships → Fields (Right Field)
SELECT
    'rel_' || rc.Rel_ID::VARCHAR || '_' || rc.File_Name as Source_UUID,
    'Relationship' as Source_Type,
    rc.Right_Field_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'right_field' as Link_Role,
    NULL as Link_Subrole,
    rc.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (rc.File_Name != oc_target.File_Name) as Is_Cross_File
-- DISTINCT: ein right_field-Link je (Relation, Feld), nicht je Join-Prädikat (s.o.).
FROM (SELECT DISTINCT Rel_ID, File_Name, Right_Field_UUID FROM RelationshipCatalog WHERE Right_Field_UUID IS NOT NULL) rc
LEFT JOIN ObjectCatalog oc_target ON rc.Right_Field_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Field'

UNION ALL

-- 4b. Relationships → Fields (Sort fields, per side) — die in „Datensätze sortieren"
-- konfigurierten Felder sind eine echte Abhängigkeit der Beziehung. Link_Role='sort_field',
-- Link_Subrole = Seite ('left'/'right'). Die per-Seite index-gleichen Arrays (UUID/id/TO-UUID)
-- werden parallel ge-UNNEST-et, dann DISTINCT (Arrays sind über alle Predicate_Index-Zeilen
-- einer Relation konstant). Die Sort-FieldReference-UUID ist kontext-synthetisch → über
-- (TO_UUID, Feld-id) auf die kanonische Feld-UUID auflösen (Feld-id entity-frei),
-- Fallback = synthetische UUID. Schließt die zuvor 122 Phantom-sort_field-Links.
SELECT
    'rel_' || rc.Rel_ID::VARCHAR || '_' || rc.File_Name as Source_UUID,
    'Relationship' as Source_Type,
    COALESCE(f_canon.Field_UUID, rc.sort_field_uuid) as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'sort_field' as Link_Role,
    rc.side as Link_Subrole,
    rc.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (rc.File_Name != oc_target.File_Name) as Is_Cross_File
FROM (
    SELECT DISTINCT Rel_ID, File_Name, side, sort_field_uuid, sort_field_id, sort_to_uuid FROM (
        SELECT Rel_ID, File_Name, 'left' AS side,
               UNNEST(Left_Sort_Field_UUIDs) AS sort_field_uuid,
               UNNEST(Left_Sort_Field_IDs) AS sort_field_id,
               UNNEST(Left_Sort_Field_TO_UUIDs) AS sort_to_uuid
        FROM RelationshipCatalog WHERE Left_Sort_Field_UUIDs IS NOT NULL
        UNION ALL
        SELECT Rel_ID, File_Name, 'right' AS side,
               UNNEST(Right_Sort_Field_UUIDs),
               UNNEST(Right_Sort_Field_IDs),
               UNNEST(Right_Sort_Field_TO_UUIDs)
        FROM RelationshipCatalog WHERE Right_Sort_Field_UUIDs IS NOT NULL
    )
) rc
LEFT JOIN TableOccurrenceCatalog toc ON toc.TO_UUID = rc.sort_to_uuid AND toc.File_Name = rc.File_Name
LEFT JOIN FieldsForTables f_canon
       ON f_canon.Table_Name = toc.BT_Name
      AND f_canon.File_Name = regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
      AND f_canon.Field_ID = rc.sort_field_id
LEFT JOIN ObjectCatalog oc_target ON COALESCE(f_canon.Field_UUID, rc.sort_field_uuid) = oc_target.Object_UUID AND oc_target.Object_Type = 'Field'

UNION ALL

-- 4c. Relationships → ValueLists (Custom-Sortierung nach Werteliste, per Seite)
-- Eine Beziehungsseite kann in „Datensätze sortieren" eine Custom-Sortierung nach
-- Werteliste tragen (<Sort type="Custom"> mit <ValueListReference>). Exakt analog zu
-- Block 4b (sort_field): per-Seite-Array UNNESTen, DISTINCT über die Prädikat-Zeilen
-- (Arrays sind je Relation konstant), Link_Subrole = Seite ('left'/'right').
-- Anders als die Sort-FELD-UUIDs ist die VL-UUID kanonisch (Wertelisten sind
-- datei-lokal, keine kontext-synthetische Referenz-UUID) → direkter UUID-Link.
-- Schließt die Where-used-Lücke für Wertelisten, die NUR als Relationship-
-- Sortier-Referenz dienen (erschienen vorher als ungenutzt).
SELECT
    'rel_' || rc.Rel_ID::VARCHAR || '_' || rc.File_Name as Source_UUID,
    'Relationship' as Source_Type,
    rc.sort_vl_uuid as Target_UUID,
    'ValueList' as Target_Type,
    'operational' as Link_Type,
    'sorts_by_valuelist' as Link_Role,
    rc.side as Link_Subrole,
    rc.File_Name as Source_File,
    COALESCE(oc_target.File_Name, rc.File_Name) as Target_File,
    (rc.File_Name != COALESCE(oc_target.File_Name, rc.File_Name)) as Is_Cross_File
FROM (
    SELECT DISTINCT Rel_ID, File_Name, side, sort_vl_uuid FROM (
        SELECT Rel_ID, File_Name, 'left' AS side,
               UNNEST(Left_Sort_ValueList_UUIDs) AS sort_vl_uuid
        FROM RelationshipCatalog WHERE Left_Sort_ValueList_UUIDs IS NOT NULL
        UNION ALL
        SELECT Rel_ID, File_Name, 'right' AS side,
               UNNEST(Right_Sort_ValueList_UUIDs)
        FROM RelationshipCatalog WHERE Right_Sort_ValueList_UUIDs IS NOT NULL
    )
    WHERE sort_vl_uuid IS NOT NULL AND sort_vl_uuid <> ''
) rc
LEFT JOIN ObjectCatalog oc_target ON rc.sort_vl_uuid = oc_target.Object_UUID AND oc_target.Object_Type = 'ValueList'

UNION ALL

-- 5. Fields → Base Tables
SELECT
    f.Field_UUID as Source_UUID,
    'Field' as Source_Type,
    f.Table_UUID as Target_UUID,
    'BaseTable' as Target_Type,
    'operational' as Link_Type,
    'parent_table' as Link_Role,
    NULL as Link_Subrole,
    f.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (f.File_Name != oc_target.File_Name) as Is_Cross_File
FROM FieldsForTables f
LEFT JOIN ObjectCatalog oc_target ON f.Table_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'BaseTable'

UNION ALL

-- 6. Table Occurrences → Base Tables
-- toc.BT_UUID ist bei EXTERNEN Datenquellen die LOKALE Referenz-UUID (≠ kanonische
-- BaseTable-UUID der Heimatdatei) → der Direkt-Join auf ObjectCatalog verlöre die Kante
-- (base_table erschien in der Where-used der Basistabelle nicht). Deshalb erst über
-- BT_Name + Heimatdatei auf die kanonische BaseTableCatalog.BT_UUID auflösen;
-- Fallback = toc.BT_UUID (lokale TOs, dort bereits kanonisch). toc.BT_UUID bleibt
-- unangetastet — P5 (TableOccurrenceResolution.Local_BT_UUID) braucht die lokale UUID.
-- Die Heimatdatei kommt aus DataSourceFileMap (deklarierte Datenquelle des TOs,
-- schließt die _dev-Suffix-Lücke); zusätzlich wird oc_target auf die aufgelöste
-- Zieldatei GESCOPED — sonst fächert die Kante bei Klon-Korpora in jede Datei auf,
-- die die Ziel-UUID zufällig auch enthält (Phantom-Links, to_base_table>1).
-- Konservativ: ohne S1-Auflösung (lokale TOs, nicht importierte Quellen) bleibt
-- exakt das bisherige Verhalten (Fallback-Ausdruck + ungescoptes oc_target).
SELECT
    toc.TO_UUID as Source_UUID,
    'TableOccurrence' as Source_Type,
    COALESCE(bt_canon.BT_UUID, toc.BT_UUID) as Target_UUID,
    'BaseTable' as Target_Type,
    'operational' as Link_Type,
    'base_table' as Link_Role,
    NULL as Link_Subrole,
    toc.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (toc.File_Name != oc_target.File_Name) as Is_Cross_File
FROM TableOccurrenceCatalog toc
LEFT JOIN DataSourceFileMap dsm
       ON dsm.File_Name = toc.File_Name
      AND dsm.DS_UUID = toc.DS_UUID
LEFT JOIN BaseTableCatalog bt_canon
       ON bt_canon.BT_Name = toc.BT_Name
      AND bt_canon.File_Name = COALESCE(dsm.Resolved_File,
              regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', ''))
LEFT JOIN ObjectCatalog oc_target ON COALESCE(bt_canon.BT_UUID, toc.BT_UUID) = oc_target.Object_UUID AND oc_target.Object_Type = 'BaseTable'
      AND (dsm.Resolved_File IS NULL OR oc_target.File_Name = dsm.Resolved_File)

UNION ALL

-- 7. Table Occurrences → External Data Sources
SELECT
    toc.TO_UUID as Source_UUID,
    'TableOccurrence' as Source_Type,
    toc.DS_UUID as Target_UUID,
    'ExternalDataSource' as Target_Type,
    'operational' as Link_Type,
    'data_source' as Link_Role,
    NULL as Link_Subrole,
    toc.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (toc.File_Name != oc_target.File_Name) as Is_Cross_File
FROM TableOccurrenceCatalog toc
LEFT JOIN ObjectCatalog oc_target ON toc.DS_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'ExternalDataSource'
WHERE toc.DS_UUID IS NOT NULL

UNION ALL

-- 8. Layouts → Table Occurrences
SELECT
    l.L_UUID as Source_UUID,
    'Layout' as Source_Type,
    (SELECT TO_UUID FROM TableOccurrenceCatalog WHERE TO_Name = l.L_TO_Name AND File_Name = l.File_Name LIMIT 1) as Target_UUID,
    'TableOccurrence' as Target_Type,
    'operational' as Link_Type,
    'context_table' as Link_Role,
    NULL as Link_Subrole,
    l.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (l.File_Name != oc_target.File_Name) as Is_Cross_File
FROM Layouts l
LEFT JOIN ObjectCatalog oc_target ON (SELECT TO_UUID FROM TableOccurrenceCatalog WHERE TO_Name = l.L_TO_Name AND File_Name = l.File_Name LIMIT 1) = oc_target.Object_UUID AND oc_target.Object_Type = 'TableOccurrence'
-- Folder-/Separator-Filter: exakt der Filter des Catalog-Blocks 9 — dieser
-- Link-Block hatte keinen → Folder-/Separator-Layouts wurden zu verwaisten
-- Link-QUELLEN (158 Orphan-Sources + Großteil der NULL-Targets, DB-verifiziert).
WHERE (l.Folder_Type IS NULL OR l.Folder_Type = 'False')
  AND NOT COALESCE(l.Is_Separator, FALSE)

UNION ALL

-- 9. Layout Objects → Layouts (Parent)
-- Link_Type 'operational': pragmatisch betrachtet ist "LayoutObject liegt auf
-- Layout X" eine funktionale Information (welches Layout zeigt dieses Element?),
-- nicht nur eine reine Container-Hierarchie. Macht den Link in Standard-
-- Reference-Listen sichtbar (Frontend-Default ist Link_Type='operational').
SELECT
    lo.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    (SELECT L_UUID FROM Layouts WHERE L_ID = lo.Layout_ID AND File_Name = lo.File_Name LIMIT 1) as Target_UUID,
    'Layout' as Target_Type,
    'operational' as Link_Type,
    'parent_layout' as Link_Role,
    NULL as Link_Subrole,
    lo.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (lo.File_Name != oc_target.File_Name) as Is_Cross_File
FROM LayoutObjects lo
-- Klon-Disambiguierung: Containment ist datei-lokal (vgl. parent_script).
LEFT JOIN ObjectCatalog oc_target ON (SELECT L_UUID FROM Layouts WHERE L_ID = lo.Layout_ID AND File_Name = lo.File_Name LIMIT 1) = oc_target.Object_UUID AND oc_target.File_Name = lo.File_Name AND oc_target.Object_Type = 'Layout'

UNION ALL

-- 10. Layout Objects → Layout Objects (Parent-Child, nur wenn verschachtelt)
SELECT
    child.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    (SELECT Object_UUID FROM LayoutObjects parent WHERE parent.Object_ID = child.Parent_Object_ID AND parent.Layout_ID = child.Layout_ID AND parent.File_Name = child.File_Name LIMIT 1) as Target_UUID,
    'LayoutObject' as Target_Type,
    'structural' as Link_Type,
    'parent_object' as Link_Role,
    NULL as Link_Subrole,
    child.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (child.File_Name != oc_target.File_Name) as Is_Cross_File
FROM LayoutObjects child
-- Klon-Disambiguierung: Containment ist datei-lokal (vgl. parent_script).
LEFT JOIN ObjectCatalog oc_target ON (SELECT Object_UUID FROM LayoutObjects parent WHERE parent.Object_ID = child.Parent_Object_ID AND parent.Layout_ID = child.Layout_ID AND parent.File_Name = child.File_Name LIMIT 1) = oc_target.Object_UUID AND oc_target.File_Name = child.File_Name AND oc_target.Object_Type = 'LayoutObject'
WHERE child.Parent_Object_ID IS NOT NULL

UNION ALL

-- 11. Script Steps → Scripts (Parent)
SELECT
    sfs.Step_UUID as Source_UUID,
    'ScriptStep' as Source_Type,
    sfs.Script_UUID as Target_UUID,
    'Script' as Target_Type,
    'structural' as Link_Type,
    'parent_script' as Link_Role,
    NULL as Link_Subrole,
    sfs.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (sfs.File_Name != oc_target.File_Name) as Is_Cross_File
FROM StepsForScripts sfs
-- Klon-Disambiguierung: Containment ist datei-lokal. Ohne File_Name-Abgleich
-- matcht eine geteilte Klon-Script_UUID die Script-Zeile ALLER Klon-Dateien →
-- kartesische parent_script-Kanten (Step-Datei × Script-Datei).
LEFT JOIN ObjectCatalog oc_target ON sfs.Script_UUID = oc_target.Object_UUID AND oc_target.File_Name = sfs.File_Name AND oc_target.Object_Type = 'Script'

UNION ALL

-- 11b. CustomMenuItem → CustomMenu (Parent, structural, AP-3/D-2)
-- Back-link vom Item zu seinem Menü, analog parent_script. Klon-Disambiguierung
-- datei-lokal (Menü-UUID kann über Modul-Dateien geklont sein).
SELECT
    cmi.Item_UUID as Source_UUID,
    'CustomMenuItem' as Source_Type,
    cmi.Menu_UUID as Target_UUID,
    'CustomMenu' as Target_Type,
    'structural' as Link_Type,
    'parent_menu' as Link_Role,
    NULL as Link_Subrole,
    cmi.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (cmi.File_Name != oc_target.File_Name) as Is_Cross_File
FROM CustomMenuItemCatalog cmi
LEFT JOIN ObjectCatalog oc_target ON cmi.Menu_UUID = oc_target.Object_UUID AND oc_target.File_Name = cmi.File_Name AND oc_target.Object_Type = 'CustomMenu'

UNION ALL

-- 12. Value Lists → Fields (Primärfeld). Link_Subrole = 'primary'.
SELECT
    ovl.VL_UUID as Source_UUID,
    'ValueList' as Source_Type,
    ovl.Field_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'source_field' as Link_Role,
    'primary' as Link_Subrole,
    ovl.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (ovl.File_Name != oc_target.File_Name) as Is_Cross_File
FROM OptionsForValueLists ovl
LEFT JOIN ObjectCatalog oc_target ON ovl.Field_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Field'
WHERE ovl.Field_UUID IS NOT NULL

UNION ALL

-- 12b. Value Lists → Fields (Zweitfeld, „auch aus zweitem Feld anzeigen"/Sortierung).
-- Echte Feldabhängigkeit → source_field mit Link_Subrole = 'secondary' (bzw.
-- 'secondary_sort' wenn nach dem Zweitfeld sortiert wird). Schließt die Where-used-Lücke
-- für Felder, die nur als Werteliste-Anzeige-/Sortierfeld dienen.
SELECT
    ovl.VL_UUID as Source_UUID,
    'ValueList' as Source_Type,
    ovl.Secondary_Field_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'source_field' as Link_Role,
    CASE WHEN ovl.Secondary_Sort THEN 'secondary_sort' ELSE 'secondary' END as Link_Subrole,
    ovl.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (ovl.File_Name != oc_target.File_Name) as Is_Cross_File
FROM OptionsForValueLists ovl
LEFT JOIN ObjectCatalog oc_target ON ovl.Secondary_Field_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Field'
WHERE ovl.Secondary_Field_UUID IS NOT NULL

UNION ALL

-- 13. Value Lists → Table Occurrences
SELECT
    ovl.VL_UUID as Source_UUID,
    'ValueList' as Source_Type,
    ovl.TO_UUID as Target_UUID,
    'TableOccurrence' as Target_Type,
    'operational' as Link_Type,
    'source_table' as Link_Role,
    NULL as Link_Subrole,
    ovl.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (ovl.File_Name != oc_target.File_Name) as Is_Cross_File
FROM OptionsForValueLists ovl
LEFT JOIN ObjectCatalog oc_target ON ovl.TO_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'TableOccurrence'
WHERE ovl.TO_UUID IS NOT NULL

UNION ALL

-- 13b. Value Lists → Value Lists (External-Quelle, „Werteliste aus anderer Datei")
-- Ein Wrapper mit <Source value="External"> referenziert eine VL einer anderen Datei.
-- Die Ziel-ValueListReference trägt im XML eine LEERE UUID → Auflösung über die
-- Datenquelle (DS_UUID → Zieldatei aus Path/DS_Name) + VL-ID in der Zieldatei
-- (Fallback: VL-Name; beide über arg_min-Aggregate eindeutig gemacht). Nicht
-- auflösbare Ziele (Zieldatei nicht im Korpus) erzeugen KEINEN Link — sie werden
-- vom P6-Check v_check_external_vl_unresolved ausgewiesen, nicht verschluckt.
-- Schließt die Where-used-Lücke der Ziel-VL in ihrer Heimatdatei (erschien als
-- ungenutzt, obwohl eine andere Datei sie als External-Quelle einbindet).
SELECT
    ext.VL_UUID as Source_UUID,
    'ValueList' as Source_Type,
    ext.target_vl_uuid as Target_UUID,
    'ValueList' as Target_Type,
    'operational' as Link_Type,
    'source_valuelist' as Link_Role,
    NULL as Link_Subrole,
    ext.File_Name as Source_File,
    ext.target_file as Target_File,
    (ext.File_Name != ext.target_file) as Is_Cross_File
FROM (
    SELECT o.VL_UUID, o.File_Name, t.target_file,
           COALESCE(vid.VL_UUID, vnm.VL_UUID) AS target_vl_uuid
    FROM OptionsForValueLists o
    LEFT JOIN ExternalDataSourceCatalog eds
           ON eds.DS_UUID = o.External_DS_UUID AND eds.File_Name = o.File_Name
    -- Zieldatei aus dem DS-Pfad: erste Pfadzeile, letztes Segment (deckt file:/fmnet:/
    -- filemac:-Formen ab), .fmp12-Suffix strippen; Fallback DS-Name (≙ Dateiname).
    CROSS JOIN LATERAL (
        SELECT COALESCE(
                 NULLIF(regexp_replace(regexp_extract(regexp_extract(COALESCE(eds.Path, ''), '^[^\n]+', 0), '[^/:]+$', 0), '\.fmp12$', ''), ''),
                 eds.DS_Name,
                 o.External_DS_Name
               ) AS target_file
    ) t
    LEFT JOIN (SELECT File_Name, VL_ID, arg_min(VL_UUID, VL_UUID) AS VL_UUID
               FROM ValueListCatalog GROUP BY File_Name, VL_ID) vid
           ON vid.File_Name = t.target_file AND vid.VL_ID = o.External_VL_ID
    LEFT JOIN (SELECT File_Name, VL_Name, arg_min(VL_UUID, VL_UUID) AS VL_UUID
               FROM ValueListCatalog GROUP BY File_Name, VL_Name) vnm
           ON vnm.File_Name = t.target_file AND vnm.VL_Name = o.External_VL_Name
    WHERE o.Source_Type = 'External'
) ext
WHERE ext.target_vl_uuid IS NOT NULL

UNION ALL

-- 13c. Value Lists → External Data Sources (External-Quelle: benutzte Datenquelle)
-- Der External-Wrapper hängt an einer Datenquelle (DataSourceReference) — Rolle
-- 'data_source' wie bei TableOccurrence → ExternalDataSource. Schließt die
-- EDS-Where-used-Lücke für Datenquellen, die nur von Wertelisten genutzt werden.
SELECT
    ovl.VL_UUID as Source_UUID,
    'ValueList' as Source_Type,
    ovl.External_DS_UUID as Target_UUID,
    'ExternalDataSource' as Target_Type,
    'operational' as Link_Type,
    'data_source' as Link_Role,
    NULL as Link_Subrole,
    ovl.File_Name as Source_File,
    COALESCE(oc_target.File_Name, ovl.File_Name) as Target_File,
    (ovl.File_Name != COALESCE(oc_target.File_Name, ovl.File_Name)) as Is_Cross_File
FROM OptionsForValueLists ovl
LEFT JOIN ObjectCatalog oc_target ON ovl.External_DS_UUID = oc_target.Object_UUID
   AND oc_target.File_Name = ovl.File_Name AND oc_target.Object_Type = 'ExternalDataSource'
WHERE ovl.Source_Type = 'External' AND ovl.External_DS_UUID IS NOT NULL

UNION ALL

-- 14. Custom Functions → Custom Functions (via CalcsForCustomFunctions)
-- HINWEIS: Keine direkte Verknüpfung in diesem Schema, könnte über DDR_Calculations analysiert werden

-- 15. Script → Script (Perform Script Steps)
-- Extrahiert aus XMLStepReferences (Python XML-Extraktor, umgeht webbed JSON-Bugs).
-- Link_Subrole trägt den PSoS-Ausführungskontext (Schema 1.20.0): 'on_server'
-- (Step 164) / 'on_server_callback' (Step 210) — das Ziel läuft server-seitig.
-- Bewusst Subrole statt eigener Rolle: calls_script bleibt die eine Aufruf-
-- Rolle für alle Konsumenten (where-used, Call-Chains, Graph), der Kontext ist
-- ein Qualifier wie Condition_1/Hide. Step-ID via Step-Join, weil
-- XMLStepReferences keine Step_ID trägt (Muster wie Block 16). Kein Step-Match
-- (theoretisch) → Subrole NULL = gewöhnlicher Aufruf, nie falsch-positiv.
SELECT
    xsr.Script_UUID as Source_UUID,
    'Script' as Source_Type,
    xsr.Ref_UUID as Target_UUID,
    'Script' as Target_Type,
    'operational' as Link_Type,
    'calls_script' as Link_Role,
    CASE sfs.Step_ID
        WHEN 164 THEN 'on_server'
        WHEN 210 THEN 'on_server_callback'
    END as Link_Subrole,
    xsr.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (xsr.File_Name != oc_target.File_Name) as Is_Cross_File
FROM XMLStepReferences xsr
LEFT JOIN (SELECT DISTINCT Step_UUID, Script_UUID, File_Name, Step_ID
           FROM StepsForScripts) sfs
       ON sfs.Step_UUID = xsr.Step_UUID
      AND sfs.Script_UUID = xsr.Script_UUID
      AND sfs.File_Name = xsr.File_Name
LEFT JOIN ObjectCatalog oc_target ON xsr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Script'
WHERE xsr.Ref_Type = 'script'

UNION ALL

-- 16. Script → Field (alle Step-Typen mit FieldReference)
-- Extrahiert aus XMLStepReferences. Link-Rolle LOCALE-UNABHÄNGIG über die
-- Step-ID via ScriptStepRoleMap (Definition + Doku oberhalb des CTAS):
-- die frühere Step_Name-CASE-Liste schickte lokalisierte Exporte (deutsche
-- Step-Namen) komplett in den references_field-Fallback. Step_ID kommt über
-- den Step-Join — XMLStepReferences trägt keine Step_ID; (Step_UUID,
-- Script_UUID, File_Name) löst im Korpus 100 % auf. DISTINCT-Projektion als
-- Fan-out-Schutz gegen Merge-Artefakt-Dubletten (BrojDva-Klasse).
--   references_field — Fallback für nicht gemappte Step-Typen (P6-Wächter)
SELECT
    xsr.Script_UUID as Source_UUID,
    'Script' as Source_Type,
    xsr.Ref_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    COALESCE(rm.Link_Role, 'references_field') as Link_Role,
    NULL as Link_Subrole,
    xsr.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (xsr.File_Name != oc_target.File_Name) as Is_Cross_File
FROM XMLStepReferences xsr
LEFT JOIN (SELECT DISTINCT Step_UUID, Script_UUID, File_Name, Step_ID
           FROM StepsForScripts) sfs
       ON sfs.Step_UUID = xsr.Step_UUID
      AND sfs.Script_UUID = xsr.Script_UUID
      AND sfs.File_Name = xsr.File_Name
LEFT JOIN ScriptStepRoleMap rm ON rm.Step_ID = sfs.Step_ID
LEFT JOIN ObjectCatalog oc_target ON xsr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Field'
WHERE xsr.Ref_Type = 'field'

UNION ALL

-- 18. Script Triggers → Scripts
SELECT
    -- Owner_UUID muss im Source_UUID stehen, damit der Link zum ObjectCatalog-
    -- Eintrag passt (dort Block 18: Trigger_ID_Owner_UUID_File_Name). Ohne Owner
    -- (a) matcht der Link keinen Katalog-Eintrag → Trigger-Detail findet keine
    -- Referenz, und (b) kollabieren Object-Level-Trigger gleicher Trigger_ID auf
    -- eine UUID (derselbe Kollaps wie der ScriptTriggers-PK-Bug, eine Ebene tiefer).
    'trig_' || st.Trigger_ID::VARCHAR || '_' || st.Owner_UUID || '_' || st.File_Name as Source_UUID,
    'ScriptTrigger' as Source_Type,
    st.Script_UUID as Target_UUID,
    'Script' as Target_Type,
    'operational' as Link_Type,
    'trigger_script' as Link_Role,
    NULL as Link_Subrole,
    st.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (st.File_Name != oc_target.File_Name) as Is_Cross_File
FROM ScriptTriggers st
LEFT JOIN ObjectCatalog oc_target ON st.Script_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Script'

UNION ALL

-- 18b. Script Triggers → Owner (Layout / LayoutObject / File)
-- Rückwärts-navigierbare Kante
-- vom Trigger-Knoten auf seinen Owner (child→parent, wie parent_layout/
-- parent_object/parent_script). Source_UUID identisch zu Block 18 (= Katalog-
-- UUID des Triggers). Link_Subrole trägt den Trigger-Typ, sodass "alle
-- OnObjectSave-Trigger eines Layouts" ohne JOIN auf ScriptTriggers geht.
-- Der IS-NOT-NULL-Guard verhindert verwaiste Links für unauflösbare Owner
-- (aktuell die 78 PopoverPanel-Owner — Parser-Folge-Ticket).
SELECT
    'trig_' || st.Trigger_ID::VARCHAR || '_' || st.Owner_UUID || '_' || st.File_Name as Source_UUID,
    'ScriptTrigger' as Source_Type,
    st.Owner_UUID as Target_UUID,
    st.Owner_Type as Target_Type,
    'structural' as Link_Type,
    'trigger_owner' as Link_Role,
    st.Trigger_Action as Link_Subrole,
    st.File_Name as Source_File,
    oc_owner.File_Name as Target_File,
    FALSE as Is_Cross_File
FROM ScriptTriggers st
-- Clone-Scoping: ein Trigger-Owner (Layout/
-- LayoutObject/File) liegt IMMER in derselben Datei wie der Trigger. Ohne
-- File_Name-Scope matcht eine geteilte Owner_UUID (geklonte Module) zusätzlich
-- die Owner-Schatten der Schwester-Module → mehrfache/fehlattribuierte Kanten.
-- Auf einem Nicht-Klon-Korpus ist die Bedingung ein No-Op (UUID global eindeutig).
LEFT JOIN ObjectCatalog oc_owner
    ON st.Owner_UUID = oc_owner.Object_UUID
   AND oc_owner.File_Name = st.File_Name
WHERE oc_owner.Object_UUID IS NOT NULL

UNION ALL

-- 18c. Script Trigger → Transaktions-Parameterfeld (Namens-Kandidaten)
-- OnWindowTransaction-Attribut scriptParameterFieldName: reine Namens-Referenz
-- ohne Tabellen-Qualifizierung, von FileMaker zur Laufzeit je auslösender
-- Tabelle spät gebunden — eine deterministische 1:1-Kante ist prinzipiell
-- unmöglich. Stattdessen KANDIDATEN-Kanten: eine je gleichnamigem Feld der
-- EIGENEN Datei (file-lokale Fächerung = dokumentierte Modellgrenze; cross-file
-- wäre Raterei). Join über FieldsForTables.Field_Name (unqualifiziert —
-- ObjectCatalog.Object_Name ist 'Tabelle::Feld' und matcht den Roh-Namen nie);
-- Field_UUID == ObjectCatalog-UUID des Felds. Ein verwaister Name (0
-- Kandidaten, z.B. nach Feld-Umbenennung) ist ein legitimer Lösungszustand —
-- Report-View v_report_trigger_parameter_fields (P6), bewusst kein FAIL-Gate.
SELECT
    'trig_' || st.Trigger_ID::VARCHAR || '_' || st.Owner_UUID || '_' || st.File_Name as Source_UUID,
    'ScriptTrigger' as Source_Type,
    ft.Field_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'reads_field' as Link_Role,
    'transaction_parameter_field' as Link_Subrole,
    st.File_Name as Source_File,
    ft.File_Name as Target_File,
    FALSE as Is_Cross_File
FROM ScriptTriggers st
JOIN FieldsForTables ft
    ON ft.Field_Name = st.Trigger_ScriptParameter_FieldName
   AND ft.File_Name  = st.File_Name
WHERE NULLIF(st.Trigger_ScriptParameter_FieldName, '') IS NOT NULL

UNION ALL

-- 19. Accounts → Privilege Sets
SELECT
    ac.Account_UUID as Source_UUID,
    'Account' as Source_Type,
    (SELECT PrivilegeSet_UUID FROM PrivilegeSetsCatalog WHERE PrivilegeSet_Name = ac.PrivilegeSet_Name AND File_Name = ac.File_Name LIMIT 1) as Target_UUID,
    'PrivilegeSet' as Target_Type,
    'operational' as Link_Type,
    'privilege_set' as Link_Role,
    NULL as Link_Subrole,
    ac.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (ac.File_Name != oc_target.File_Name) as Is_Cross_File
FROM AccountsCatalog ac
LEFT JOIN ObjectCatalog oc_target ON (SELECT PrivilegeSet_UUID FROM PrivilegeSetsCatalog WHERE PrivilegeSet_Name = ac.PrivilegeSet_Name AND File_Name = ac.File_Name LIMIT 1) = oc_target.Object_UUID AND oc_target.Object_Type = 'PrivilegeSet'

UNION ALL

-- 20. LayoutObject → Field (Edit Box, Drop-down List, etc.)
-- Extrahiert aus XMLLayoutReferences (Python XML-Extraktor, umgeht webbed JSON-Bugs)
SELECT
    xlr.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    xlr.Ref_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'displays_field' as Link_Role,
    NULL as Link_Subrole,
    xlr.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (xlr.File_Name != oc_target.File_Name) as Is_Cross_File
FROM XMLLayoutReferences xlr
LEFT JOIN ObjectCatalog oc_target ON xlr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Field'
-- Kein displays_field aus NULL-UUID (unaufgelöste externe-TO-Feldref) — sonst Orphan-Link
WHERE xlr.Ref_Type = 'field' AND xlr.Ref_UUID IS NOT NULL

UNION ALL

-- 21. Owner → Script (Trigger-Spiegel + Button/GroupedButton/PopoverButton Actions)
-- Owner-granulare Where-used-Kanten: EINE Rolle (triggers_script) für beide
-- Auslöser-Arten, der Subrole-Wert diskriminiert (Event vs. 'button_action').
-- Seit 2.17.0 symmetrisch über ALLE DREI Owner-Ebenen (LayoutObject/Layout/File)
-- — die Spiegel sind die einzige zählende Where-used-Wahrheit (LinkRoleRegistry:
-- trigger_script zählt nicht mehr); Invariante je Ebene: 1 Spiegel ⇔ 1
-- ScriptTriggers-Zeile mit Script ⇔ 1 Trigger-Knoten (P6:
-- v_check_trigger_mirror_symmetry).
-- Objekt-Ebene: zwei UNION-Teile, Gesamt-Kantenzahl je Gruppe (Object_UUID,
-- File_Name, Script_UUID) bleibt r (= XMLLayoutReferences-Zeilen mit
-- Ref_Type='script'). Die Quell-Zeilen tragen KEINEN direkten Diskriminator
-- Trigger vs. Button (Step_ID dort immer NULL); die Aufteilung ist als Multiset
-- deterministisch rekonstruierbar über die korpusverifizierte Invariante t ≤ r:
-- t Kanten aus ScriptTriggers (Subrole = Event), r−t Kanten als 'button_action'.
-- Die Attribution gilt je Gruppe als Multiset, nicht zeilen-identisch.
-- Layout-/File-Ebene: KEIN Multiset nötig — dort existieren keine Button-
-- Actions, jede ScriptTriggers-Zeile ist eindeutig ein Trigger (21b bleibt
-- darum LayoutObject-gebunden).
-- 21a. Trigger-Kanten: eine je ScriptTriggers-Zeile, Source = Owner (Typ aus
--      Owner_Type); Link_Subrole = Trigger_Action (kanonisches Event;
--      Roh-Passthrough wie trigger_owner in Block 18b — ein Locale-Leak der
--      Quelle fließt roh mit).
SELECT
    st.Owner_UUID as Source_UUID,
    st.Owner_Type as Source_Type,
    st.Script_UUID as Target_UUID,
    'Script' as Target_Type,
    'operational' as Link_Type,
    'triggers_script' as Link_Role,
    st.Trigger_Action as Link_Subrole,
    st.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (st.File_Name != oc_target.File_Name) as Is_Cross_File
FROM ScriptTriggers st
LEFT JOIN ObjectCatalog oc_target ON st.Script_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Script'
WHERE st.Owner_Type IN ('LayoutObject', 'Layout', 'File') AND st.Script_UUID IS NOT NULL

UNION ALL

-- 21b. Button-Rest: XMLLayoutReferences-Script-Zeilen (Python XML-Extraktor,
--      findet auch GroupedButton), je Gruppe die ersten t Zeilen verworfen
--      (t = Trigger-Anzahl der Gruppe aus 21a) — die Gruppen-Zeilen sind als
--      Kanten-Payload identisch, daher braucht ROW_NUMBER kein ORDER BY.
--      Gruppen ohne ScriptTriggers-Zeilen (coalesce 0) bleiben komplett.
SELECT
    x.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    x.Ref_UUID as Target_UUID,
    'Script' as Target_Type,
    'operational' as Link_Type,
    'triggers_script' as Link_Role,
    'button_action' as Link_Subrole,
    x.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (x.File_Name != oc_target.File_Name) as Is_Cross_File
FROM (
    SELECT xlr.Object_UUID, xlr.Ref_UUID, xlr.File_Name,
           ROW_NUMBER() OVER (PARTITION BY xlr.Object_UUID, xlr.File_Name, xlr.Ref_UUID) as rn
    FROM XMLLayoutReferences xlr
    WHERE xlr.Ref_Type = 'script'
) x
LEFT JOIN (
    SELECT Owner_UUID, File_Name, Script_UUID, count(*) as t
    FROM ScriptTriggers
    WHERE Owner_Type = 'LayoutObject' AND Script_UUID IS NOT NULL
    GROUP BY ALL
) tt ON tt.Owner_UUID = x.Object_UUID AND tt.File_Name = x.File_Name AND tt.Script_UUID = x.Ref_UUID
LEFT JOIN ObjectCatalog oc_target ON x.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Script'
WHERE x.rn > coalesce(tt.t, 0)

UNION ALL

-- 22. LayoutObject → ValueList (Field Display)
-- Extrahiert aus XMLLayoutReferences (Ref_Type = 'valuelist')
SELECT
    xlr.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    xlr.Ref_UUID as Target_UUID,
    'ValueList' as Target_Type,
    'operational' as Link_Type,
    'uses_valuelist' as Link_Role,
    NULL as Link_Subrole,
    xlr.File_Name as Source_File,
    COALESCE(oc_target.File_Name, xlr.File_Name) as Target_File,
    (xlr.File_Name != COALESCE(oc_target.File_Name, xlr.File_Name)) as Is_Cross_File
FROM XMLLayoutReferences xlr
LEFT JOIN ObjectCatalog oc_target ON xlr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'ValueList'
WHERE xlr.Ref_Type = 'valuelist'

UNION ALL

-- 22b. LayoutObject → ValueList (Custom-Sortierung: Portal-Sort / button-eingebetteter Sort-Step)
-- Extrahiert aus XMLLayoutReferences (Ref_Type = 'valuelist_sort'; P2-Block mit am
-- besitzenden Objekt verankerten Pfaden). Gleiche Rolle wie der Script-Fall (Block 24c),
-- die Source_Type-Spalte unterscheidet den Träger; Link_Subrole = 'portal'/'button'
-- (aus LayoutObjects.Object_Type). DISTINCT: mehrere Custom-Sort-Kriterien desselben
-- Objekts können dieselbe Werteliste referenzieren.
SELECT DISTINCT
    xlr.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    xlr.Ref_UUID as Target_UUID,
    'ValueList' as Target_Type,
    'operational' as Link_Type,
    'sorts_by_valuelist' as Link_Role,
    CASE WHEN lo.Object_Type = 'Portal' THEN 'portal' ELSE 'button' END as Link_Subrole,
    xlr.File_Name as Source_File,
    COALESCE(oc_target.File_Name, xlr.File_Name) as Target_File,
    (xlr.File_Name != COALESCE(oc_target.File_Name, xlr.File_Name)) as Is_Cross_File
FROM XMLLayoutReferences xlr
LEFT JOIN LayoutObjects lo ON lo.Object_UUID = xlr.Object_UUID AND lo.File_Name = xlr.File_Name
LEFT JOIN ObjectCatalog oc_target ON xlr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'ValueList'
WHERE xlr.Ref_Type = 'valuelist_sort'

UNION ALL

-- 23. Portal → TableOccurrence (Portal Data Source)
-- Extrahiert aus XMLLayoutReferences (Ref_Type = 'table_occurrence')
SELECT
    xlr.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    xlr.Ref_UUID as Target_UUID,
    'TableOccurrence' as Target_Type,
    'operational' as Link_Type,
    'portal_context' as Link_Role,
    NULL as Link_Subrole,
    xlr.File_Name as Source_File,
    COALESCE(oc_target.File_Name, xlr.File_Name) as Target_File,
    (xlr.File_Name != COALESCE(oc_target.File_Name, xlr.File_Name)) as Is_Cross_File
FROM XMLLayoutReferences xlr
LEFT JOIN ObjectCatalog oc_target ON xlr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'TableOccurrence'
WHERE xlr.Ref_Type = 'table_occurrence'

UNION ALL

-- 23b. LayoutObject → Layout (button-eingebetteter Go-to-Layout-/GTRR-Step) — F-2
-- Extrahiert aus XMLLayoutReferences (Ref_Type = 'layout_step'; P2-Block mit am
-- besitzenden Button verankertem action/Step-Pfad). WIEDERVERWENDETE Rolle: gleiche
-- navigates_to_layout wie der Script-Fall (Block 24), die Source_Type-Spalte
-- unterscheidet den Träger. Ohne diese Regel erschien ein nur per Button erreichbares
-- Layout in unused_layout als False Positive.
SELECT
    xlr.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    xlr.Ref_UUID as Target_UUID,
    'Layout' as Target_Type,
    'operational' as Link_Type,
    'navigates_to_layout' as Link_Role,
    NULL as Link_Subrole,
    xlr.File_Name as Source_File,
    COALESCE(oc_target.File_Name, xlr.File_Name) as Target_File,
    (xlr.File_Name != COALESCE(oc_target.File_Name, xlr.File_Name)) as Is_Cross_File
FROM XMLLayoutReferences xlr
LEFT JOIN ObjectCatalog oc_target ON xlr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Layout'
WHERE xlr.Ref_Type = 'layout_step'

UNION ALL

-- 23c. LayoutObject → TableOccurrence (button-eingebetteter GTRR-Ziel-TO) — F-2
-- Extrahiert aus XMLLayoutReferences (Ref_Type = 'table_occurrence_step'). Gleiche
-- Lückenklasse und WIEDERVERWENDETE Rolle wie der Script-GTRR-Fall (Block 24b):
-- navigates_to_to. Ein TO, das nur als Button-GTRR-Sprungziel dient, erschien sonst
-- als ungenutzt.
SELECT
    xlr.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    xlr.Ref_UUID as Target_UUID,
    'TableOccurrence' as Target_Type,
    'operational' as Link_Type,
    'navigates_to_to' as Link_Role,
    NULL as Link_Subrole,
    xlr.File_Name as Source_File,
    COALESCE(oc_target.File_Name, xlr.File_Name) as Target_File,
    (xlr.File_Name != COALESCE(oc_target.File_Name, xlr.File_Name)) as Is_Cross_File
FROM XMLLayoutReferences xlr
LEFT JOIN ObjectCatalog oc_target ON xlr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'TableOccurrence'
WHERE xlr.Ref_Type = 'table_occurrence_step'

UNION ALL

-- 23d. LayoutObject → Field (button-eingebetteter Set-Field-/Go-to-Field-/Sort-Step) — F-2
-- Extrahiert aus XMLLayoutReferences (Ref_Type = 'field_step'; FieldReference unter
-- ParameterValues). Link-Rolle LOCALE-UNABHÄNGIG über die mitgeführte Step-ID via
-- ScriptStepRoleMap — dieselbe kuratierte Zuordnung wie der Script→Field-Block (16),
-- die Source_Type-Spalte unterscheidet den Träger (LayoutObject statt Script). Nicht
-- gemappte Step-Typen → Fallback references_field (registrierte Rolle → v_check_link_roles
-- bleibt 0). DISTINCT als Fan-out-Schutz (mehrere identische Feld-Refs möglich).
SELECT DISTINCT
    xlr.Object_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    xlr.Ref_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    COALESCE(rm.Link_Role, 'references_field') as Link_Role,
    NULL as Link_Subrole,
    xlr.File_Name as Source_File,
    -- COALESCE wie die Schwester-Blöcke 23b/23c — unaufgelöste Ziele (Feld nicht im
    -- Katalog: gelöscht/Teil-Korpus) erhalten Target_File = Quelldatei statt NULL und
    -- Is_Cross_File = FALSE statt NULL (Konsistenz; die P4-End-Bereinigung fing bisher nur
    -- Is_Cross_File ab, Target_File blieb NULL).
    COALESCE(oc_target.File_Name, xlr.File_Name) as Target_File,
    (xlr.File_Name != COALESCE(oc_target.File_Name, xlr.File_Name)) as Is_Cross_File
FROM XMLLayoutReferences xlr
LEFT JOIN ScriptStepRoleMap rm ON rm.Step_ID = xlr.Step_ID
LEFT JOIN ObjectCatalog oc_target ON xlr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Field'
WHERE xlr.Ref_Type = 'field_step'

UNION ALL

-- 24. Script → Layout (Go to Layout Steps)
-- Extrahiert aus XMLStepReferences (Ref_Type = 'layout')
SELECT
    xsr.Script_UUID as Source_UUID,
    'Script' as Source_Type,
    xsr.Ref_UUID as Target_UUID,
    'Layout' as Target_Type,
    'operational' as Link_Type,
    'navigates_to_layout' as Link_Role,
    NULL as Link_Subrole,
    xsr.File_Name as Source_File,
    COALESCE(oc_target.File_Name, xsr.File_Name) as Target_File,
    (xsr.File_Name != COALESCE(oc_target.File_Name, xsr.File_Name)) as Is_Cross_File
FROM XMLStepReferences xsr
LEFT JOIN ObjectCatalog oc_target ON xsr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'Layout'
WHERE xsr.Ref_Type = 'layout'

UNION ALL

-- 24b. Script → TableOccurrence (Go to Related Record — Sprungziel-TO)
-- Extrahiert aus XMLStepReferences (Ref_Type = 'tableOccurrence'). GTRR legt das
-- Bezugs-TO als <TableOccurrenceReference> ab; ohne diese Regel verpuffte die Referenz
-- komplett (kein Konsument für Ref_Type='tableOccurrence') — ein TO, das nur als
-- GTRR-Sprungziel dient, erschien dadurch in Where-used/Dead-Code als ungenutzt.
-- Rolle analog zu navigates_to_field/navigates_to_layout. TO-UUIDs sind in
-- ObjectCatalog eindeutig (keine Klon-Mehrfachtreffer → kein Row-Multiply); COALESCE
-- fängt das seltene datei-externe (nicht importierte) Sprungziel als Nicht-Cross-File ab.
SELECT
    xsr.Script_UUID as Source_UUID,
    'Script' as Source_Type,
    xsr.Ref_UUID as Target_UUID,
    'TableOccurrence' as Target_Type,
    'operational' as Link_Type,
    'navigates_to_to' as Link_Role,
    NULL as Link_Subrole,
    xsr.File_Name as Source_File,
    COALESCE(oc_target.File_Name, xsr.File_Name) as Target_File,
    (xsr.File_Name != COALESCE(oc_target.File_Name, xsr.File_Name)) as Is_Cross_File
FROM XMLStepReferences xsr
LEFT JOIN ObjectCatalog oc_target ON xsr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'TableOccurrence'
WHERE xsr.Ref_Type = 'tableOccurrence'

UNION ALL

-- 24c. Script → ValueList (Sort Records — Custom-Sortierung nach Werteliste)
-- Extrahiert aus XMLStepReferences (Ref_Type = 'valuelist'). Eine „Custom sort
-- order" kann nach einer Werteliste sortieren (<Sort type="Custom"> mit
-- <ValueListReference>). Ohne diese Regel erschien eine Werteliste, die NUR als
-- Sortier-Referenz dient, in Where-used/Dead-Code als ungenutzt (gleiche
-- Lückenklasse wie das GTRR-TO-/New-Window-Layout-Loch). Rolle analog zu
-- sorts_by_field (das Sortier-Feld wird bereits über Block 16 verlinkt).
SELECT
    xsr.Script_UUID as Source_UUID,
    'Script' as Source_Type,
    xsr.Ref_UUID as Target_UUID,
    'ValueList' as Target_Type,
    'operational' as Link_Type,
    'sorts_by_valuelist' as Link_Role,
    NULL as Link_Subrole,
    xsr.File_Name as Source_File,
    COALESCE(oc_target.File_Name, xsr.File_Name) as Target_File,
    (xsr.File_Name != COALESCE(oc_target.File_Name, xsr.File_Name)) as Is_Cross_File
FROM XMLStepReferences xsr
LEFT JOIN ObjectCatalog oc_target ON xsr.Ref_UUID = oc_target.Object_UUID AND oc_target.Object_Type = 'ValueList'
WHERE xsr.Ref_Type = 'valuelist'

UNION ALL

-- 25. Field → Field (Lookup-Quelle)
-- Link: Zielfeld hat Lookup auf Quellfeld
SELECT
    f.Field_UUID as Source_UUID,
    'Field' as Source_Type,
    f.Lookup_Field_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'lookup_source' as Link_Role,
    NULL as Link_Subrole,
    f.File_Name as Source_File,
    COALESCE(oc_target.File_Name, f.File_Name) as Target_File,
    (f.File_Name != COALESCE(oc_target.File_Name, f.File_Name)) as Is_Cross_File
FROM FieldsForTables f
-- Clone-Scoping „prefer-local-else-home": ein Lookup-Quellfeld
-- liegt MEIST in derselben Datei, kann aber legitim datei-übergreifend sein
-- (z. B. eine zentrale Daten-Datei). Hartes File_Name=-Scoping wäre falsch
-- (killte die legitimen Cross-File-Lookups). Stattdessen: existiert eine
-- gleichdateiliche Ziel-Kopie, gewinnt sie; sonst die (deterministisch erste)
-- Cross-File-Kopie. Der Object_Type-Guard verhindert UUID-Kollision mit Nicht-Feldern.
LEFT JOIN ObjectCatalog oc_target
    ON f.Lookup_Field_UUID = oc_target.Object_UUID
   AND oc_target.Object_Type = 'Field'
WHERE f.AutoEnter_Type = 'Looked_up'
  AND f.Lookup_Field_UUID IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY f.Field_UUID, f.File_Name
    ORDER BY (oc_target.File_Name = f.File_Name) DESC, oc_target.File_Name
  ) = 1

UNION ALL

-- 23. Field → TableOccurrence (Lookup-Beziehung)
-- Link: Zielfeld nutzt diese Beziehung für den Lookup
SELECT
    f.Field_UUID as Source_UUID,
    'Field' as Source_Type,
    f.Lookup_TO_UUID as Target_UUID,
    'TableOccurrence' as Target_Type,
    'operational' as Link_Type,
    'lookup_relationship' as Link_Role,
    NULL as Link_Subrole,
    f.File_Name as Source_File,
    COALESCE(oc_target.File_Name, f.File_Name) as Target_File,
    (f.File_Name != COALESCE(oc_target.File_Name, f.File_Name)) as Is_Cross_File
FROM FieldsForTables f
-- Clone-Scoping „prefer-local-else-home" (analog zu lookup_source, Block 25):
-- die Lookup-Beziehungs-TO liegt meist lokal, kann aber legitim cross-file sein.
-- Gleichdateilige Kopie gewinnt, sonst deterministisch erste Cross-File-Kopie.
LEFT JOIN ObjectCatalog oc_target
    ON f.Lookup_TO_UUID = oc_target.Object_UUID
   AND oc_target.Object_Type = 'TableOccurrence'
WHERE f.AutoEnter_Type = 'Looked_up'
  AND f.Lookup_TO_UUID IS NOT NULL
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY f.Field_UUID, f.File_Name
    ORDER BY (oc_target.File_Name = f.File_Name) DESC, oc_target.File_Name
  ) = 1

UNION ALL

-- ========================================
-- Variable Links (24-29)
-- ========================================

-- 24. Script → Variable (sets_variable)
-- Script setzt eine Variable via Set Variable Schritt
SELECT DISTINCT
    vu.Script_UUID as Source_UUID,
    'Script' as Source_Type,
    md5(vu.Variable_Scope || '::' || vu.Scope_Anchor || '::' || vu.Variable_Name) as Target_UUID,
    'Variable' as Target_Type,
    'operational' as Link_Type,
    'sets_variable' as Link_Role,
    NULL as Link_Subrole,
    vu.File_Name as Source_File,
    vc.File_Name as Target_File,
    CASE WHEN vu.Variable_Scope IN ('local', 'global') THEN FALSE
         ELSE (vu.File_Name != vc.File_Name)
    END as Is_Cross_File
FROM VariableUsages vu
JOIN VariablesCatalog vc
    ON vu.Variable_Name  = vc.Variable_Name
   AND vu.Variable_Scope = vc.Variable_Scope
   AND vu.Scope_Anchor   = vc.Scope_Anchor
WHERE vu.Usage_Type = 'set'
  AND vu.Context_Type = 'script_step'
  AND vu.Variable_Scope IN ('global', 'local', 'superglobal')
  AND vu.Script_UUID IS NOT NULL

UNION ALL

-- 25. Script → Variable (reads_variable)
-- Script-Formel referenziert eine Variable
SELECT DISTINCT
    vu.Script_UUID as Source_UUID,
    'Script' as Source_Type,
    md5(vu.Variable_Scope || '::' || vu.Scope_Anchor || '::' || vu.Variable_Name) as Target_UUID,
    'Variable' as Target_Type,
    'operational' as Link_Type,
    'reads_variable' as Link_Role,
    NULL as Link_Subrole,
    vu.File_Name as Source_File,
    vc.File_Name as Target_File,
    CASE WHEN vu.Variable_Scope IN ('local', 'global') THEN FALSE
         ELSE (vu.File_Name != vc.File_Name)
    END as Is_Cross_File
FROM VariableUsages vu
JOIN VariablesCatalog vc
    ON vu.Variable_Name  = vc.Variable_Name
   AND vu.Variable_Scope = vc.Variable_Scope
   AND vu.Scope_Anchor   = vc.Scope_Anchor
WHERE vu.Usage_Type = 'read'
  AND vu.Context_Type = 'script_step'
  AND vu.Variable_Scope IN ('global', 'local', 'superglobal')
  AND vu.Script_UUID IS NOT NULL

UNION ALL

-- 26. Field → Variable (reads_variable)
-- Calculated/AutoEnter-Formel referenziert eine Variable
SELECT DISTINCT
    vu.Context_UUID as Source_UUID,
    'Field' as Source_Type,
    md5(vu.Variable_Scope || '::' || vu.Scope_Anchor || '::' || vu.Variable_Name) as Target_UUID,
    'Variable' as Target_Type,
    'operational' as Link_Type,
    'reads_variable' as Link_Role,
    NULL as Link_Subrole,
    vu.File_Name as Source_File,
    vc.File_Name as Target_File,
    CASE WHEN vu.Variable_Scope IN ('local', 'global') THEN FALSE
         ELSE (vu.File_Name != vc.File_Name)
    END as Is_Cross_File
FROM VariableUsages vu
JOIN VariablesCatalog vc
    ON vu.Variable_Name  = vc.Variable_Name
   AND vu.Variable_Scope = vc.Variable_Scope
   AND vu.Scope_Anchor   = vc.Scope_Anchor
WHERE vu.Usage_Type = 'read'
  AND vu.Context_Type IN ('calculation', 'auto_enter_calc')
  AND vu.Variable_Scope IN ('global', 'local', 'superglobal')
  AND vu.Context_UUID IS NOT NULL

UNION ALL

-- 27. CustomFunction → Variable (reads_variable / sets_variable)
-- CF-Formel referenziert oder setzt eine Variable (z.B. MBS Superglobale)
SELECT DISTINCT
    vu.Context_UUID as Source_UUID,
    'CustomFunction' as Source_Type,
    md5(vu.Variable_Scope || '::' || vu.Scope_Anchor || '::' || vu.Variable_Name) as Target_UUID,
    'Variable' as Target_Type,
    'operational' as Link_Type,
    CASE vu.Usage_Type WHEN 'set' THEN 'sets_variable' ELSE 'reads_variable' END as Link_Role,
    NULL as Link_Subrole,
    vu.File_Name as Source_File,
    vc.File_Name as Target_File,
    CASE WHEN vu.Variable_Scope IN ('local', 'global') THEN FALSE
         ELSE (vu.File_Name != vc.File_Name)
    END as Is_Cross_File
FROM VariableUsages vu
JOIN VariablesCatalog vc
    ON vu.Variable_Name  = vc.Variable_Name
   AND vu.Variable_Scope = vc.Variable_Scope
   AND vu.Scope_Anchor   = vc.Scope_Anchor
WHERE vu.Context_Type = 'custom_function'
  AND vu.Variable_Scope IN ('global', 'local', 'superglobal')
  AND vu.Context_UUID IS NOT NULL

UNION ALL

-- 28. LayoutObject → Variable (alle Quellen: Merge, Script-Trigger, DDR-Formeln)
-- merge_variable → displays_variable, alle anderen → reads_variable
SELECT DISTINCT
    vu.Context_UUID as Source_UUID,
    'LayoutObject' as Source_Type,
    md5(vu.Variable_Scope || '::' || vu.Scope_Anchor || '::' || vu.Variable_Name) as Target_UUID,
    'Variable' as Target_Type,
    'operational' as Link_Type,
    CASE vu.Source
        WHEN 'merge_variable' THEN 'displays_variable'
        ELSE 'reads_variable'
    END as Link_Role,
    NULL as Link_Subrole,
    vu.File_Name as Source_File,
    vc.File_Name as Target_File,
    CASE WHEN vu.Variable_Scope IN ('local', 'global') THEN FALSE
         ELSE (vu.File_Name != vc.File_Name)
    END as Is_Cross_File
FROM VariableUsages vu
JOIN VariablesCatalog vc
    ON vu.Variable_Name  = vc.Variable_Name
   AND vu.Variable_Scope = vc.Variable_Scope
   AND vu.Scope_Anchor   = vc.Scope_Anchor
WHERE vu.Context_Type = 'layout_object'
  AND vu.Variable_Scope IN ('global', 'local')
  AND vu.Context_UUID IS NOT NULL

UNION ALL

-- 28b. PrivilegeSet → Variable (reads_variable) — Custom Record Privilege Calc
-- Gespiegelt vom Field-/CF-
-- Pendant (Block 26/27), gefiltert auf den neuen Context_Type. Schließt die
-- Where-Used-Lücke für Variablen, die NUR in einer Record-Access-Calc gelesen
-- werden (z.B. $$__Rechte_Bearbeiten). Record-Calcs lesen nur → immer
-- reads_variable. Source_UUID = Context_UUID = PrivilegeSet_UUID.
--
-- Bidirektional traversierbar: Vorwärts (Set → Variable) via
-- Source_UUID, Rückwärts (Where-Used) via Target_UUID — keine zweite Kante nötig.
-- Link_Subrole bleibt NULL (konsistent mit der reads_variable-Familie 26/27/28);
-- die feinere Operation:Tabelle-Auflösung lebt in VariableUsages.Context_Name.
SELECT DISTINCT
    vu.Context_UUID as Source_UUID,
    'PrivilegeSet' as Source_Type,
    md5(vu.Variable_Scope || '::' || vu.Scope_Anchor || '::' || vu.Variable_Name) as Target_UUID,
    'Variable' as Target_Type,
    'operational' as Link_Type,
    'reads_variable' as Link_Role,
    NULL as Link_Subrole,
    vu.File_Name as Source_File,
    vc.File_Name as Target_File,
    CASE WHEN vu.Variable_Scope IN ('local', 'global') THEN FALSE
         ELSE (vu.File_Name != vc.File_Name)
    END as Is_Cross_File
FROM VariableUsages vu
JOIN VariablesCatalog vc
    ON vu.Variable_Name  = vc.Variable_Name
   AND vu.Variable_Scope = vc.Variable_Scope
   AND vu.Scope_Anchor   = vc.Scope_Anchor
WHERE vu.Context_Type = 'record_access_calc'
  AND vu.Variable_Scope IN ('global', 'local', 'superglobal')
  AND vu.Context_UUID IS NOT NULL

UNION ALL

-- 29. Item/Sub-Folder → Folder (parent_folder, structural)
-- Verbindet Scripts/Layouts mit ihrem direkten Parent-Folder und Sub-Folder mit ihrem Parent-Folder.
-- Source_Type wird aus subtype + Source_Table abgeleitet.
-- Hinweis: parent_folder ist NICHT mit parent_object zu verwechseln — letzteres ist
-- die Layout-interne Objekt-Hierarchie (Group/Tab/Portal-Children).
SELECT
    fh.Source_UUID as Source_UUID,
    CASE
        WHEN fh.subtype = 'Folder' THEN 'Folder'
        WHEN fh.Source_Table = 'ScriptCatalog' THEN 'Script'
        WHEN fh.Source_Table = 'Layouts' THEN 'Layout'
        WHEN fh.Source_Table = 'CustomFunctionsCatalog' THEN 'CustomFunction'
    END as Source_Type,
    fh.Parent_Folder_UUID as Target_UUID,
    'Folder' as Target_Type,
    'structural' as Link_Type,
    'parent_folder' as Link_Role,
    NULL as Link_Subrole,
    fh.File_Name as Source_File,
    fh.File_Name as Target_File,
    FALSE as Is_Cross_File
FROM FolderHierarchy fh
WHERE fh.Parent_Folder_UUID IS NOT NULL
  AND fh.subtype IN ('Folder', 'Item')

UNION ALL

-- ========================================
-- Erweiterte Referenz-Auflösung
-- ========================================

-- 30. Calc-Source → Field (reads_field)
-- Quelle: XMLCalcReferences — alle Field-Referenzen aus DDR-Calc-Chunks.
-- Cross-File ist möglich: der Calc-Chunk liegt in der nutzenden Datei,
-- die Field-UUID kann auf eine andere Datei zeigen.
-- DISTINCT verhindert Aufblähung durch redundante DDRREF-Vorkommen im XML
-- (gleicher Hash kann z.B. in einem Layout 128x referenziert werden, wenn
-- alle Sub-Elemente dieselbe Hide-Calc nutzen). Ein Source-Target-Subrole-
-- Tupel bleibt eindeutig — Mehrfacherwähnung wird kollabiert.
SELECT DISTINCT
    xcr.Source_UUID as Source_UUID,
    xcr.Source_Type as Source_Type,
    xcr.Ref_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    -- Feld-Refs aus einem Validierungs-Calc (Subrole='validation', A.2.7) oder der
    -- Fehlermeldungs-Berechnung (Subrole='validation_message', A.2.10 — seit 1.22.0
    -- eigene Subrole) tragen die eigene Rolle validates_by_calc; alle übrigen
    -- Calc-Feld-Refs bleiben reads_field.
    CASE WHEN xcr.Subrole IN ('validation', 'validation_message') AND xcr.Source_Type = 'Field'
         THEN 'validates_by_calc' ELSE 'reads_field' END as Link_Role,
    xcr.Subrole as Link_Subrole,
    xcr.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (xcr.File_Name != oc_target.File_Name) as Is_Cross_File
FROM XMLCalcReferences xcr
JOIN ObjectCatalog oc_target
  ON xcr.Ref_UUID = oc_target.Object_UUID
 AND oc_target.Object_Type = 'Field'
WHERE xcr.Ref_Type = 'field'
  AND xcr.Ref_UUID IS NOT NULL

UNION ALL

-- 31. Calc-Source → CustomFunction (calls_customfunction)
-- CustomFunctions sind per FileMaker-Definition strikt datei-lokal:
-- Aufrufe können nur innerhalb der definierenden Datei erfolgen, gleichnamige
-- CFs in unterschiedlichen Dateien sind eigenständige Objekte.
-- → File-lokaler JOIN, Is_Cross_File konstant FALSE.
-- DISTINCT analog zu Block 30, kollabiert Mehrfachreferenzen.
SELECT DISTINCT
    xcr.Source_UUID as Source_UUID,
    xcr.Source_Type as Source_Type,
    cf.CF_UUID as Target_UUID,
    'CustomFunction' as Target_Type,
    'operational' as Link_Type,
    -- CF-Refs aus einem Validierungs-Calc (A.2.8) oder der Fehlermeldungs-
    -- Berechnung (A.2.11, Subrole 'validation_message' seit 1.22.0)
    -- → validates_by_calc; sonst calls_customfunction.
    CASE WHEN xcr.Subrole IN ('validation', 'validation_message') AND xcr.Source_Type = 'Field'
         THEN 'validates_by_calc' ELSE 'calls_customfunction' END as Link_Role,
    xcr.Subrole as Link_Subrole,
    xcr.File_Name as Source_File,
    cf.File_Name as Target_File,
    FALSE as Is_Cross_File
FROM XMLCalcReferences xcr
JOIN CustomFunctionsCatalog cf
  ON xcr.Ref_Name = cf.CF_Name
 AND xcr.File_Name = cf.File_Name
WHERE xcr.Ref_Type = 'customfunction'
  AND xcr.Ref_Name IS NOT NULL
  -- Ordner/Trenner sind seit Schema 1.15.0 nicht mehr im ObjectCatalog (Block 6);
  -- ein Namensgleichstand Ordner↔CF würde sonst einen Link auf ein nicht
  -- katalogisiertes Ziel erzeugen (Orphan-Target, v_check_orphan_links).
  AND (cf.Folder_Type IS NULL OR cf.Folder_Type = 'False')
  AND NOT COALESCE(cf.Is_Separator, FALSE)

UNION ALL

-- 32. Layout → Field (displays_field, aggregiert)
-- Aggregierter Direktlink aus dem Doppelhop:
--   LayoutObject → Field (displays_field) + LayoutObject → Layout (parent_layout).
-- Praxis: ein Feld kann auf einem Layout in mehreren LayoutObjects auftauchen
-- (verschiedene Slots, Tab-Panels, Group-Mitglieder). DISTINCT kollabiert das
-- auf das eindeutige (Layout, Field)-Paar.
-- Richtung Layout → Field gewählt (analog zu LayoutObject → Field), damit der
-- Link beim Field als Reverse-Lookup ("Wird verwendet von") automatisch
-- erscheint — parallel zum LayoutObject-granularen displays_field-Link.
-- Source_Type unterscheidet die beiden Granularitäten:
--   'LayoutObject' = einzelnes Element (mit Bounds-Kontext und Subrole)
--   'Layout'       = aggregiert (Layout zeigt Field)
SELECT DISTINCT
    l.L_UUID as Source_UUID,
    'Layout' as Source_Type,
    xlr.Ref_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'displays_field' as Link_Role,
    NULL as Link_Subrole,
    l.File_Name as Source_File,
    oc_field.File_Name as Target_File,
    (l.File_Name != oc_field.File_Name) as Is_Cross_File
FROM XMLLayoutReferences xlr
JOIN LayoutObjects lo
    ON xlr.Object_UUID = lo.Object_UUID
   AND xlr.File_Name   = lo.File_Name
JOIN Layouts l
    ON lo.Layout_ID = l.L_ID
   AND lo.File_Name = l.File_Name
   -- Folder-/Separator-Filter: defensive Parität zum Catalog-Block 9 — Folder
   -- tragen keine LayoutObjects, aber eine ID-Kollision dürfte hier keinen Link erzeugen.
   AND (l.Folder_Type IS NULL OR l.Folder_Type = 'False')
   AND NOT COALESCE(l.Is_Separator, FALSE)
JOIN ObjectCatalog oc_field
    ON xlr.Ref_UUID = oc_field.Object_UUID
   AND oc_field.Object_Type = 'Field'
WHERE xlr.Ref_Type = 'field'
  AND xlr.Ref_UUID IS NOT NULL

UNION ALL

-- 33. Calc-Source → BuiltinFunction (calls_function)
-- Built-in FunctionRef-Aufrufe als
-- Link-Tripel (dedupliziert). Target ist datei-unabhängig → Is_Cross_File=FALSE.
-- Für Get(<SubParameter>) zeigt der Link auf den SubParameter-Eintrag, sonst
-- auf den nackten Token.
SELECT DISTINCT
    xcr.Source_UUID as Source_UUID,
    xcr.Source_Type as Source_Type,
    md5('BuiltinFunction::' ||
        CASE WHEN xcr.Ref_Name = 'Get' AND xcr.Ref_SubName IS NOT NULL
             THEN xcr.Ref_Name || '::' || xcr.Ref_SubName
             ELSE xcr.Ref_Name END
    ) as Target_UUID,
    'BuiltinFunction' as Target_Type,
    'operational' as Link_Type,
    'calls_function' as Link_Role,
    xcr.Subrole as Link_Subrole,
    xcr.File_Name as Source_File,
    NULL as Target_File,
    FALSE as Is_Cross_File
FROM XMLCalcReferences xcr
WHERE xcr.Ref_Type = 'function'
  AND xcr.Ref_Name IS NOT NULL
  AND xcr.Ref_Name != ''

UNION ALL

-- 34. Calc-Source → PluginFunction (calls_pluginfunction)
-- Plugin-Funktionsaufrufe (granular
-- pro Plugin-Token + SubName für Container-Plugins). Source-Tupel kommt aus
-- PluginFunctionUsages (positionsbezogen via Calc_UUID + Plugin_Chunk_Index
-- → MBS_SubnameMap). Dynamische MBS-Aufrufe (SubName NULL) werden ausgefiltert.
-- Target ist datei-unabhängig → Is_Cross_File=FALSE.
SELECT DISTINCT
    pfu.Source_UUID as Source_UUID,
    pfu.Source_Type as Source_Type,
    md5('PluginFunction::' || pfu.Plugin_Function_Name || '::' ||
        COALESCE(msm.SubName, '')) as Target_UUID,
    'PluginFunction' as Target_Type,
    'operational' as Link_Type,
    'calls_pluginfunction' as Link_Role,
    pfu.Subrole as Link_Subrole,
    pfu.File_Name as Source_File,
    NULL as Target_File,
    FALSE as Is_Cross_File
FROM PluginFunctionUsages pfu
LEFT JOIN MBS_SubnameMap msm
  ON msm.Calc_UUID = pfu.Calc_UUID
 AND msm.File_Name = pfu.File_Name
 AND msm.Plugin_Chunk_Index = pfu.Plugin_Chunk_Index
WHERE pfu.Plugin_Function_Name IS NOT NULL
  AND pfu.Plugin_Function_Name != ''
  AND (msm.SubName IS NOT NULL OR pfu.Plugin_Function_Name != 'MBS')

UNION ALL

-- 34b. MBS FM.RunScript → Script (calls_script, AP-5B / D-6)
-- MBS("FM.RunScript"; "<Datei>"; "<Script>"; "<param>") ruft ein Script per NAME auf —
-- die DDR sieht nur ein String-Argument, keine ScriptReference → der Aufruf war im
-- Graphen unsichtbar. Ziel-Script (3. Literal) + Ziel-Datei (2. Literal) werden aus
-- dem Argument-Chunk (Plugin_Chunk_Index + 1) gelesen, entity-dekodiert und gegen
-- ScriptCatalog gebunden. Nur statisch benannte, auflösbare Ziele erzeugen Kanten;
-- dynamische / nicht importierte Ziel-Dateien fallen über den JOIN heraus. Cross-File
-- möglich (Ziel-Datei ist das 2. Argument). Setzt A.10 (Qualifizierung) in P2 voraus.
SELECT DISTINCT
    pfu.Source_UUID as Source_UUID,
    pfu.Source_Type as Source_Type,
    sc.Script_UUID as Target_UUID,
    'Script' as Target_Type,
    'operational' as Link_Type,
    'calls_script' as Link_Role,
    'MBS:FM.RunScript' as Link_Subrole,
    pfu.File_Name as Source_File,
    sc.File_Name as Target_File,
    (pfu.File_Name != sc.File_Name) as Is_Cross_File
FROM PluginFunctionUsages pfu
JOIN DDR_Calculations d
  ON d.Calc_UUID = pfu.Calc_UUID
 AND d.File_Name = pfu.File_Name
 AND d.Chunk_Index = pfu.Plugin_Chunk_Index + 1
JOIN ScriptCatalog sc
  ON sc.Script_Name = html_unescape(regexp_extract(d.Chunk_Content, '"[^"]*"\s*;\s*"([^"]*)"\s*;\s*"([^"]*)"', 2))
 AND sc.File_Name   = html_unescape(regexp_extract(d.Chunk_Content, '"[^"]*"\s*;\s*"([^"]*)"\s*;\s*"([^"]*)"', 1))
 AND (sc.Folder_Type IS NULL OR sc.Folder_Type = 'False')
 AND NOT COALESCE(sc.Is_Separator, FALSE)
WHERE pfu.Plugin_Function_Name = 'MBS:FM.RunScript'

UNION ALL

-- 35. PrivilegeSet → Field (restricts_field)
-- Quelle: PrivilegeSetFieldAccess (Custom Record Privileges, Feld-Ebene).
-- Eigener Link_Role (NICHT reads_field): dies ist eine Zugriffs-EINSCHRÄNKUNG,
-- keine Nutzung. Damit bleibt Where-Used-/Dead-Code-Analyse unberührt — ein für
-- ein Set gesperrtes Feld gilt dadurch NICHT als "genutzt".
-- Scope: nur Abweichungen vom vollen Zugriff (Access_Mode <> 'ReadWrite'), d.h.
-- jede echte Restriktion (NoAccess/ReadOnly); voll-offene Felder erzeugen keine
-- Links (kein Signal, nur Volumen). Link_Subrole trägt den Access-Modus.
-- New-Default-Zeilen fallen über Field_UUID IS NOT NULL automatisch raus.
SELECT DISTINCT
    pfa.PrivilegeSet_UUID as Source_UUID,
    'PrivilegeSet' as Source_Type,
    pfa.Field_UUID as Target_UUID,
    'Field' as Target_Type,
    'operational' as Link_Type,
    'restricts_field' as Link_Role,
    pfa.Access_Mode as Link_Subrole,
    pfa.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (pfa.File_Name != oc_target.File_Name) as Is_Cross_File
FROM PrivilegeSetFieldAccess pfa
JOIN ObjectCatalog oc_target
  ON pfa.Field_UUID = oc_target.Object_UUID
 AND oc_target.Object_Type = 'Field'
WHERE pfa.Field_UUID IS NOT NULL
  AND pfa.Access_Mode <> 'ReadWrite'

UNION ALL

-- 36. PrivilegeSet → Layout/ValueList/Script (restricts_object)
-- Quelle: PrivilegeSetObjectAccess (Custom Privileges, Stufe 3). Analog zu
-- Block 35: eigener Link_Role, nur Restriktionen (Access_Mode <> 'ReadWrite').
-- Target_Type = Object_Class (entspricht direkt den ObjectCatalog-Typen
-- 'Layout'/'ValueList'/'Script'); Link_Subrole trägt den Access-Modus.
-- PrivilegeSets sind datei-lokal → Is_Cross_File praktisch FALSE, wird aber
-- konsistent über den ObjectCatalog-JOIN berechnet.
-- Hinweis: Der Custom-Zugriffsbaum listet auch Folder/Separatoren (mit eigener
-- UUID); diese sind im ObjectCatalog als Typ 'Folder' registriert, nicht als
-- 'Layout'/'Script'/'ValueList'. Der Inner-JOIN auf Object_Type=Object_Class
-- lässt sie daher bewusst weg — Folder-Zugriff ist rein strukturell.
SELECT DISTINCT
    poa.PrivilegeSet_UUID as Source_UUID,
    'PrivilegeSet' as Source_Type,
    poa.Object_UUID as Target_UUID,
    poa.Object_Class as Target_Type,
    'operational' as Link_Type,
    'restricts_object' as Link_Role,
    poa.Access_Mode as Link_Subrole,
    poa.File_Name as Source_File,
    oc_target.File_Name as Target_File,
    (poa.File_Name != oc_target.File_Name) as Is_Cross_File
FROM PrivilegeSetObjectAccess poa
JOIN ObjectCatalog oc_target
  ON poa.Object_UUID = oc_target.Object_UUID
 AND oc_target.Object_Type = poa.Object_Class
WHERE poa.Object_UUID IS NOT NULL
  AND poa.Access_Mode <> 'ReadWrite';

-- ========================================
-- groups_into-Links: PluginFunction → PluginComponent (structural)
-- ========================================
-- Jede MBS-Plugin-Funktion ist
-- über einen 'groups_into'-Link an ihre Komponente angebunden. Die Komponenten-
-- Auflösung folgt derselben Logik wie der PluginComponent-INSERT
-- (CSV-Override + Default-Heuristik split_part(SubName,'.',1)).
-- Source = PluginFunction (qualifiziert, z.B. 'MBS:XL.Book.AddFormat::XL.Book.AddFormat';
-- SubName = Teil nach '::', deckt auch das alte 'MBS::<Sub>'-Format ab),
-- Target = PluginComponent (z.B. 'MBS::XL'). Target_File = NULL (Component
-- ist lösungs-unabhängig), Is_Cross_File = FALSE (beide synthetisch).
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
WITH component_map AS (
    SELECT
        Funktionsname AS function_name,
        Component     AS component_name
    FROM read_csv('reference/mbs_component_exceptions.csv', header=true)
),
resolved AS (
    SELECT
        pf.Object_UUID                       AS function_uuid,
        split_part(pf.Object_Name, '::', 2)  AS sub_name,
        COALESCE(
            cm.component_name,
            split_part(split_part(pf.Object_Name, '::', 2), '.', 1)
        ) AS component_name
    FROM ObjectCatalog pf
    LEFT JOIN component_map cm
      ON cm.function_name = split_part(pf.Object_Name, '::', 2)
    WHERE pf.Object_Type = 'PluginFunction'
      AND pf.Object_Name LIKE 'MBS:%'
)
SELECT DISTINCT
    function_uuid                                          as Source_UUID,
    'PluginFunction'                                        as Source_Type,
    md5('PluginComponent::MBS::' || component_name)         as Target_UUID,
    'PluginComponent'                                       as Target_Type,
    'structural'                                            as Link_Type,
    'groups_into'                                           as Link_Role,
    NULL                                                    as Link_Subrole,
    NULL                                                    as Source_File,
    NULL                                                    as Target_File,
    FALSE                                                   as Is_Cross_File
FROM resolved
WHERE component_name IS NOT NULL
  AND component_name != '';

-- ========================================
-- CustomMenuSet → CustomMenu (contains_menu, structural)
-- ========================================
-- Member-Referenzen (CustomMenuList/CustomMenuReference) tragen nur @id (kein UUID) →
-- Auflösung per (Menu_ID, File_Name) gegen CustomMenuCatalog. Built-in-Menüs (z.B.
-- id 1 "[Standard FileMaker Menus]", "[Spelling]") sind KEINE Katalog-Objekte → der
-- JOIN lässt sie weg (nur echte Custom Menus werden verlinkt). Menü-Sets sind datei-
-- lokal → Is_Cross_File = FALSE.
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
WITH menuset_members AS (
    SELECT MenuSet_UUID, File_Name, UNNEST(Member_Menu_IDs) AS Menu_ID
    FROM CustomMenuSetCatalog
    WHERE Member_Menu_IDs IS NOT NULL
)
SELECT DISTINCT
    m.MenuSet_UUID  as Source_UUID,
    'CustomMenuSet' as Source_Type,
    cm.Menu_UUID    as Target_UUID,
    'CustomMenu'    as Target_Type,
    'structural'    as Link_Type,
    'contains_menu' as Link_Role,
    NULL            as Link_Subrole,
    m.File_Name     as Source_File,
    cm.File_Name    as Target_File,
    FALSE           as Is_Cross_File
FROM menuset_members m
JOIN CustomMenuCatalog cm
  ON cm.Menu_ID = m.Menu_ID AND cm.File_Name = m.File_Name;

-- ========================================
-- CustomMenuItem → CustomMenu (opens_menu, operational) — Submenu-Ziel (F-3)
-- ========================================
-- Ein Submenu-Item (isSubMenuItem="True") referenziert das Menü, das es öffnet, als
-- <CustomMenuReference id="…"/> — OHNE UUID. Auflösung per (File_Name, Menu_ID) gegen
-- CustomMenuCatalog (Menü-IDs sind datei-stabil). Bewusst NICHT parent_menu wieder-
-- verwenden: parent_menu ist der containment-artige Owner-Backlink (Item → sein Menü),
-- opens_menu dagegen eine echte Verwendung (Item → geöffnetes Ziel-Menü) → schließt die
-- Where-used-Lücke für Menüs, die NUR als Submenu eines anderen dienen (die MÜSSEN kein
-- Menü-Set-Mitglied sein, contains_menu deckt sie nicht ab) und macht die Menü-Hierarchie
-- navigierbar. Built-in-Menüs (kein Katalog-Objekt) fallen im JOIN weg. Menü-IDs sind
-- datei-lokal → Is_Cross_File = FALSE. Unauflösbare Ziel-IDs meldet P6 v_check_submenu_unresolved.
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
WITH submenu_refs AS (
    SELECT Item_UUID, File_Name,
           -- TRY_CAST — ein leeres/nicht-numerisches @id bräche mit hartem
           -- ::BIGINT ganz P4 mit Conversion Error ab (alle anderen F-2-Blöcke nutzen
           -- TRY_CAST). Ein NULL-Ergebnis fällt im JOIN gegen CustomMenuCatalog weg.
           TRY_CAST(xml_extract_text(Item_XML, '/CustomMenuItem/CustomMenuReference/@id')[1] AS BIGINT) AS Target_Menu_ID
    FROM CustomMenuItemCatalog
    WHERE Is_SubMenuItem
)
SELECT DISTINCT
    r.Item_UUID      as Source_UUID,
    'CustomMenuItem' as Source_Type,
    cm.Menu_UUID     as Target_UUID,
    'CustomMenu'     as Target_Type,
    'operational'    as Link_Type,
    'opens_menu'     as Link_Role,
    NULL             as Link_Subrole,
    r.File_Name      as Source_File,
    cm.File_Name     as Target_File,
    FALSE            as Is_Cross_File
FROM submenu_refs r
JOIN CustomMenuCatalog cm
  ON cm.Menu_ID = r.Target_Menu_ID AND cm.File_Name = r.File_Name;

-- ========================================
-- Portal → Field (sorts_by_field): Portal-Zeilensortierung
-- ========================================
-- Ein Portal kann seine Zeilen nach Feldern sortieren (SortSpecification/SortList) — diese
-- Felder waren bisher GAR NICHT als Abhängigkeit erfasst (nur zufällige displays_field-
-- Überlappung). Pro Sortfeld werden die index-parallelen @UUID/@id/TO-@UUID-Listen
-- ge-UNNEST-et und über (TO_UUID, Feld-id) auf die kanonische Feld-UUID aufgelöst (die
-- FieldReference-UUID ist kontext-synthetisch); Fallback = synthetische UUID. Der finale
-- ObjectCatalog-JOIN lässt nicht-auflösbare (z.B. TO-lose) Fälle sauber weg — eine etwaige
-- Listen-Fehlausrichtung erzeugt so höchstens einen Drop, nie einen falschen Link.
-- Link_Subrole='portal'. webbed ist am P4-Kopf geladen; Scan nur über Portale mit SortList.
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
WITH ps_raw AS (
    -- Extraktion PRO //Sort-Element statt drei parallel ge-UNNEST-eter
    -- XPath-Listen — eine fehlende TableOccurrenceReference verschob das Zipping
    -- und konnte (entgegen dem alten Kommentar) auf ein FALSCHES existierendes
    -- Feld auflösen, nicht nur droppen.
    SELECT lo.Object_UUID, lo.File_Name,
        unnest(xml_extract_elements(lo.Object_XML, '//SortSpecification/SortList/Sort')) AS sort_xml
    FROM LayoutObjects lo
    WHERE lo.Object_Type = 'Portal' AND lo.Object_XML LIKE '%SortList%'
),
ps AS (
    SELECT Object_UUID, File_Name,
        xml_extract_text(sort_xml, '/Sort/PrimaryField/FieldReference/@UUID')[1] AS suid,
        xml_extract_text(sort_xml, '/Sort/PrimaryField/FieldReference/@id')[1] AS sid_str,
        xml_extract_text(sort_xml, '/Sort/PrimaryField/FieldReference/TableOccurrenceReference/@UUID')[1] AS sto
    FROM ps_raw
)
SELECT DISTINCT
    ps.Object_UUID  as Source_UUID,
    'LayoutObject'  as Source_Type,
    COALESCE(f.Field_UUID, ps.suid) as Target_UUID,
    'Field'         as Target_Type,
    'operational'   as Link_Type,
    'sorts_by_field' as Link_Role,
    'portal'        as Link_Subrole,
    ps.File_Name    as Source_File,
    oc.File_Name    as Target_File,
    (ps.File_Name != oc.File_Name) as Is_Cross_File
FROM ps
LEFT JOIN TableOccurrenceCatalog toc ON toc.TO_UUID = ps.sto AND toc.File_Name = ps.File_Name
LEFT JOIN FieldsForTables f
       ON f.Table_Name = toc.BT_Name
      AND f.File_Name = regexp_replace(COALESCE(NULLIF(toc.DS_Name, ''), toc.File_Name), '\.fmp12$', '')
      AND f.Field_ID = TRY_CAST(ps.sid_str AS BIGINT)
JOIN ObjectCatalog oc ON COALESCE(f.Field_UUID, ps.suid) = oc.Object_UUID AND oc.Object_Type = 'Field'
WHERE ps.suid IS NOT NULL;

-- ========================================
-- Kanten: bislang „tote Knoten" verlinken (Schema 1.5.0)
-- ========================================

-- PrivilegeSet → ExtendedPrivilege (grants_privilege, operational)
-- Zugriffs-Audit: „welche Sets gewähren fmapp/fmxdbc/fmwebdirect?" — vorher
-- waren alle 630 ExtendedPrivileges unverlinkt. Quelle: die PrivilegeSet_IDs-
-- Arrays der EP-Zeilen (datei-lokal).
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    psc.PrivilegeSet_UUID as Source_UUID,
    'PrivilegeSet'        as Source_Type,
    ep.EP_UUID            as Target_UUID,
    'ExtendedPrivilege'   as Target_Type,
    'operational'         as Link_Type,
    'grants_privilege'    as Link_Role,
    NULL                  as Link_Subrole,
    ep.File_Name          as Source_File,
    ep.File_Name          as Target_File,
    FALSE                 as Is_Cross_File
FROM (
    SELECT EP_UUID, File_Name, UNNEST(PrivilegeSet_IDs) AS PS_ID
    FROM ExtendedPrivilegesCatalog
    WHERE PrivilegeSet_IDs IS NOT NULL
) ep
JOIN PrivilegeSetsCatalog psc
  ON psc.PrivilegeSet_ID = ep.PS_ID
 AND psc.File_Name = ep.File_Name
WHERE ep.EP_UUID IS NOT NULL;

-- Layout → Theme (uses_theme, operational)
-- Theme-Aufräumfrage („welche Themes sind in Gebrauch?") — vorher waren alle
-- Themes unverlinkt. Join primär über die AUFGELÖSTE Referenz-UUID
-- (L_Theme_Resolved_UUID aus P3/A.11), Fallback über die datei-lokale Theme-ID
-- (falls Referenz- und Katalog-UUID divergieren).
-- Die aufgelöste UUID statt der rohen L_Theme_UUID, weil SaXML das Classic-Theme
-- als leere <LayoutThemeReference/> kodiert: mit der Rohspalte blieb jedes
-- Classic-Layout unverlinkt und Classic in JEDER Datei scheinbar unbenutzt.
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    l.L_UUID       as Source_UUID,
    'Layout'       as Source_Type,
    tc.Theme_UUID  as Target_UUID,
    'Theme'        as Target_Type,
    'operational'  as Link_Type,
    'uses_theme'   as Link_Role,
    NULL           as Link_Subrole,
    l.File_Name    as Source_File,
    tc.File_Name   as Target_File,
    FALSE          as Is_Cross_File
FROM Layouts l
JOIN ThemeCatalog tc
  ON tc.File_Name = l.File_Name
 AND (tc.Theme_UUID = l.L_Theme_Resolved_UUID OR tc.Theme_ID = l.L_Theme_ID)
WHERE l.L_Theme_Resolved_UUID IS NOT NULL
  AND (l.Folder_Type IS NULL OR l.Folder_Type = 'False')
  AND NOT COALESCE(l.Is_Separator, FALSE);

-- Layout → CustomMenuSet (uses_menuset, operational)
-- Layout-gebundenes Menüset (CustomMenuSetReference im Layout-Tail, Schema 1.5.1):
-- ein NUR per Layout gebundenes Menüset erschien als unverlinkt (installs_menuset
-- deckte nur Script-Steps ab). Built-in-Default (id=0) ist bereits in P1 auf NULL
-- normalisiert. Join wie uses_theme: primär Referenz-UUID, Fallback datei-lokale ID.
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    l.L_UUID          as Source_UUID,
    'Layout'          as Source_Type,
    cms.MenuSet_UUID  as Target_UUID,
    'CustomMenuSet'   as Target_Type,
    'operational'     as Link_Type,
    'uses_menuset'    as Link_Role,
    NULL              as Link_Subrole,
    l.File_Name       as Source_File,
    cms.File_Name     as Target_File,
    FALSE             as Is_Cross_File
FROM Layouts l
JOIN CustomMenuSetCatalog cms
  ON cms.File_Name = l.File_Name
 AND (cms.MenuSet_UUID = l.L_MenuSet_UUID OR cms.MenuSet_ID = l.L_MenuSet_ID)
WHERE l.L_MenuSet_ID IS NOT NULL
  AND (l.Folder_Type IS NULL OR l.Folder_Type = 'False')
  AND NOT COALESCE(l.Is_Separator, FALSE);

-- Script → CustomMenuSet (installs_menuset, operational)
-- Install-Menu-Set-Steps (P2: XMLStepReferences Ref_Type='menuset') — vorher
-- erschien ein nur per Script installiertes Menüset als unverlinkt.
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    xsr.Script_UUID     as Source_UUID,
    'Script'            as Source_Type,
    xsr.Ref_UUID        as Target_UUID,
    'CustomMenuSet'     as Target_Type,
    'operational'       as Link_Type,
    'installs_menuset'  as Link_Role,
    NULL                as Link_Subrole,
    xsr.File_Name       as Source_File,
    oc.File_Name        as Target_File,
    (xsr.File_Name != oc.File_Name) as Is_Cross_File
FROM XMLStepReferences xsr
JOIN ObjectCatalog oc
  ON xsr.Ref_UUID = oc.Object_UUID
 AND oc.Object_Type = 'CustomMenuSet'
WHERE xsr.Ref_Type = 'menuset'
  AND xsr.Ref_UUID IS NOT NULL AND xsr.Ref_UUID <> '';

-- LayoutPart → Layout (parent_layout, structural)
-- LayoutParts waren „halb integriert" (registriert, aber unverlinkt).
-- Composite-UUID identisch zur Catalog-Registrierung (Block 10).
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    'part_' || lp.Layout_ID::VARCHAR || '_' || lp.Part_Kind::VARCHAR || '_' || lp.Part_Seq::VARCHAR || '_' || lp.File_Name as Source_UUID,
    'LayoutPart'    as Source_Type,
    l.L_UUID        as Target_UUID,
    'Layout'        as Target_Type,
    'structural'    as Link_Type,
    'parent_layout' as Link_Role,
    lp.Part_Type    as Link_Subrole,
    lp.File_Name    as Source_File,
    l.File_Name     as Target_File,
    FALSE           as Is_Cross_File
FROM LayoutParts lp
JOIN Layouts l
  ON l.L_ID = lp.Layout_ID
 AND l.File_Name = lp.File_Name
 AND (l.Folder_Type IS NULL OR l.Folder_Type = 'False')
 AND NOT COALESCE(l.Is_Separator, FALSE);

-- LayoutPart → Field (breaks_on_field, operational)
-- Gruppierungs-/Umbruchfeld einer Sub-Summary (Part/Definition/FieldReference, Schema
-- 1.5.1): ein NUR als Sub-Summary-Umbruch genutztes Feld erschien sonst als unbenutzt.
-- Composite-Source-UUID identisch zur Catalog-Registrierung (Block 10, nutzt Part_Kind).
-- Klon-Fächerung über den generischen oc-Join wird vom prefer-local-DELETE unten bereinigt.
--
-- FILTER LOCALE-UNABHÄNGIG per Part_Kind (früher `Part_Type LIKE '%Sub-summary%'`): die
-- beiden Sub-summary-Arten sind kind=3 (Leading) und kind=5 (Trailing). Der Namensfilter
-- verfehlte GLEICH ZWEI Klassen: (a) den lokalisierten dt. Namen „Vorangestelltes
-- Zwischenergebnis" (kind=3) und (b) ALLE kind=5-Parts — FileMaker exportiert deren @type
-- fälschlich als „Trailing Grand Summary" (Mislabel; die ECHTE Trailing Grand Summary ist
-- kind=6 und trägt korpusweit KEIN Break-Feld). Alle 273 kind=5-Parts tragen ein aktives
-- Gruppierungsfeld (name="Sub…") → reale Feldreferenz, kein Leftover. Echte Grand
-- Summaries (kind 2/6) bleiben ausgeschlossen — ein etwaiges Leftover-Umbruchfeld dort
-- wäre semantisch inaktiv. Link_Subrole kind-korrekt (statt des @type-Mislabels).
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    'part_' || lp.Layout_ID::VARCHAR || '_' || lp.Part_Kind::VARCHAR || '_' || lp.Part_Seq::VARCHAR || '_' || lp.File_Name as Source_UUID,
    'LayoutPart'        as Source_Type,
    lp.Break_Field_UUID as Target_UUID,
    'Field'             as Target_Type,
    'operational'       as Link_Type,
    'breaks_on_field'   as Link_Role,
    -- Subrole rein aus Part_Kind (locale-unabhängig, unabhängig von der Part_Type-
    -- Normalisierungs-Reihenfolge; der Filter lässt nur kind 3/5 durch):
    CASE lp.Part_Kind
        WHEN 3 THEN 'Leading Sub-summary'
        WHEN 5 THEN 'Trailing Sub-summary'
        ELSE lp.Part_Type
    END as Link_Subrole,
    lp.File_Name        as Source_File,
    oc.File_Name        as Target_File,
    (lp.File_Name != oc.File_Name) as Is_Cross_File
FROM LayoutParts lp
JOIN ObjectCatalog oc
  ON lp.Break_Field_UUID = oc.Object_UUID
 AND oc.Object_Type = 'Field'
WHERE lp.Break_Field_UUID IS NOT NULL
  AND lp.Part_Kind IN (3, 5);   -- 3 = Leading, 5 = Trailing Sub-summary (locale-unabhängig)

-- Field → ValueList (uses_valuelist, Subrole 'validation', operational)
-- Feld-Validierung per Werteliste: eine NUR zur Validierung genutzte
-- ValueList erschien als unbenutzt. Gleiche Rolle wie die LayoutObject-Nutzung
-- (uses_valuelist), Subrole unterscheidet die Validierungs-Granularität.
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    f.Field_UUID          as Source_UUID,
    'Field'               as Source_Type,
    f.Validation_VL_UUID  as Target_UUID,
    'ValueList'           as Target_Type,
    'operational'         as Link_Type,
    'uses_valuelist'      as Link_Role,
    'validation'          as Link_Subrole,
    f.File_Name           as Source_File,
    oc.File_Name          as Target_File,
    (f.File_Name != oc.File_Name) as Is_Cross_File
FROM FieldsForTables f
JOIN ObjectCatalog oc
  ON f.Validation_VL_UUID = oc.Object_UUID
 AND oc.Object_Type = 'ValueList'
WHERE f.Validation_VL_UUID IS NOT NULL;

-- Field → Field (summarizes_field, operational)
-- Summary-Felder: das summierte Feld verlor einen Verwender. Die
-- SummaryField/FieldReference-UUID ist kanonisch (BaseTable-Kontext).
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    f.Field_UUID          as Source_UUID,
    'Field'               as Source_Type,
    f.Summary_Field_UUID  as Target_UUID,
    'Field'               as Target_Type,
    'operational'         as Link_Type,
    'summarizes_field'    as Link_Role,
    f.Summary_Operation   as Link_Subrole,
    f.File_Name           as Source_File,
    oc.File_Name          as Target_File,
    (f.File_Name != oc.File_Name) as Is_Cross_File
FROM FieldsForTables f
JOIN ObjectCatalog oc
  ON f.Summary_Field_UUID = oc.Object_UUID
 AND oc.Object_Type = 'Field'
WHERE f.Summary_Field_UUID IS NOT NULL;

-- File → Layout (default_layout, operational)
-- Start-Layout aus den Datei-Optionen (FileOptionsCatalog): ein nur als
-- Start-Layout dienendes Layout erschien als ungenutzt.
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    fc.File_UUID             as Source_UUID,
    'File'                   as Source_Type,
    fo.Default_Layout_UUID   as Target_UUID,
    'Layout'                 as Target_Type,
    'operational'            as Link_Type,
    'default_layout'         as Link_Role,
    NULL                     as Link_Subrole,
    fo.File_Name             as Source_File,
    oc.File_Name             as Target_File,
    FALSE                    as Is_Cross_File
FROM FileOptionsCatalog fo
JOIN FilesCatalog fc ON fc.File_Name = fo.File_Name
JOIN ObjectCatalog oc
  ON fo.Default_Layout_UUID = oc.Object_UUID
 AND oc.Object_Type = 'Layout'
WHERE fo.Default_Layout_UUID IS NOT NULL;

-- File → Account (auto_login_account, operational — SICHERHEITSRELEVANT)
-- Auto-Login-Konto aus den Datei-Optionen (Login type='1' + AccountName).
-- Namensbasierte Auflösung (die Datei-Option trägt keine Account-UUID).
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT DISTINCT
    fc.File_UUID         as Source_UUID,
    'File'               as Source_Type,
    ac.Account_UUID      as Target_UUID,
    'Account'            as Target_Type,
    'operational'        as Link_Type,
    'auto_login_account' as Link_Role,
    NULL                 as Link_Subrole,
    fo.File_Name         as Source_File,
    ac.File_Name         as Target_File,
    FALSE                as Is_Cross_File
FROM FileOptionsCatalog fo
JOIN FilesCatalog fc ON fc.File_Name = fo.File_Name
JOIN AccountsCatalog ac
  ON ac.Account_Name = fo.Login_AccountName
 AND ac.File_Name = fo.File_Name
WHERE fo.Login_AccountName IS NOT NULL;

-- ========================================
-- Owner → Calculation (has_calculation, structural) — Schema 1.22.0
-- ========================================
-- Containment-Schicht der Berechnungs-Instanzen (Variante A des Calculation-
-- Objekttyps): macht Owner ↔ Calculation in beiden Richtungen navigierbar,
-- OHNE eine einzige Nutzungs-Semantik zu verändern — die owner-projizierten
-- Usage-Kanten bleiben kanonisch, Calculation→Ziel gibt es nur als abgeleitete
-- View v_calculation_links (s. Ende dieser Datei). Link_Kind='containment',
-- Counts_For_Where_Used=false (Registry) → fällt aus Where-used-Analysen und
-- (weil structural) per Konstruktion aus LogicalLinks/ClusterEdges heraus.
-- Link_Subrole = Calc_Role[:Calc_Index] (Index nur bei Mehrfach-Instanzen
-- derselben Rolle, konsistent zur Object_Name-Bildung).
-- Owner-Typ 'unresolved' (Anker ohne Katalog-Treffer, Soll 0) erzeugt bewusst
-- KEINE Kante (Quelle wäre unkatalogisiert → v_check_orphan_sources).
INSERT INTO ObjectLinks (Source_UUID, Source_Type, Target_UUID, Target_Type,
                          Link_Type, Link_Role, Link_Subrole,
                          Source_File, Target_File, Is_Cross_File)
SELECT
    c.Owner_UUID          as Source_UUID,
    c.Owner_Type          as Source_Type,
    c.Calculation_UUID    as Target_UUID,
    'Calculation'         as Target_Type,
    'structural'          as Link_Type,
    'has_calculation'     as Link_Role,
    c.Calc_Role
        || CASE WHEN COUNT(*) OVER (PARTITION BY c.File_Name, c.Owner_UUID, c.Calc_Role) > 1
                THEN ':' || c.Calc_Index ELSE '' END as Link_Subrole,
    c.File_Name           as Source_File,
    c.File_Name           as Target_File,
    FALSE                 as Is_Cross_File
FROM CalculationsCatalog c
WHERE c.Owner_Type <> 'unresolved';

-- ========================================
-- Link-Hygiene: NULL-Ziele entfernen, Is_Cross_File normalisieren
-- ========================================
-- Diverse LEFT-JOIN-Blöcke reichen NULL-Targets bzw. NULL-Is_Cross_File durch
-- (Blöcke 22–25 coalescen auf FALSE, Blöcke 1–9 nicht). NULL-Ziel-Zeilen tragen
-- keine auswertbare Information, zwingen aber jeden direkten ObjectLinks-
-- Konsumenten zu NULL-Safety (klassische NOT-IN-NULL-Falle) → hier zentral
-- bereinigt statt in jedem Block einzeln.
DELETE FROM ObjectLinks WHERE Target_UUID IS NULL;

-- Is_Cross_File vereinheitlichen: wo beide Datei-Spalten bekannt sind, ehrlich
-- berechnen; unauflösbare Ziele (Target_File NULL — z.B. Referenz in eine nicht
-- importierte Datei oder datei-unabhängige synthetische Ziele) konservativ FALSE
-- (Konvention der Blöcke 22–25) — sie sollen in Cross-File-Auswertungen nicht
-- als belegte Abhängigkeit erscheinen.
UPDATE ObjectLinks
SET Is_Cross_File = (Source_File IS DISTINCT FROM Target_File)
WHERE Is_Cross_File IS NULL AND Target_File IS NOT NULL;

UPDATE ObjectLinks
SET Is_Cross_File = FALSE
WHERE Is_Cross_File IS NULL;

-- ========================================
-- LinkRoleRegistry — Rollen-Semantik als Daten (analog step_metadata)
-- ========================================
-- Die Semantik jeder Link-Rolle (usage/containment/restriction, zählt-für-
-- Where-used) lebte bisher nur in Kommentaren und handgepflegten Listen (z.B.
-- kannte der LogicalLinks-Containment-Ausschluss `parent_menu` nicht — aktuell
-- durch Type-Filter gedeckt, bräche aber bei der nächsten Rolle). Diese Registry
-- macht sie abfragbar; P6 wacht darüber, dass KEINE Rolle in ObjectLinks ohne
-- Registry-Eintrag existiert (v_check_link_roles) — neue Rollen müssen hier
-- klassifiziert werden. Volatil (jeder P4-Lauf baut sie neu).
-- Kind-Semantik:
--   usage       = echte Verwendung → zählt in Where-used-/Dead-Code-Analysen
--   containment = Struktur-Gerüst (Eltern-Kind) → zählt NICHT als Verwendung
--   restriction = Rechte-Einschränkung → zählt NICHT als Verwendung
CREATE OR REPLACE TABLE LinkRoleRegistry (
    Link_Role VARCHAR PRIMARY KEY,
    Link_Kind VARCHAR NOT NULL,            -- usage | containment | restriction
    Counts_For_Where_Used BOOLEAN NOT NULL
);
INSERT INTO LinkRoleRegistry VALUES
    ('base_table',           'usage',       TRUE),
    ('breaks_on_field',      'usage',       TRUE),
    ('parent_table',         'usage',       TRUE),
    ('calls_customfunction', 'usage',       TRUE),
    ('calls_function',       'usage',       TRUE),
    ('calls_pluginfunction', 'usage',       TRUE),
    ('calls_script',         'usage',       TRUE),
    ('context_table',        'usage',       TRUE),
    ('data_source',          'usage',       TRUE),
    ('default_layout',       'usage',       TRUE),
    ('auto_login_account',   'usage',       TRUE),
    ('displays_field',       'usage',       TRUE),
    ('displays_variable',    'usage',       TRUE),
    ('exports_from_field',   'usage',       TRUE),
    ('finds_in_field',       'usage',       TRUE),
    ('grants_privilege',     'usage',       TRUE),
    ('imports_to_field',     'usage',       TRUE),
    ('inputs_to_field',      'usage',       TRUE),
    ('installs_menuset',     'usage',       TRUE),
    ('left_field',           'usage',       TRUE),
    ('left_table',           'usage',       TRUE),
    ('right_field',          'usage',       TRUE),
    ('right_table',          'usage',       TRUE),
    ('lookup_relationship',  'usage',       TRUE),
    ('lookup_source',        'usage',       TRUE),
    ('navigates_to_field',   'usage',       TRUE),
    ('navigates_to_layout',  'usage',       TRUE),
    ('navigates_to_to',      'usage',       TRUE),
    -- Submenu-Ziel: Item → geöffnetes Menü (F-3); echte Verwendung (≠ parent_menu-Owner)
    ('opens_menu',           'usage',       TRUE),
    ('portal_context',       'usage',       TRUE),
    ('privilege_set',        'usage',       TRUE),
    ('reads_field',          'usage',       TRUE),
    ('reads_variable',       'usage',       TRUE),
    -- Fallback-Rolle des Script→Field-Blocks (Block 16) für Step-Namen ohne
    -- CASE-Zweig. Feuert real bei LOKALISIERTEN Exporten (deutsche Step-Namen
    -- „Feldwert setzen" …) — die Step_Name-basierte Rollen-Zuordnung ist eine
    -- bekannte Lücke (Folgearbeit: Mapping auf Step_ID statt Namen umstellen).
    ('references_field',     'usage',       TRUE),
    ('sets_field',           'usage',       TRUE),
    ('sets_variable',        'usage',       TRUE),
    ('sort_field',           'usage',       TRUE),
    ('sorts_by_field',       'usage',       TRUE),
    ('sorts_by_valuelist',   'usage',       TRUE),
    ('source_field',         'usage',       TRUE),
    ('source_table',         'usage',       TRUE),
    -- External-Werteliste: Wrapper-VL → Ziel-VL der Quelldatei (Block 13b)
    ('source_valuelist',     'usage',       TRUE),
    ('summarizes_field',     'usage',       TRUE),
    -- Granulare Detail-Kante des reifizierten Triggers (Block 18). Zählt seit
    -- 2.17.0 NICHT mehr für Where-used: die Owner-Spiegel (triggers_script,
    -- Block 21a, alle drei Owner-Ebenen) sind die einzige zählende Wahrheit —
    -- vorher zählte dieselbe ScriptTriggers-Zeile auf Objekt-Ebene doppelt.
    -- Kind bleibt 'usage' (die Kante IST eine Script-Verwendung, nur nicht die
    -- zählende Repräsentation); Navigation/Detailseite/Graph-Fokus-Brücke
    -- lesen sie weiter.
    ('trigger_script',       'usage',       FALSE),
    ('triggers_script',      'usage',       TRUE),
    ('uses_menuset',         'usage',       TRUE),
    ('uses_theme',           'usage',       TRUE),
    ('uses_valuelist',       'usage',       TRUE),
    -- Feld → Feld/CustomFunction über eine Feldvalidierung „Überprüfung durch
    -- Berechnung" (<Validation><Calculated>); echte Verwendung → Where-used zählt.
    ('validates_by_calc',    'usage',       TRUE),
    -- Containment (Struktur; parent_layout existiert operational [LayoutObject→
    -- Layout, bewusst sichtbar in Referenzlisten] UND structural [LayoutPart→
    -- Layout] — für Where-used zählt beides nicht als "Verwendung" des Layouts)
    ('parent_layout',        'containment', FALSE),
    ('parent_script',        'containment', FALSE),
    ('parent_object',        'containment', FALSE),
    ('parent_folder',        'containment', FALSE),
    ('parent_menu',          'containment', FALSE),
    ('contains_menu',        'containment', FALSE),
    ('groups_into',          'containment', FALSE),
    ('trigger_owner',        'containment', FALSE),
    -- Owner → Calculation (Schema 1.22.0): Berechnungs-Instanz als Sub-Objekt
    -- ihres Owners; zählt NIE als Verwendung (die Usage-Semantik liegt in den
    -- owner-projizierten Kanten, Variante A).
    ('has_calculation',      'containment', FALSE),
    -- Restriktionen (nie eine Verwendung — s. PrivilegeSet-Doku)
    ('restricts_field',      'restriction', FALSE),
    ('restricts_object',     'restriction', FALSE);

-- Indexes für ObjectLinks
CREATE INDEX idx_objectlinks_source ON ObjectLinks(Source_UUID);
CREATE INDEX idx_objectlinks_target ON ObjectLinks(Target_UUID);
CREATE INDEX idx_objectlinks_type ON ObjectLinks(Link_Type);
CREATE INDEX idx_objectlinks_composite ON ObjectLinks(Source_Type, Target_Type);
CREATE INDEX idx_objectlinks_file ON ObjectLinks(Source_File, Target_File);
CREATE INDEX idx_objectlinks_crossfile ON ObjectLinks(Is_Cross_File);


-- ========================================
-- Klon-Robustheit: prefer-local-else-keep-cross-file (operationale Links)
-- ========================================
-- In geklonten/modularen Lösungen ("Kopie speichern unter…") ist Object_UUID NICHT
-- eindeutig — die Objekt-Identität ist das Paar (Object_UUID, File_Name). Die
-- generischen oc_target-JOINs oben binden ein Ziel allein über die UUID; existiert
-- dieselbe UUID in mehreren Klon-Dateien, fächert EINE operationale Kante über alle
-- diese Dateien (z.B. portal_context/right_table/left_table/context_table →
-- TableOccurrence, triggers_script/calls_script → Script). Das sind Klon-Artefakte:
-- eine Beziehung/ein Layout/ein Button referenziert die Kopie in der EIGENEN Datei.
--
-- Regel: existiert für eine Kante (Source_UUID, Source_File, Link_Role, Link_Subrole,
-- Target_UUID) ein datei-LOKALES Ziel (Target_File = Source_File), gewinnt dieses
-- (prefer-local) und alle cross-file Zeilen derselben Kante werden entfernt. Existiert
-- KEIN lokales Ziel, bleibt die Kante als echte Cross-File-Referenz erhalten (z.B.
-- externer Scriptaufruf / Set Field in eine zentrale Daten-/Archiv-Datei) — wir raten
-- NICHT willkürlich einen Klon (keep-cross-file). Ist das Cross-File-Ziel selbst
-- geklont, bleibt es bewusst mehrdeutig (dokumentierte Modellgrenze).
--
-- Containment/strukturelle Links sind bereits datei-gleich gejoint (Is_Cross_File=0)
-- → unberührt (Filter Link_Type='operational'). NULL-Ziel-Rollen (BuiltinFunction/
-- PluginFunction/calls_function: Target_File IS NULL) haben nie ein lokales Sibling
-- (NULL = Source_File ist nie wahr) → ebenfalls unberührt. Auf klon-freien Lösungen
-- existiert keine geteilte UUID → der DELETE trifft nichts (No-Op, bit-identisch).
--
-- KANONISCHE ZIEL-AUFLÖSUNGS-REIHENFOLGE (verbindlich für alle Stufen an diesem
-- Hotspot — hier UND in künftigen Erweiterungen):
--   (1) Ref_ID-Rewrite intra-file        → korrekte Ziel-UUID bei Intra-File-
--       Duplikaten (UUID-Healing, Schema 1.19.0 — UMGESETZT als Rewrite der
--       P2-Referenztabellen VOR dem ObjectLinks-CTAS, s. Block „UUID-Healing —
--       Stufe (1)" nach der Empty-String-Hygiene; wirkt dadurch uniform auf
--       CTAS und alle Folge-INSERTs, ohne einzelne Resolver anzufassen)
--   (2) declared-source-Scoping cross-file → korrekte Ziel-DATEI über die
--       deklarierte Datenquelle (DataSourceFileMap): Block 6 scopet base_table
--       bereits beim CTAS (per-TO-Deklaration, präziser als jede Datei-Heuristik);
--       der prefer-declared-source-Pass unten deckt die übrigen Rollen ab
--   (3) prefer-local (dieser DELETE)      → lokales Ziel schlägt Cross-File-Klone
--   (4) keep-cross-file                   → keine/mehrdeutige Auflösung bleibt
--       ehrlich mehrdeutig stehen (Modellgrenze)
DELETE FROM ObjectLinks ol
WHERE ol.Link_Type = 'operational'
  AND ol.Target_File IS DISTINCT FROM ol.Source_File
  AND EXISTS (
        SELECT 1 FROM ObjectLinks loc
        WHERE loc.Link_Type    = 'operational'
          AND loc.Source_UUID  = ol.Source_UUID
          AND loc.Source_File  = ol.Source_File
          AND loc.Link_Role    = ol.Link_Role
          AND loc.Link_Subrole IS NOT DISTINCT FROM ol.Link_Subrole
          AND loc.Target_UUID  = ol.Target_UUID
          AND loc.Target_File  = loc.Source_File
      );

-- Stufe (2) generisch: prefer-declared-source (Phantom-Links über Klon-Dateien).
-- Fächert eine operationale Kante (gleiche Source, Rolle, Subrole, Target_UUID)
-- über MEHRERE Ziel-Dateien auf und ist GENAU EINE davon eine deklarierte
-- Datenquelle der Quelldatei (DataSourceFileMap), gewinnt diese — die übrigen
-- Zeilen sind Klon-Artefakte („in irgendeine Datei, die die UUID zufällig auch
-- enthält") und werden entfernt. Deckt reads_field/displays_field/calls_script/
-- sets_field/left_field/source_field … uniform ab, ohne jeden Resolver anzufassen.
--
-- Konservativ in drei Richtungen: (a) Gruppen mit lokalem Ziel bleiben dem
-- prefer-local-DELETE überlassen (NOT bool_or(is_local) — macht den Pass
-- reihenfolge-unabhängig zu Stufe 3); (b) keine oder MEHRERE deklarierte
-- Zieldateien in der Gruppe → unverändert keep-cross-file (z. B. Hub-Datei, die
-- zwei Klon-Module gleichzeitig als Quelle deklariert — ehrliche Modellgrenze);
-- (c) klonfreie Korpora haben keine mehrdatei-Fächer → No-Op, bit-identisch.
CREATE TEMP TABLE PreferDeclaredWinners AS
SELECT Source_UUID, Source_File, Link_Role, Link_Subrole, Target_UUID,
       any_value(declared_file) AS Winner_File
FROM (
    SELECT ol.Source_UUID, ol.Source_File, ol.Link_Role, ol.Link_Subrole,
           ol.Target_UUID, ol.Target_File,
           CASE WHEN d.File_Name IS NOT NULL THEN ol.Target_File END AS declared_file,
           (ol.Target_File = ol.Source_File) AS is_local
    FROM ObjectLinks ol
    LEFT JOIN (SELECT DISTINCT File_Name, Resolved_File FROM DataSourceFileMap) d
           ON d.File_Name = ol.Source_File
          AND d.Resolved_File = ol.Target_File
    WHERE ol.Link_Type = 'operational'
      AND ol.Target_File IS NOT NULL
)
GROUP BY Source_UUID, Source_File, Link_Role, Link_Subrole, Target_UUID
HAVING COUNT(DISTINCT Target_File) > 1
   AND COUNT(DISTINCT declared_file) = 1
   AND NOT bool_or(is_local);

DELETE FROM ObjectLinks ol
USING PreferDeclaredWinners w
WHERE ol.Link_Type = 'operational'
  AND ol.Source_UUID  = w.Source_UUID
  AND ol.Source_File  = w.Source_File
  AND ol.Link_Role    = w.Link_Role
  AND ol.Link_Subrole IS NOT DISTINCT FROM w.Link_Subrole
  AND ol.Target_UUID  = w.Target_UUID
  AND ol.Target_File IS NOT NULL
  AND ol.Target_File <> w.Winner_File;

DROP TABLE PreferDeclaredWinners;


-- ========================================
-- Statistik-Views für Monitoring
-- ========================================

-- Object Count per Type and File
CREATE OR REPLACE VIEW v_object_stats AS
SELECT
    Object_Type,
    File_Name,
    COUNT(*) as Object_Count
FROM ObjectCatalog
GROUP BY Object_Type, File_Name
ORDER BY Object_Type, File_Name;

-- Link Count per Type
CREATE OR REPLACE VIEW v_link_stats AS
SELECT
    Source_Type,
    Target_Type,
    Link_Type,
    COUNT(*) as Link_Count,
    SUM(CASE WHEN Is_Cross_File THEN 1 ELSE 0 END) as Cross_File_Links
FROM ObjectLinks
GROUP BY Source_Type, Target_Type, Link_Type
ORDER BY Link_Count DESC;

-- Cross-File Dependencies
CREATE OR REPLACE VIEW v_cross_file_dependencies AS
SELECT
    ol.Source_Type,
    oc_source.Object_Name as Source_Object,
    oc_source.File_Name as Source_File,
    ol.Target_Type,
    oc_target.Object_Name as Target_Object,
    oc_target.File_Name as Target_File,
    ol.Link_Role
FROM ObjectLinks ol
JOIN ObjectCatalog oc_source ON ol.Source_UUID = oc_source.Object_UUID
JOIN ObjectCatalog oc_target ON ol.Target_UUID = oc_target.Object_UUID
WHERE ol.Is_Cross_File = true
ORDER BY ol.Source_Type, oc_source.Object_Name;

-- ========================================
-- v_calculation_links — Calculation → Ziel, ABGELEITET (Schema 1.22.0)
-- ========================================
-- Kernentscheidung Variante A: die owner-projizierten Usage-Kanten bleiben die
-- kanonische Nutzungsschicht; diese View rekonstruiert die Detailauflösung
-- „welche Kante gehört zu welcher Berechnungs-Instanz" — es entstehen KEINE
-- physischen Zusatz-Kanten (kein Where-used-Doppel, kein Graph-Wachstum).
--
-- Zwei Auflösungswege:
--   (1) Nicht-Step-Owner: ObjectLinks ankert direkt am Owner; der Slot steckt
--       in Link_Subrole und matcht CalculationsCatalog.Edge_Subrole
--       (Rollen-Whitelist = die calc-gespeisten Rollen der Blöcke 30/31/33/34 —
--       schließt Kollisionen mit gleich-subrolten Nicht-Calc-Kanten wie
--       uses_valuelist/'validation' aus).
--   (2) ScriptStep-Owner: ObjectLinks ankert am SCRIPT (Source_UUID =
--       Script_UUID) und Link_Subrole = Calc-Position — über Steps hinweg
--       mehrdeutig (Position 0 hat fast jeder Step). Instanz-exakt geht es
--       über XMLCalcReferences/PluginFunctionUsages (tragen Source_Subkey =
--       Step_Index); die Ziel-Auflösung spiegelt die Blöcke 30/31/33/34
--       (XMLCalcReferences.Ref_UUID ist zu diesem Zeitpunkt bereits geheilt).
--
-- Bekannte Grenzen (dokumentiert, Stufe 1): Variablen-Ziele fehlen (laufen über
-- VariableUsages, nicht slot-attribuierbar); calls_script via MBS:FM.RunScript
-- (Block 34b) fehlt (Subrole trägt dort die Methode, nicht den Slot); bei
-- Feldern vor Re-Import mit Schema <1.22.0 sind AutoEnter-Kanten noch
-- Subrole-NULL (Trennschärfe erst nach Neuimport).
CREATE OR REPLACE VIEW v_calculation_links AS
-- (1) Nicht-Step-Owner über ObjectLinks
SELECT DISTINCT
    c.Calculation_UUID,
    ol.Link_Role,
    ol.Target_UUID,
    ol.Target_Type,
    ol.Target_File,
    ol.Is_Cross_File
FROM CalculationsCatalog c
JOIN ObjectLinks ol
  ON ol.Source_UUID  = c.Owner_UUID
 AND ol.Source_File  = c.File_Name
 AND ol.Link_Type    = 'operational'
 AND ol.Link_Role IN ('reads_field', 'validates_by_calc', 'calls_customfunction',
                      'calls_function', 'calls_pluginfunction')
 AND ol.Link_Subrole IS NOT DISTINCT FROM c.Edge_Subrole
WHERE c.Owner_Type NOT IN ('ScriptStep', 'unresolved')

UNION ALL

-- (2a) ScriptStep → Field (instanz-exakt via XMLCalcReferences)
SELECT DISTINCT
    c.Calculation_UUID,
    'reads_field'         AS Link_Role,
    oc.Object_UUID        AS Target_UUID,
    'Field'               AS Target_Type,
    oc.File_Name          AS Target_File,
    (c.File_Name != oc.File_Name) AS Is_Cross_File
FROM CalculationsCatalog c
JOIN StepsForScripts s
  ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
JOIN XMLCalcReferences x
  ON x.Source_Type   = 'Script'
 AND x.Source_UUID   = s.Script_UUID
 AND x.File_Name     = c.File_Name
 AND x.Source_Subkey = s.Step_Index::VARCHAR
 AND x.Subrole IS NOT DISTINCT FROM c.Edge_Subrole
 AND x.Ref_Type = 'field'
 AND x.Ref_UUID IS NOT NULL
JOIN ObjectCatalog oc
  ON oc.Object_UUID = x.Ref_UUID AND oc.Object_Type = 'Field'
WHERE c.Owner_Type = 'ScriptStep'

UNION ALL

-- (2b) ScriptStep → CustomFunction (Spiegel Block 31: namensbasiert, datei-lokal)
SELECT DISTINCT
    c.Calculation_UUID,
    'calls_customfunction' AS Link_Role,
    cf.CF_UUID             AS Target_UUID,
    'CustomFunction'       AS Target_Type,
    cf.File_Name           AS Target_File,
    FALSE                  AS Is_Cross_File
FROM CalculationsCatalog c
JOIN StepsForScripts s
  ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
JOIN XMLCalcReferences x
  ON x.Source_Type   = 'Script'
 AND x.Source_UUID   = s.Script_UUID
 AND x.File_Name     = c.File_Name
 AND x.Source_Subkey = s.Step_Index::VARCHAR
 AND x.Subrole IS NOT DISTINCT FROM c.Edge_Subrole
 AND x.Ref_Type = 'customfunction'
 AND x.Ref_Name IS NOT NULL
JOIN CustomFunctionsCatalog cf
  ON cf.CF_Name = x.Ref_Name AND cf.File_Name = x.File_Name
 AND (cf.Folder_Type IS NULL OR cf.Folder_Type = 'False')
 AND NOT COALESCE(cf.Is_Separator, FALSE)
WHERE c.Owner_Type = 'ScriptStep'

UNION ALL

-- (2c) ScriptStep → BuiltinFunction (Spiegel Block 33 inkl. Get(<Sub>))
SELECT DISTINCT
    c.Calculation_UUID,
    'calls_function'       AS Link_Role,
    md5('BuiltinFunction::' ||
        CASE WHEN x.Ref_Name = 'Get' AND x.Ref_SubName IS NOT NULL
             THEN x.Ref_Name || '::' || x.Ref_SubName
             ELSE x.Ref_Name END) AS Target_UUID,
    'BuiltinFunction'      AS Target_Type,
    CAST(NULL AS VARCHAR)  AS Target_File,
    FALSE                  AS Is_Cross_File
FROM CalculationsCatalog c
JOIN StepsForScripts s
  ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
JOIN XMLCalcReferences x
  ON x.Source_Type   = 'Script'
 AND x.Source_UUID   = s.Script_UUID
 AND x.File_Name     = c.File_Name
 AND x.Source_Subkey = s.Step_Index::VARCHAR
 AND x.Subrole IS NOT DISTINCT FROM c.Edge_Subrole
 AND x.Ref_Type = 'function'
 AND x.Ref_Name IS NOT NULL AND x.Ref_Name != ''
WHERE c.Owner_Type = 'ScriptStep'

UNION ALL

-- (2d) ScriptStep → PluginFunction (Spiegel Block 34; dynamische MBS-Aufrufe
-- ohne SubName fallen wie dort heraus)
SELECT DISTINCT
    c.Calculation_UUID,
    'calls_pluginfunction' AS Link_Role,
    md5('PluginFunction::' || p.Plugin_Function_Name || '::' ||
        COALESCE(msm.SubName, '')) AS Target_UUID,
    'PluginFunction'       AS Target_Type,
    CAST(NULL AS VARCHAR)  AS Target_File,
    FALSE                  AS Is_Cross_File
FROM CalculationsCatalog c
JOIN StepsForScripts s
  ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
JOIN PluginFunctionUsages p
  ON p.Source_Type   = 'Script'
 AND p.Source_UUID   = s.Script_UUID
 AND p.File_Name     = c.File_Name
 AND p.Source_Subkey = s.Step_Index::VARCHAR
 AND p.Subrole IS NOT DISTINCT FROM c.Edge_Subrole
LEFT JOIN MBS_SubnameMap msm
  ON msm.Calc_UUID = p.Calc_UUID
 AND msm.File_Name = p.File_Name
 AND msm.Plugin_Chunk_Index = p.Plugin_Chunk_Index
WHERE c.Owner_Type = 'ScriptStep'
  AND p.Plugin_Function_Name IS NOT NULL
  AND p.Plugin_Function_Name != ''
  AND (msm.SubName IS NOT NULL OR p.Plugin_Function_Name != 'MBS');
