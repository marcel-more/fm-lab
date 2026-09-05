/*
-- convert_xml_02_resolve.sql — Phase 2 der XML-Konvertierungs-Pipeline.
-- Löst die Verschränkungs-/Referenz-Tabellen
-- auf, die aus den P1-Roh-Katalogen abgeleitet werden:
--   • XMLStepReferences   (Cluster 1)
--   • XMLLayoutReferences  (Cluster 2)
--   • MBS_SubnameMap + GetSubparameterMap          (Cluster 3)
--   • XMLCalcReferences + PluginFunctionUsages     (Cluster 4)
--
-- TABLE-ONLY (Schritt 2 abgeschlossen): Diese Phase liest AUSSCHLIESSLICH aus
-- den P1-Tabellen (inkl. der Roh-XML-Spalten Step_XML/Object_XML/Parameters_XML
-- via xml_extract_* auf Spaltenwerten) — KEIN read_xml mehr. Sie verarbeitet alle
-- Dateien auf einmal (DELETE-then-INSERT pro Tabelle, File_Name-Filter entfallen)
-- und läuft daher genau EINMAL nach allen P1-Importen (das
-- Skill-Skript ruft sie batch-einmalig auf, analog zu create_universal_catalogs.sql).
-- Schema-Persistenz (SchemaInfo) bleibt in convert_xml_01_extract.sql — diese Datei
-- schreibt KEINE SchemaInfo.
*/

INSTALL webbed FROM community;
LOAD webbed;   -- xml_extract_* auf Spaltenwerten (Step_XML/Object_XML/Parameters_XML); kein read_xml

-- Workaround-Disable-Flag (Version-Check-Registry ingestion/version_check.json,
-- Capability fragment_utf8/#108 → wa_entity_decode, Default ON). Gatet den html_unescape-
-- Decode der Namensspalten unten; OFF (sobald webbed Fragmente als literales UTF-8 statt
-- &#xNN; serialisiert) → Roh-Wert unveraendert. Idempotent → identitaets-neutral solange ON.
SET VARIABLE wa_entity_decode = true;

-- ============================================
-- XMLStepReferences (ersetzt Python extract_xml_references.py)
-- ============================================
-- Extrahiert UUID-Referenzen direkt aus dem XML per xml_extract_text().
-- Kein JSON-Umweg, kein Escaping-Problem.
CREATE TABLE IF NOT EXISTS XMLStepReferences (
    Script_UUID VARCHAR,
    Step_UUID VARCHAR,
    Step_Name VARCHAR,
    Step_Index VARCHAR,
    Ref_Type VARCHAR,            -- 'field' | 'script' | 'layout' | 'variable'
    Ref_UUID VARCHAR,            -- bei Ref_Type='variable': NULL
    Ref_Name VARCHAR,
    File_Name VARCHAR,
    -- v2.0 Erweiterungen:
    TO_Name VARCHAR,             -- nur Ref_Type='field' (Set Field / GTF / GTRR)
    TO_UUID VARCHAR,             -- analog
    Data_Source_Name VARCHAR,    -- nur Ref_Type='script' Cross-File (Perform Script from file)
    Data_Source_UUID VARCHAR,    -- analog
    Variable_Scope VARCHAR,      -- nur Ref_Type='variable': 'local'|'global'|'superglobal'|'let_local'
    Usage_Type VARCHAR,          -- nur Ref_Type='variable': 'set' (Set-Variable-Step-Definition)
    -- UUID-Healing (Schema 1.19.0): FileMaker-interne @id des Referenz-Elements
    -- (ScriptReference/LayoutReference/FieldReference/…). Das SaXML referenziert als
    -- Tripel id+name+UUID; die @id disambiguiert Intra-File-UUID-Duplikate in der
    -- P4-Rewrite-Stufe. NULL bei Ref_Type='variable' (kein Referenz-Element).
    Ref_ID BIGINT,
    -- Kontext-TO-@id (nur Ref_Type='field'): FieldReference/@id ist TABELLEN-lokal —
    -- der Feld-Schlüssel ist zweistufig über TableOccurrenceReference/@id → BaseTable.
    TO_Ref_ID BIGINT
);

-- Additive Migration für Bestands-DBs (idempotent — neuer Bau setzt sie via CREATE).
ALTER TABLE XMLStepReferences ADD COLUMN IF NOT EXISTS TO_Name VARCHAR;
ALTER TABLE XMLStepReferences ADD COLUMN IF NOT EXISTS TO_UUID VARCHAR;
ALTER TABLE XMLStepReferences ADD COLUMN IF NOT EXISTS Data_Source_Name VARCHAR;
ALTER TABLE XMLStepReferences ADD COLUMN IF NOT EXISTS Data_Source_UUID VARCHAR;
ALTER TABLE XMLStepReferences ADD COLUMN IF NOT EXISTS Variable_Scope VARCHAR;
ALTER TABLE XMLStepReferences ADD COLUMN IF NOT EXISTS Usage_Type VARCHAR;
ALTER TABLE XMLStepReferences ADD COLUMN IF NOT EXISTS Ref_ID BIGINT;
ALTER TABLE XMLStepReferences ADD COLUMN IF NOT EXISTS TO_Ref_ID BIGINT;

-- Bestehende Einträge entfernen (Idempotenz; batch-weiter DELETE — P2 läuft
-- einmal für alle Dateien bzw. je Slice in eine frische Part-DB)
DELETE FROM XMLStepReferences WHERE TRUE;

-- Quelle: StepsForScripts-Tabelle.
-- Step-UUID/Name/Index stammen aus Spalten; alle Referenzen (Script/Field/Layout/
-- TableOccurrence/DataSource/Name) werden aus Step_XML (vollständiges <Step>-Element)
-- gelesen — byte-identisch zur früheren Extraktion aus der Roh-XML (kein read_xml mehr).
-- Step_XML statt Parameters_XML, weil manche Step-Typen (z.B. "missing plug-in")
-- Referenzen AUSSERHALB von ParameterValues ablegen.

-- Perform Script → ScriptReference
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'script' as Ref_Type,
    ref_uuid as Ref_UUID,
    NULLIF(xml_extract_text(Step_XML, '//ScriptReference/@name')[1], '') as Ref_Name,
    File_Name,
    NULL AS TO_Name, NULL AS TO_UUID,
    -- Cross-File-Detection: <DataSourceReference> vor <ScriptReference> markiert externen Aufruf.
    -- NULLIF, weil xml_extract_text leere Strings für nicht-existente Elemente liefert.
    NULLIF(xml_extract_text(Step_XML, '//DataSourceReference/@name')[1], '') AS Data_Source_Name,
    NULLIF(xml_extract_text(Step_XML, '//DataSourceReference/@UUID')[1], '') AS Data_Source_UUID,
    NULL AS Variable_Scope, NULL AS Usage_Type,
    TRY_CAST(NULLIF(xml_extract_text(Step_XML, '//ScriptReference/@id')[1], '') AS BIGINT) AS Ref_ID,
    NULL AS TO_Ref_ID
FROM (
    -- Opt 3A (Resolve-Query-Dedup): //ScriptReference/@UUID nur EINMAL parsen statt in
    -- SELECT *und* WHERE; der LIKE-Vorfilter hält den Parse auf Perform-Script-Steps
    -- beschränkt. Die übrigen (Select-only-)Extrakte bleiben außen → werden erst für die
    -- gefilterten Zeilen ausgewertet (parse-count ≤ vorher; Output bit-identisch).
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name, Step_XML,
           NULLIF(xml_extract_text(Step_XML, '//ScriptReference/@UUID')[1], '') AS ref_uuid  -- B-R4: ''→NULL
    FROM StepsForScripts
    WHERE Step_ID IN (1, 164, 210)  -- 'Perform Script' / 'On Server' / 'On Server with Callback'
                                    -- (Step-ID statt lokalisiertem Namen — SaXML schreibt @name in der UI-Sprache)
)
WHERE ref_uuid IS NOT NULL OR Ref_Name IS NOT NULL;  -- Name-only = externe Referenz (P4 löst auf)

-- Alle Step-Typen mit eingebetteten <FieldReference>-Elementen
-- Universelle Erfassung: unnest jeder FieldReference im Step_XML → eine Zeile pro
-- Feld. Step-Filter entfällt — XPath '//FieldReference' matched in 22 Step-Typen
-- (Set Field, Sort Records, Import Records, Perform Find, Replace Field Contents,
-- Show Custom Dialog, etc.). TO-Auflösung relativ zur FieldReference, damit Steps
-- mit mehreren Feld-TO-Paaren (Import Records) korrekt aufgelöst werden.
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'field' as Ref_Type,
    ref_uuid as Ref_UUID,
    ref_name as Ref_Name,
    File_Name,
    -- TO-Auflösung relativ zum FieldReference-Element
    NULLIF(xml_extract_text(field_ref_xml, '/FieldReference/TableOccurrenceReference/@name')[1], '') AS TO_Name,
    NULLIF(xml_extract_text(field_ref_xml, '/FieldReference/TableOccurrenceReference/@UUID')[1], '') AS TO_UUID,
    NULL AS Data_Source_Name, NULL AS Data_Source_UUID,
    NULL AS Variable_Scope, NULL AS Usage_Type,
    TRY_CAST(NULLIF(xml_extract_text(field_ref_xml, '/FieldReference/@id')[1], '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(xml_extract_text(field_ref_xml, '/FieldReference/TableOccurrenceReference/@id')[1], '') AS BIGINT) AS TO_Ref_ID
FROM (
    -- Opt 3A: /FieldReference/@UUID + @name je EINMAL parsen (vorher SELECT+WHERE doppelt);
    -- field_ref_xml bleibt durchgereicht für die gefilterten Select-only-Extrakte.
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name, field_ref_xml,
           xml_extract_text(field_ref_xml, '/FieldReference/@UUID')[1] AS ref_uuid,
           xml_extract_text(field_ref_xml, '/FieldReference/@name')[1] AS ref_name
    FROM (
        SELECT
            Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name,
            unnest(xml_extract_elements(Step_XML, '//FieldReference')) as field_ref_xml
        FROM StepsForScripts
        -- Opt 3A: LIKE-Vorfilter überspringt Steps ohne FieldReference komplett (kein DOM-Parse).
        -- Ein XPath-Match auf //FieldReference impliziert den Substring → kein Treffer fällt weg
        -- (gleiche Superset-Logik wie der Script-Ref-Footprint-Fix weiter unten).
        WHERE Step_XML LIKE '%FieldReference%'
    )
)
WHERE ref_uuid IS NOT NULL
  -- Import-Records-Platzhalter ausfiltern: nicht zugeordnete Quellspalten einer
  -- Importzuordnung stehen als '<FieldReference id="0" name="" UUID="">' im Map —
  -- weder Name noch UUID → keine echte Feldreferenz (sonst ~14,8k dangling
  -- imports_to_field-Links + „Ziel nicht im Datenbestand" in der Step-Anzeige).
  AND NOT (COALESCE(ref_uuid, '') = '' AND COALESCE(ref_name, '') = '');

-- Go to Related Record → TableOccurrenceReference
-- GTRR enthält kein <FieldReference>; das Ziel ist die TO. Heimat/Cross-File werden
-- im Template über TableOccurrenceResolution aufgelöst (Ref_UUID = TO_UUID, File_Name
-- = Quelldatei des Scripts).
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'tableOccurrence' as Ref_Type,
    ref_uuid as Ref_UUID,
    NULLIF(xml_extract_text(Step_XML, '//TableOccurrenceReference/@name')[1], '') as Ref_Name,
    File_Name,
    -- TO_Name/TO_UUID-Spalten redundant für tableOccurrence-Refs (Ref_UUID/Ref_Name
    -- enthalten dieselbe Info). NULL hält die Semantik konsistent (TO_* nur für
    -- Field-Refs gefüllt, wo es das *Kontext*-TO eines Felds beschreibt).
    NULL AS TO_Name, NULL AS TO_UUID,
    NULL AS Data_Source_Name, NULL AS Data_Source_UUID,
    NULL AS Variable_Scope, NULL AS Usage_Type,
    TRY_CAST(NULLIF(xml_extract_text(Step_XML, '//TableOccurrenceReference/@id')[1], '') AS BIGINT) AS Ref_ID,
    NULL AS TO_Ref_ID
FROM (
    -- Opt 3A: //TableOccurrenceReference/@UUID nur EINMAL parsen (vorher SELECT+WHERE).
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name, Step_XML,
           NULLIF(xml_extract_text(Step_XML, '//TableOccurrenceReference/@UUID')[1], '') AS ref_uuid  -- B-R4: ''→NULL
    FROM StepsForScripts
    WHERE Step_ID = 74  -- 'Go to Related Record' (Step-ID statt lokalisiertem Namen)
)
WHERE ref_uuid IS NOT NULL OR Ref_Name IS NOT NULL;  -- Name-only = externe Referenz (P4 löst auf)

-- Go to Related Record → LayoutReference
-- Variante A (~92%) hat <LayoutReference> innerhalb von <LayoutReferenceContainer>.
-- Variante B ("original layout") hat nur <LayoutReferenceContainer> mit <Label> —
-- der XPath //LayoutReference/@UUID matcht dann nichts → kein INSERT.
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'layout' as Ref_Type,
    ref_uuid as Ref_UUID,
    NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@name')[1], '') as Ref_Name,
    File_Name,
    NULL AS TO_Name, NULL AS TO_UUID,
    NULL AS Data_Source_Name, NULL AS Data_Source_UUID,
    NULL AS Variable_Scope, NULL AS Usage_Type,
    TRY_CAST(NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@id')[1], '') AS BIGINT) AS Ref_ID,
    NULL AS TO_Ref_ID
FROM (
    -- Opt 3A: //LayoutReference/@UUID nur EINMAL parsen (vorher SELECT+WHERE).
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name, Step_XML,
           NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@UUID')[1], '') AS ref_uuid  -- B-R4: ''→NULL
    FROM StepsForScripts
    WHERE Step_ID = 74  -- 'Go to Related Record'
)
WHERE ref_uuid IS NOT NULL OR Ref_Name IS NOT NULL;  -- Name-only = externe Referenz (P4 löst auf)

-- Go to Layout → LayoutReference
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'layout' as Ref_Type,
    ref_uuid as Ref_UUID,
    NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@name')[1], '') as Ref_Name,
    File_Name,
    NULL AS TO_Name, NULL AS TO_UUID,
    NULL AS Data_Source_Name, NULL AS Data_Source_UUID,
    NULL AS Variable_Scope, NULL AS Usage_Type,
    TRY_CAST(NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@id')[1], '') AS BIGINT) AS Ref_ID,
    NULL AS TO_Ref_ID
FROM (
    -- Opt 3A: //LayoutReference/@UUID nur EINMAL parsen (vorher SELECT+WHERE).
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name, Step_XML,
           NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@UUID')[1], '') AS ref_uuid  -- B-R4: ''→NULL
    FROM StepsForScripts
    WHERE Step_ID = 6  -- 'Go to Layout'
)
WHERE ref_uuid IS NOT NULL OR Ref_Name IS NOT NULL;  -- Name-only = externe Referenz (P4 löst auf)

-- New Window → LayoutReference
-- "New Window"/Card-Steps tragen ihr Ziel-Layout in WindowReference/
-- LayoutReferenceContainer/LayoutReference. Ohne diesen Block erschien ein
-- Layout, das NUR als New-Window-/Card-Ziel dient, als ungenutzt (gleiche
-- Lückenklasse wie das geschlossene GTRR-TO-Loch). Steps mit "current layout"
-- (LayoutReferenceContainer value=0, kein LayoutReference-Element) fallen durch
-- den ref_uuid-Filter — nur echte Layout-Ziele werden erfasst. Der Graph-Link
-- entsteht im bestehenden P4-Block (Ref_Type='layout' → navigates_to_layout).
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'layout' as Ref_Type,
    ref_uuid as Ref_UUID,
    NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@name')[1], '') as Ref_Name,
    File_Name,
    NULL AS TO_Name, NULL AS TO_UUID,
    NULL AS Data_Source_Name, NULL AS Data_Source_UUID,
    NULL AS Variable_Scope, NULL AS Usage_Type,
    TRY_CAST(NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@id')[1], '') AS BIGINT) AS Ref_ID,
    NULL AS TO_Ref_ID
FROM (
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name, Step_XML,
           NULLIF(xml_extract_text(Step_XML, '//LayoutReference/@UUID')[1], '') AS ref_uuid  -- B-R4: ''→NULL
    FROM StepsForScripts
    WHERE Step_ID = 122  -- 'New Window'
)
WHERE ref_uuid IS NOT NULL OR Ref_Name IS NOT NULL;  -- Name-only = externe Referenz (P4 löst auf)

-- Install Menu Set → CustomMenuSetReference
-- Der Step trägt das Ziel-Menüset in ParameterValues/Parameter/CustomMenuSetReference.
-- Ref_Type='menuset' → P4 erzeugt daraus Script → CustomMenuSet (installs_menuset);
-- vorher waren Menüsets, die nur per Script installiert werden, unverlinkt
-- („tote Knoten"). Das Boolean-Kind "Use as file default" bleibt im Step_XML
-- abfragbar (keine eigene Spalte).
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'menuset' as Ref_Type,
    ref_uuid as Ref_UUID,
    NULLIF(xml_extract_text(Step_XML, '//CustomMenuSetReference/@name')[1], '') as Ref_Name,
    File_Name,
    NULL AS TO_Name, NULL AS TO_UUID,
    NULL AS Data_Source_Name, NULL AS Data_Source_UUID,
    NULL AS Variable_Scope, NULL AS Usage_Type,
    TRY_CAST(NULLIF(xml_extract_text(Step_XML, '//CustomMenuSetReference/@id')[1], '') AS BIGINT) AS Ref_ID,
    NULL AS TO_Ref_ID
FROM (
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name, Step_XML,
           NULLIF(xml_extract_text(Step_XML, '//CustomMenuSetReference/@UUID')[1], '') AS ref_uuid  -- B-R4: ''→NULL
    FROM StepsForScripts
    WHERE Step_ID = 142  -- 'Install Menu Set'
)
WHERE ref_uuid IS NOT NULL;

-- Sort Records → ValueListReference (Custom-Sortierung nach Werteliste)
-- Eine „Custom sort order" trägt ihre Referenz-Werteliste als <ValueListReference>
-- neben dem <PrimaryField> im <Sort type="Custom">-Element. Ein Sort-Records-Step
-- kann mehrere Sortier-Kriterien (mehrere <Sort>) haben → mehrere ValueListReference-
-- Elemente pro Step (unnest, analog zum universellen FieldReference-Block oben).
-- Ref_Type='valuelist' → P4 erzeugt daraus Script → ValueList (sorts_by_valuelist);
-- vorher war eine NUR als Sortier-Referenz genutzte Werteliste unverlinkt (erschien
-- in Where-used/Dead-Code als ungenutzt).
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'valuelist' as Ref_Type,
    ref_uuid as Ref_UUID,
    ref_name as Ref_Name,
    File_Name,
    NULL AS TO_Name, NULL AS TO_UUID,
    NULL AS Data_Source_Name, NULL AS Data_Source_UUID,
    NULL AS Variable_Scope, NULL AS Usage_Type,
    ref_id AS Ref_ID,
    NULL AS TO_Ref_ID
FROM (
    -- @UUID + @name je Element EINMAL parsen; vl_ref_xml ist das einzelne
    -- <ValueListReference>-Fragment (unnest liefert eine Zeile pro Vorkommen).
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name,
           xml_extract_text(vl_ref_xml, '/ValueListReference/@UUID')[1] AS ref_uuid,
           xml_extract_text(vl_ref_xml, '/ValueListReference/@name')[1] AS ref_name,
           TRY_CAST(NULLIF(xml_extract_text(vl_ref_xml, '/ValueListReference/@id')[1], '') AS BIGINT) AS ref_id
    FROM (
        SELECT
            Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name,
            unnest(xml_extract_elements(Step_XML, '//ValueListReference')) as vl_ref_xml
        FROM StepsForScripts
        -- LIKE-Vorfilter überspringt Steps ohne ValueListReference (Superset; kein
        -- Treffer fällt weg). Step_ID=39 grenzt auf 'Sort Records' ein — der einzige
        -- Step-Typ, der eine Werteliste referenziert.
        WHERE Step_ID = 39  -- 'Sort Records'
          AND Step_XML LIKE '%ValueListReference%'
    )
)
WHERE ref_uuid IS NOT NULL AND ref_uuid <> '';


-- Set Variable → <Name value="$X"> als Definition (LHS, Usage_Type='set')
-- Die RHS-Lesung kommt über DDR-Calc-Chunks und landet in XMLCalcReferences
-- (Ref_Type='variable', Usage_Type='read'). Damit haben wir saubere Trennung
-- Definition vs. Lesung — Voraussetzung für Cross-Step-Navigation.
INSERT INTO XMLStepReferences
SELECT
    Script_UUID,
    Step_UUID,
    Step_Name,
    Step_Index::VARCHAR AS Step_Index,
    'variable' as Ref_Type,
    NULL as Ref_UUID,
    -- <Name value="$X"> liegt unterhalb von ParameterValues/Parameter/Name
    name_value as Ref_Name,
    File_Name,
    NULL AS TO_Name, NULL AS TO_UUID,
    NULL AS Data_Source_Name, NULL AS Data_Source_UUID,
    -- Scope-Detektor: $$$ → superglobal, $$ → global, $ → local. Reihenfolge wichtig
    -- (LIKE '$$$%' muss vor LIKE '$$%' stehen — sonst werden $$$ als $$ erkannt).
    CASE
        WHEN name_value LIKE '$$$%' THEN 'superglobal'
        WHEN name_value LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END AS Variable_Scope,
    'set' AS Usage_Type,
    NULL AS Ref_ID,      -- Variablen tragen kein Referenz-Element (keine FM-@id)
    NULL AS TO_Ref_ID
FROM (
    -- Opt 3A: //Name/@value nur EINMAL parsen (vorher 5× pro Zeile: SELECT + CASE×2 + WHERE×2).
    SELECT Script_UUID, Step_UUID, Step_Name, Step_Index, File_Name,
           xml_extract_text(Step_XML, '//Name/@value')[1] AS name_value
    FROM StepsForScripts
    WHERE Step_ID = 141  -- 'Set Variable'
)
WHERE name_value IS NOT NULL
  AND name_value <> '';

-- HINWEIS: Die Cross-File-Auflösung leerer Referenz-UUIDs (External GTRR / Go-to-Layout /
-- Perform-Script + TO-relative Feldbezüge) UND der Step_UUID-Index liegen NICHT hier,
-- sondern in Phase 4 (convert_xml_04_catalog.sql, ganz oben). Grund: P2 läuft im Batch
-- DATEI-PARTITIONIERT (je Slice nur die eigenen Dateien als gefilterte `src`-Views), die
-- Auflösung ist aber DATEI-ÜBERGREIFEND und batch-weit — sie muss auf der fertig gemergten
-- Master-XMLStepReferences laufen, nicht je Slice. Der Import-Platzhalter-Filter im
-- Feld-INSERT oben bleibt hier (rein per-Datei → partitionssicher).

-- ============================================
-- XMLLayoutReferences (ersetzt Python extract_xml_references.py)
-- ============================================
-- Extrahiert UUID-Referenzen aus LayoutObjects direkt per xml_extract_text().
CREATE TABLE IF NOT EXISTS XMLLayoutReferences (
    Object_UUID VARCHAR,
    Ref_Type VARCHAR,
    Ref_UUID VARCHAR,
    Ref_Name VARCHAR,
    File_Name VARCHAR,
    -- Step-ID des button-eingebetteten Script-Steps (nur Ref_Type='field_step';
    -- sonst NULL). Trägt die locale-unabhängige Rollen-Zuordnung in P4 (ScriptStepRoleMap),
    -- analog zum Script→Field-Block. Additive Spalte (Schema-Bump unkritisch, P2-Tabelle
    -- ist volatil und wird je Lauf neu befüllt).
    Step_ID BIGINT,
    -- UUID-Healing (Schema 1.19.0): FileMaker-interne @id des Referenz-Elements
    -- (Tripel id+name+UUID im SaXML) — disambiguiert Intra-File-UUID-Duplikate in der
    -- P4-Rewrite-Stufe. TO_Ref_ID = Kontext-TO-@id (nur Feld-Referenzen: FieldReference/@id
    -- ist TABELLEN-lokal, der Feld-Schlüssel läuft zweistufig über die TO).
    Ref_ID BIGINT,
    TO_Ref_ID BIGINT
);

-- Additive Migration für Bestands-DBs (idempotent — neuer Bau setzt sie via CREATE).
ALTER TABLE XMLLayoutReferences ADD COLUMN IF NOT EXISTS Step_ID BIGINT;
ALTER TABLE XMLLayoutReferences ADD COLUMN IF NOT EXISTS Ref_ID BIGINT;
ALTER TABLE XMLLayoutReferences ADD COLUMN IF NOT EXISTS TO_Ref_ID BIGINT;

-- Bestehende Einträge entfernen (Idempotenz; batch-weiter DELETE — P2 läuft
-- einmal für alle Dateien bzw. je Slice in eine frische Part-DB)
DELETE FROM XMLLayoutReferences WHERE TRUE;

-- Feld-Referenzen: LayoutObject/Field/FieldReference/@UUID
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Ref_ID, TO_Ref_ID)
SELECT
    object_uuid as Object_UUID,
    'field' as Ref_Type,
    -- K4 (Empty-String-Hygiene): externe-TO-Feldreferenzen tragen UUID="" → xml_extract
    -- liefert '' statt NULL. NULLIF hebt das auf NULL; die Zeile BLEIBT (Guard unten hält
    -- reale + ''-UUIDs), damit der Feldname fürs spätere Auflösen (TO+Feld-id, s.u.) erhalten
    -- bleibt. Ohne NULLIF joint P4 displays_field auf '' → Orphan-Link statt sauberer NULL.
    NULLIF(ref_uuid, '') as Ref_UUID,
    NULLIF(xml_extract_text(object_xml, '/LayoutObject/Field/FieldReference/@name')[1], '') as Ref_Name,
    File_Name,
    TRY_CAST(NULLIF(xml_extract_text(object_xml, '/LayoutObject/Field/FieldReference/@id')[1], '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(xml_extract_text(object_xml, '/LayoutObject/Field/FieldReference/TableOccurrenceReference/@id')[1], '') AS BIGINT) AS TO_Ref_ID
FROM (
    -- Opt 3A: UUID + FieldReference/@UUID je EINMAL parsen (vorher SELECT+WHERE doppelt);
    -- object_xml bleibt durchgereicht für den gefilterten Select-only-@name-Extrakt.
    SELECT Object_XML AS object_xml, File_Name,
           Object_UUID AS object_uuid,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
           xml_extract_text(Object_XML, '/LayoutObject/Field/FieldReference/@UUID')[1] AS ref_uuid
    FROM LayoutObjects
    -- Opt 3A: LIKE-Vorfilter überspringt Objekte ohne FieldReference (Superset; kein Treffer fällt weg).
    WHERE Object_XML LIKE '%FieldReference%'
)
WHERE object_uuid IS NOT NULL
  AND ref_uuid IS NOT NULL;

-- Merge-Feld-Referenzen: <<Tabelle::Feld>> in Text-Objekten liegt als
-- /LayoutObject/FieldList/FieldReference (ein Element je Merge-Feld). Ohne diesen
-- Block hatten Text-Objekte mit Merge-Feldern KEINEN displays_field-Link (Merge-
-- VARIABLEN sind separat abgedeckt). Direkte Kind-Achse statt '//': Container-
-- Object_XML enthält die Kind-Objekte mit — die Descendant-Achse würde deren
-- Merge-Felder zusätzlich dem Container zuschreiben. Mehrere Merge-Felder pro
-- Objekt → parallele @UUID/@name-Listen, positionsweise gezippt (Muster/Nachweis
-- wie ScriptReference-Block unten; Korpus: 298 Text-Objekte → 414 Refs, 0 Mismatch).
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Ref_ID, TO_Ref_ID)
-- K4: leere Merge-Feld-UUID → NULL (analog zum Field-Block oben); Guard unten hält reale + ''.
SELECT Object_UUID, 'field' AS Ref_Type, NULLIF(Ref_UUID, '') AS Ref_UUID, NULLIF(Ref_Name, '') AS Ref_Name, File_Name,
       TRY_CAST(NULLIF(Ref_ID_raw, '') AS BIGINT) AS Ref_ID,
       TRY_CAST(NULLIF(TO_Ref_ID_raw, '') AS BIGINT) AS TO_Ref_ID
FROM (
    -- Ausrichtungs-Guard für die Zusatz-Listen: nur zippen, wenn die Liste exakt so lang
    -- ist wie die @UUID-Liste (jede FieldReference hat ≤1 TO-Kind → Längengleichheit
    -- impliziert Positionstreue). Bei Mismatch degradiert die GANZE Liste zu NULL
    -- (paralleles unnest padded mit NULL) statt falsch zuzuordnen.
    SELECT ou AS Object_UUID, unnest(uuids) AS Ref_UUID, unnest(names) AS Ref_Name,
           unnest(CASE WHEN len(ids)    = len(uuids) THEN ids    ELSE NULL END) AS Ref_ID_raw,
           unnest(CASE WHEN len(to_ids) = len(uuids) THEN to_ids ELSE NULL END) AS TO_Ref_ID_raw,
           File_Name
    FROM (
        SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
               xml_extract_text(Object_XML, '/LayoutObject/FieldList/FieldReference/@UUID') AS uuids,
               xml_extract_text(Object_XML, '/LayoutObject/FieldList/FieldReference/@name') AS names,
               xml_extract_text(Object_XML, '/LayoutObject/FieldList/FieldReference/@id') AS ids,
               xml_extract_text(Object_XML, '/LayoutObject/FieldList/FieldReference/TableOccurrenceReference/@id') AS to_ids,
               File_Name
        FROM LayoutObjects
        WHERE Object_XML LIKE '%<FieldList>%'
    )
    WHERE ou IS NOT NULL AND len(uuids) > 0
)
WHERE Ref_UUID IS NOT NULL;

-- Script-Referenzen: //ScriptReference mit Ancestor-Guard — nur EIGENE Referenzen.
-- Container-Object_XML (Portal, Tab Control, Panel, Group, Button Bar, Popover
-- Button, Grouped Button, …) enthält die verschachtelten Kind-Objekte als
-- <LayoutObject>-Elemente mit; die nackte Descendant-Achse schrieb deren Script-
-- Refs (Kind-Trigger, Segment-Buttons) zusätzlich dem Container zu — auf jeder
-- Verschachtelungsebene eine Kopie (Phantom-Kanten, falsche button_action-Labels
-- in P4 Block 21b). Der Guard behält nur Refs mit genau EINEM LayoutObject-
-- Vorfahren (= der Objekt-Wurzel selbst): eigene Trigger-Refs und eigene
-- Action-Refs; Kinder tragen ihre Refs bereits als eigene Zeilen. Eigene
-- Container-Trigger (z.B. OnPanelSwitch) bleiben erhalten. Der Guard muss auf
-- allen DREI parallelen Listen identisch stehen (Zippungs-Ausrichtung).
-- Verifikation (Korpus, 2.15.0): Guard-Ergebnis == Multiset-Subtraktion
-- r(selbst) − Σ r(direkte Kinder) je (Objekt, Script), 37899 → 28152 Zeilen
-- (−25,7 %, gewollt — die alte Bit-Identitäts-Notiz 38326 galt für den
-- ungefilterten //-Stand), 0 Negativfälle, Kind-Refs unverändert 1:1.
-- P2-Footprint-Fix bleibt: statt
-- unnest(xml_extract_elements(…, '//ScriptReference')) — das DOM-tragende
-- Fragment-Listen materialisiert und den EINZIGEN nicht-spillbaren >1-GB-Peak
-- erzeugte (2298 MB, reproduzierte den 2-GiB-P2-OOM) — werden PARALLELE
-- String-Listen (@UUID ∥ @name ∥ @id) extrahiert und positionsweise gezippt. Die
-- Listen sind je ScriptReference längen-gleich (im Korpus 0 Mismatch), daher
-- ausrichtungstreu; Footprint voll spillbar. LIKE-Vorfilter überspringt Objekte
-- ohne ScriptReference (ein XPath-Match impliziert den Substring → kein Treffer
-- fällt weg; Superset auch zum Guard-Ergebnis).
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Ref_ID)
SELECT Object_UUID, 'script' AS Ref_Type, Ref_UUID, Ref_Name, File_Name,
       TRY_CAST(NULLIF(Ref_ID_raw, '') AS BIGINT) AS Ref_ID
FROM (
    -- Dritte parallele String-Liste (@id) für UUID-Healing; gleicher Footprint-Ansatz
    -- (Strings statt DOM-Fragmente), Ausrichtungs-Guard wie im Merge-Feld-Block.
    SELECT ou AS Object_UUID, unnest(uuids) AS Ref_UUID, unnest(names) AS Ref_Name,
           unnest(CASE WHEN len(ids) = len(uuids) THEN ids ELSE NULL END) AS Ref_ID_raw,
           File_Name
    FROM (
        SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
               xml_extract_text(Object_XML, '//ScriptReference[not(ancestor::LayoutObject/ancestor::LayoutObject)]/@UUID') AS uuids,
               xml_extract_text(Object_XML, '//ScriptReference[not(ancestor::LayoutObject/ancestor::LayoutObject)]/@name') AS names,
               xml_extract_text(Object_XML, '//ScriptReference[not(ancestor::LayoutObject/ancestor::LayoutObject)]/@id') AS ids,
               File_Name
        FROM LayoutObjects
        WHERE Object_XML LIKE '%ScriptReference%'
    )
    WHERE ou IS NOT NULL AND len(uuids) > 0
)
WHERE Ref_UUID IS NOT NULL;

-- ValueList-Referenzen: LayoutObject/Field/Display/ValueListReference/@UUID (NEU)
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Ref_ID)
SELECT
    object_uuid as Object_UUID,
    'valuelist' as Ref_Type,
    ref_uuid as Ref_UUID,
    xml_extract_text(object_xml, '/LayoutObject/Field/Display/ValueListReference/@name')[1] as Ref_Name,
    File_Name,
    TRY_CAST(NULLIF(xml_extract_text(object_xml, '/LayoutObject/Field/Display/ValueListReference/@id')[1], '') AS BIGINT) AS Ref_ID
FROM (
    -- Opt 3A: UUID + ValueListReference/@UUID je EINMAL parsen (vorher SELECT+WHERE doppelt);
    -- object_xml bleibt durchgereicht für den gefilterten Select-only-@name-Extrakt.
    SELECT Object_XML AS object_xml, File_Name,
           Object_UUID AS object_uuid,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
           xml_extract_text(Object_XML, '/LayoutObject/Field/Display/ValueListReference/@UUID')[1] AS ref_uuid
    FROM LayoutObjects
    -- Opt 3A: LIKE-Vorfilter überspringt Objekte ohne ValueListReference (Superset; kein Treffer fällt weg).
    WHERE Object_XML LIKE '%ValueListReference%'
)
WHERE object_uuid IS NOT NULL
  AND ref_uuid IS NOT NULL;

-- Portal → TableOccurrence: /LayoutObject/Portal/TableOccurrenceReference/@UUID (NEU)
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Ref_ID)
SELECT
    object_uuid as Object_UUID,
    'table_occurrence' as Ref_Type,
    ref_uuid as Ref_UUID,
    xml_extract_text(object_xml, '/LayoutObject/Portal/TableOccurrenceReference/@name')[1] as Ref_Name,
    File_Name,
    TRY_CAST(NULLIF(xml_extract_text(object_xml, '/LayoutObject/Portal/TableOccurrenceReference/@id')[1], '') AS BIGINT) AS Ref_ID
FROM (
    -- Opt 3A: Portal/TableOccurrenceReference/@UUID nur EINMAL parsen (vorher SELECT+WHERE);
    -- object_xml durchgereicht für die gefilterten Select-only-Extrakte (UUID + @name).
    -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2).
    SELECT Object_XML AS object_xml, File_Name,
           Object_UUID AS object_uuid,
           xml_extract_text(Object_XML, '/LayoutObject/Portal/TableOccurrenceReference/@UUID')[1] AS ref_uuid
    FROM LayoutObjects
    -- Portal-Vorfilter über die von P1 kanonisierte Object_Type-Spalte, NICHT über den rohen
    -- /LayoutObject/@type-String: der ist im SaXML-Export lokalisiert (dt. „Ausschnitt"), ein
    -- Literalvergleich gegen 'Portal' verwirft dt. Portale still. Das <Portal>-Wrapper-Element
    -- und damit der XPath oben bleiben locale-unabhängig.
    WHERE Object_Type = 'Portal'
)
WHERE ref_uuid IS NOT NULL;

-- Custom-Sort-Werteliste (Portal-Sort + button-eingebetteter Sort-Step) → Ref_Type='valuelist_sort'
-- Eine „Custom sort order" trägt ihre Referenz-Werteliste als <ValueListReference> neben dem
-- <PrimaryField> im <Sort type="Custom">-Element (analog zum Sort-Records-Block über
-- StepsForScripts). Träger im Layout: (a) die SortSpecification des Portals selbst,
-- (b) ein button-eingebetteter Sort-Records-Step (Grouped Button / Button, action/Step).
-- WICHTIG — verankerte Pfade statt '//…': Object_XML enthält den VOLLEN Subtree eines
-- Objekts (inkl. aller Kind-Objekte). Eine //-Extraktion würde die Portal-Sorts zusätzlich
-- an jedem Ancestor-Container (Panel, Tab Control, …) matchen und Duplikat-Links erzeugen.
-- Die absoluten Pfade matchen nur die dem Objekt SELBST gehörende SortSpecification;
-- Kind-Objekte liegen unter …/ObjectList und haben eigene Zeilen. Ein Prädikat
-- [@type="Custom"] ist unnötig: nur Custom-Sorts tragen überhaupt eine ValueListReference,
-- und die Feld-Control-VL (Field/Display/ValueListReference) liegt außerhalb der Pfade.
-- @UUID- und @name-Listen werden positionsweise gezippt (je ValueListReference sind beide
-- Attribute gesetzt; gleiche Ausrichtungs-Annahme wie im ScriptReference-Block oben).
-- P4 erzeugt daraus LayoutObject → ValueList (sorts_by_valuelist, Subrole portal/button);
-- vorher erschien eine NUR als Portal-/Button-Sortier-Referenz genutzte Werteliste
-- in Where-used/Dead-Code als ungenutzt.
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Ref_ID)
SELECT Object_UUID, 'valuelist_sort' AS Ref_Type, Ref_UUID, Ref_Name, File_Name,
       TRY_CAST(NULLIF(Ref_ID_raw, '') AS BIGINT) AS Ref_ID
FROM (
    SELECT ou AS Object_UUID, unnest(uuids) AS Ref_UUID, unnest(names) AS Ref_Name,
           -- Ausrichtungs-Guard wie im Merge-Feld-Block (Mismatch → ganze Liste NULL)
           unnest(CASE WHEN len(ids) = len(uuids) THEN ids ELSE NULL END) AS Ref_ID_raw,
           File_Name
    FROM (
        -- (a) Portal-eigene Sortierung
        SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
               xml_extract_text(Object_XML, '/LayoutObject/Portal/SortSpecification/SortList/Sort/ValueListReference/@UUID') AS uuids,
               xml_extract_text(Object_XML, '/LayoutObject/Portal/SortSpecification/SortList/Sort/ValueListReference/@name') AS names,
               xml_extract_text(Object_XML, '/LayoutObject/Portal/SortSpecification/SortList/Sort/ValueListReference/@id') AS ids,
               File_Name
        FROM LayoutObjects
        WHERE Object_Type = 'Portal'
          AND Object_XML LIKE '%ValueListReference%'
        UNION ALL
        -- (b1) Grouped Button mit eingebettetem Sort-Records-Step
        SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
               xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/ParameterValues/Parameter/SortSpecification/SortList/Sort/ValueListReference/@UUID') AS uuids,
               xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/ParameterValues/Parameter/SortSpecification/SortList/Sort/ValueListReference/@name') AS names,
               xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/ParameterValues/Parameter/SortSpecification/SortList/Sort/ValueListReference/@id') AS ids,
               File_Name
        FROM LayoutObjects
        WHERE Object_Type = 'Grouped Button'
          AND Object_XML LIKE '%ValueListReference%'
        UNION ALL
        -- (b2) Plain Button (Ein-Step-Aktion) — im Korpus 0 Treffer, defensiv abgedeckt
        SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
               xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/ParameterValues/Parameter/SortSpecification/SortList/Sort/ValueListReference/@UUID') AS uuids,
               xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/ParameterValues/Parameter/SortSpecification/SortList/Sort/ValueListReference/@name') AS names,
               xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/ParameterValues/Parameter/SortSpecification/SortList/Sort/ValueListReference/@id') AS ids,
               File_Name
        FROM LayoutObjects
        WHERE Object_Type = 'Button'
          AND Object_XML LIKE '%ValueListReference%'
    )
    WHERE ou IS NOT NULL AND len(uuids) > 0
)
WHERE Ref_UUID IS NOT NULL AND Ref_UUID <> '';

-- ============================================
-- Button-eingebettete Step-Referenzen (generisch) — F-2
-- ============================================
-- FileMaker-Buttons können statt eines Script-Aufrufs einen EINZELNEN eingebetteten
-- Script-Step ausführen (GroupedButton/action/Step, Button/action/Step). Dessen
-- Referenzen (Layout/TO/Feld) erzeugten bisher KEINE Links → Where-used-Lücke
-- (z.B. ein nur per Button erreichbares Layout erschien in unused_layout).
--
-- WICHTIG — verankerte Pfade (wie im valuelist_sort-Block): Object_XML enthält den
-- VOLLEN Subtree. Der action/Step-Subtree ist aber sicher — die Kind-Objekte eines
-- Buttons liegen unter …/ObjectList, NICHT unter action → eine '//'-Suche INNERHALB
-- des am Button verankerten action/Step-Pfads ist duplikatfrei gegenüber Kind-Objekten.
-- FileMaker erlaubt nur EINEN Step je Button.
--
-- SEMANTIK-GATING (analog Script-Seite, P2 XMLStepReferences): Nur NAVIGATIONS-Steps
-- tragen ein echtes Sprung-Ziel. Ein Feld-Step (Go to Field/Sort Records) trägt ZWAR
-- eine TableOccurrenceReference — aber das ist der KONTEXT-TO des Ziel-/Sortier-Felds,
-- KEIN Navigationsziel (die Script-Seite legt ihn in XMLStepReferences.TO_UUID ab,
-- nicht als tableOccurrence-Link). Darum wird die TO-Extraktion auf Step_ID=74 (GTRR)
-- gegated und pro Button skalar ([1]) genommen — genau wie der Script-GTRR-Block.
-- Layout-Refs treten nur in Navigations-Steps (6 Go to Layout, 74 GTRR-Ziel) auf →
-- skalar [1] ohne Gate genügt und ist duplikatfrei.

-- (1) Layout-Referenz (Go to Layout / GTRR-Ziel-Layout) → Ref_Type='layout_step'
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Ref_ID)
SELECT ou AS Object_UUID, 'layout_step' AS Ref_Type, ref_uuid AS Ref_UUID, ref_name AS Ref_Name, File_Name, ref_id AS Ref_ID
FROM (
    SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
           NULLIF(xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step//LayoutReference/@UUID')[1], '') AS ref_uuid,
           xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step//LayoutReference/@name')[1] AS ref_name,
           TRY_CAST(NULLIF(xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step//LayoutReference/@id')[1], '') AS BIGINT) AS ref_id,
           File_Name
    FROM LayoutObjects
    WHERE Object_Type = 'Grouped Button' AND Object_XML LIKE '%<action>%'
    UNION ALL
    SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
           NULLIF(xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step//LayoutReference/@UUID')[1], '') AS ref_uuid,
           xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step//LayoutReference/@name')[1] AS ref_name,
           TRY_CAST(NULLIF(xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step//LayoutReference/@id')[1], '') AS BIGINT) AS ref_id,
           File_Name
    FROM LayoutObjects
    WHERE Object_Type = 'Button' AND Object_XML LIKE '%<action>%'
)
WHERE ou IS NOT NULL AND ref_uuid IS NOT NULL;

-- (2) TableOccurrence-Referenz (NUR GTRR-Ziel-TO, Step_ID=74) → Ref_Type='table_occurrence_step'
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Ref_ID)
SELECT ou AS Object_UUID, 'table_occurrence_step' AS Ref_Type, ref_uuid AS Ref_UUID, ref_name AS Ref_Name, File_Name, ref_id AS Ref_ID
FROM (
    SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
           TRY_CAST(xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/@id')[1] AS BIGINT) AS sid,
           NULLIF(xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step//TableOccurrenceReference/@UUID')[1], '') AS ref_uuid,
           xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step//TableOccurrenceReference/@name')[1] AS ref_name,
           TRY_CAST(NULLIF(xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step//TableOccurrenceReference/@id')[1], '') AS BIGINT) AS ref_id,
           File_Name
    FROM LayoutObjects
    WHERE Object_Type = 'Grouped Button' AND Object_XML LIKE '%<action>%'
    UNION ALL
    SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
           TRY_CAST(xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/@id')[1] AS BIGINT) AS sid,
           NULLIF(xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step//TableOccurrenceReference/@UUID')[1], '') AS ref_uuid,
           xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step//TableOccurrenceReference/@name')[1] AS ref_name,
           TRY_CAST(NULLIF(xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step//TableOccurrenceReference/@id')[1], '') AS BIGINT) AS ref_id,
           File_Name
    FROM LayoutObjects
    WHERE Object_Type = 'Button' AND Object_XML LIKE '%<action>%'
)
WHERE ou IS NOT NULL AND sid = 74 AND ref_uuid IS NOT NULL;

-- (3) Feld-Referenz (Go to Field / Sort Records …) → Ref_Type='field_step'
-- Verankert auf ParameterValues, damit NUR die Step-Parameter-Felder zählen (nicht
-- die FieldReference eines Layout-Controls). Step/@id wird mitgeführt → P4 mappt die
-- Link-Rolle über ScriptStepRoleMap (locale-unabhängig; Fallback references_field).
INSERT INTO XMLLayoutReferences (Object_UUID, Ref_Type, Ref_UUID, Ref_Name, File_Name, Step_ID, Ref_ID, TO_Ref_ID)
SELECT Object_UUID, 'field_step' AS Ref_Type, Ref_UUID, Ref_Name, File_Name, Step_ID,
       TRY_CAST(NULLIF(Ref_ID_raw, '') AS BIGINT) AS Ref_ID,
       TRY_CAST(NULLIF(TO_Ref_ID_raw, '') AS BIGINT) AS TO_Ref_ID
FROM (
    SELECT ou AS Object_UUID, unnest(uuids) AS Ref_UUID, unnest(names) AS Ref_Name,
           -- Ausrichtungs-Guard wie im Merge-Feld-Block (Mismatch → ganze Liste NULL)
           unnest(CASE WHEN len(ids)    = len(uuids) THEN ids    ELSE NULL END) AS Ref_ID_raw,
           unnest(CASE WHEN len(to_ids) = len(uuids) THEN to_ids ELSE NULL END) AS TO_Ref_ID_raw,
           File_Name, sid AS Step_ID
    FROM (
        SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
               TRY_CAST(xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/@id')[1] AS BIGINT) AS sid,
               xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/ParameterValues//FieldReference/@UUID') AS uuids,
               xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/ParameterValues//FieldReference/@name') AS names,
               xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/ParameterValues//FieldReference/@id') AS ids,
               xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/ParameterValues//FieldReference/TableOccurrenceReference/@id') AS to_ids,
               File_Name
        FROM LayoutObjects
        WHERE Object_Type = 'Grouped Button' AND Object_XML LIKE '%<action>%'
        UNION ALL
        SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
               TRY_CAST(xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/@id')[1] AS BIGINT) AS sid,
               xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/ParameterValues//FieldReference/@UUID') AS uuids,
               xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/ParameterValues//FieldReference/@name') AS names,
               xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/ParameterValues//FieldReference/@id') AS ids,
               xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/ParameterValues//FieldReference/TableOccurrenceReference/@id') AS to_ids,
               File_Name
        FROM LayoutObjects
        WHERE Object_Type = 'Button' AND Object_XML LIKE '%<action>%'
    )
    WHERE ou IS NOT NULL AND len(uuids) > 0
)
WHERE Ref_UUID IS NOT NULL AND Ref_UUID <> '';

-- ============================================
-- LayoutObjectSteps — Kern-Attribute des button-eingebetteten Steps
-- ============================================
-- Materialisiert pro Button-Objekt (Grouped Button / Button) den EINEN eingebetteten
-- Script-Step, damit die READ_ONLY-API-Detailansicht ihn als Klartext-Token rendern
-- kann (analog zum Script-Detail). Der API-Server kann webbed NICHT laden → alle
-- xml_extract-Zugriffe müssen HIER (Konvertierung, webbed geladen) passieren.
--   - Step_ID/Step_Name/Step_Enabled: Kopf des Steps (Step_Name ist in der Export-
--     sprache lokalisiert — wie DDR_ScriptSteps.Step_Text, also intern konsistent).
--   - StepText_Hash: DDRREF kind="StepText" → JOIN auf DDR_ScriptSteps.Step_Hash für
--     den FM-generierten Klartext ("Go to Layout [ … ]"). NULL ohne DDR-Info.
-- Verankerte Pfade (/LayoutObject/<Wrapper>/action/Step): NUR der eigene Step des
-- Objekts, nicht die Steps verschachtelter Kind-Buttons (die haben eigene Zeilen).
CREATE TABLE IF NOT EXISTS LayoutObjectSteps (
    Object_UUID   VARCHAR,
    File_Name     VARCHAR,
    Step_ID       BIGINT,
    Step_Name     VARCHAR,
    Step_Enabled  BOOLEAN,
    StepText_Hash VARCHAR,
    PRIMARY KEY (Object_UUID, File_Name)
);

-- Bestehende Einträge entfernen (Idempotenz; batch-weiter DELETE — P2 läuft
-- einmal für alle Dateien bzw. je Slice in eine frische Part-DB). Ohne diesen
-- Clear kollidiert der zweite Lauf gegen dieselbe Master-DB auf dem PRIMARY KEY —
-- bzw. akkumuliert still Duplikate, wenn ein partitionierter Lauf die Tabelle
-- zuvor per DROP+CTAS (ohne PK) neu aufgebaut hat.
DELETE FROM LayoutObjectSteps WHERE TRUE;

INSERT INTO LayoutObjectSteps (Object_UUID, File_Name, Step_ID, Step_Name, Step_Enabled, StepText_Hash)
SELECT ou, File_Name, sid, sname,
       CASE WHEN lower(COALESCE(senable, 'true')) = 'false' THEN FALSE ELSE TRUE END AS Step_Enabled,
       shash
FROM (
    SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
           TRY_CAST(xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/@id')[1] AS BIGINT) AS sid,
           xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/@name')[1] AS sname,
           xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/@enable')[1] AS senable,
           NULLIF(xml_extract_text(Object_XML, '/LayoutObject/GroupedButton/action/Step/DDRREF[@kind=''StepText'']/@hash')[1], '') AS shash,
           File_Name
    FROM LayoutObjects
    WHERE Object_Type = 'Grouped Button' AND Object_XML LIKE '%<action>%<Step %'
    UNION ALL
    SELECT Object_UUID AS ou,  -- Katalogspalte statt Roh-XML: trägt bei geheilten Zwillingen die Ersatz-UUID (H2)
           TRY_CAST(xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/@id')[1] AS BIGINT) AS sid,
           xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/@name')[1] AS sname,
           xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/@enable')[1] AS senable,
           NULLIF(xml_extract_text(Object_XML, '/LayoutObject/Button/action/Step/DDRREF[@kind=''StepText'']/@hash')[1], '') AS shash,
           File_Name
    FROM LayoutObjects
    WHERE Object_Type = 'Button' AND Object_XML LIKE '%<action>%<Step %'
)
WHERE ou IS NOT NULL AND sid IS NOT NULL;

-- ============================================
-- MBS_SubnameMap
-- ============================================
-- Pro `MBS`-PluginFunctionRef-Chunk wird der fachliche MBS-Funktionsname (erstes
-- Argument, z.B. "List.AddPrefix") aus den NoRef-Chunks derselben Calculation
-- ermittelt. Chunk_Index steht in
-- XML-Dokumentreihenfolge — die Pairing-Heuristik nutzt nur die relative
-- Reihenfolge pro Liste:
--   (a) alle MBS-PluginFunctionRef-Chunks und
--   (b) alle NoRef-Chunks mit Pattern `( "..."` (= MBS-Argumentliste)
-- werden nach Chunk_Index sortiert und 1:1 per ROW_NUMBER gemappt.
-- Bei dynamischem ersten Argument (`MBS( $name ; … )`) liefert die NoRef-Liste
-- weniger Treffer als die MBS-Liste — dann bleibt SubName NULL (kein subFunction
-- im Tokens-Output).

CREATE TABLE IF NOT EXISTS MBS_SubnameMap (
    Calc_UUID VARCHAR,
    File_Name VARCHAR,
    Plugin_Chunk_Index BIGINT,    -- Chunk_Index des PluginFunctionRef-Chunks
    SubName VARCHAR,               -- fachlicher MBS-Funktionsname (z.B. "List.AddPrefix")
    PRIMARY KEY (Calc_UUID, File_Name, Plugin_Chunk_Index)
);

-- Idempotenz: bestehende Einträge der aktuellen Datei entfernen
DELETE FROM MBS_SubnameMap WHERE TRUE;

INSERT INTO MBS_SubnameMap
WITH plugin_refs AS (
    -- B-R5: Next_Ref_Index deckelt die Proximity-Suche — ohne Obergrenze paarte
    -- ein dynamisches 1. Argument (MBS($name; …), kein SubName-Chunk) den nächsten
    -- passenden String-Chunk IRGENDWO später in der Formel (falscher SubName statt NULL).
    SELECT d.Calc_UUID, d.File_Name, d.Chunk_Index,
           LEAD(d.Chunk_Index) OVER (PARTITION BY d.Calc_UUID, d.File_Name
                                     ORDER BY d.Chunk_Index) AS Next_Ref_Index
    FROM DDR_Calculations d
    WHERE d.Chunk_Type = 'PluginFunctionRef'
      AND regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'MBS'
),
subname_chunks AS (
    -- Normalize encoded whitespace char-refs (CR/LF/TAB, decimal & hex) to a plain
    -- space BEFORE the `( "<SubName>"` match, so the extraction is serialization-
    -- independent. A newline right after the opening paren — MBS( \n"FM.…"; …) — is
    -- serialized by DOM as the literal entity `&#13;` but by SAX (--streamify) as a
    -- real CR byte. The old regex `\(\s*"` matched the CR (\s) but NOT `&#13;` (the
    -- `&` is not \s) → DOM silently dropped real MBS calls (SubName NULL) that SAX
    -- resolved → DOM≠SAX AND a latent DOM data-loss bug. Decoding the char-refs first
    -- makes both paths agree and recovers the missed calls.
    SELECT Calc_UUID, File_Name, Chunk_Index,
        regexp_extract(norm, '\(\s*"([^"]+)"', 1) AS SubName
    FROM (
        SELECT d.Calc_UUID, d.File_Name, d.Chunk_Index,
            regexp_replace(d.Chunk_Content, '&#(0*(9|10|13)|[xX]0*(9|[aAdD]));', ' ', 'g') AS norm
        FROM DDR_Calculations d
        WHERE d.Chunk_Type = 'NoRef'
    )
    WHERE regexp_matches(norm, '\(\s*"[^"]+"')
)
-- Proximity-Paarung (T6, 2026-06-16): jeder MBS-PluginFunctionRef wird mit dem
-- UNMITTELBAR FOLGENDEN passenden NoRef-Chunk (kleinster Chunk_Index > Ref-Index)
-- gepaart — das ist der `( "<SubName>"; `-Chunk direkt hinter dem MBS-Aufruf.
-- Ersetzt die frühere rn-Rang-Paarung (k-ter Ref ↔ k-ter SubName-Chunk), die
-- fragil war: zusätzliche `( "…"`-matchende Chunks (SQL-Strings; im --streamify-
-- Build zusätzlich die Roh-Fallback-Serialisierung textloser Chunks) verschoben
-- die rn-Ausrichtung → falsche/fehlende SubNames (Phantom-PluginFunction
-- `MBS::SELECT`, NULLs). Proximity ist serialisierungs-robust UND korrekter
-- (DOM-NULLs 305→222, 92 Fehl-Paarungen behoben; DOM==--streamify-Objektmenge).
SELECT pr.Calc_UUID, pr.File_Name, pr.Chunk_Index, sc.SubName
FROM plugin_refs pr
LEFT JOIN subname_chunks sc
  ON pr.Calc_UUID = sc.Calc_UUID
 AND pr.File_Name = sc.File_Name
 AND sc.Chunk_Index > pr.Chunk_Index
 AND (pr.Next_Ref_Index IS NULL OR sc.Chunk_Index < pr.Next_Ref_Index)  -- B-R5: Distanzdeckel
QUALIFY ROW_NUMBER() OVER (PARTITION BY pr.Calc_UUID, pr.File_Name, pr.Chunk_Index
                           ORDER BY sc.Chunk_Index) = 1;


-- ============================================
-- GetSubparameterMap
-- ============================================
-- Get(<SubParameter>) ist eine FileMaker-Container-Funktion: pro Sub-Parameter
-- liefert sie einen anderen Wert. Im DDR steht der Sub-Parameter als eigener
-- FunctionRef-Chunk innerhalb von Get( ... ) — Pattern (nach Chunk-Reorder
-- immer in dieser Reihenfolge):
--   Chunk N:   FunctionRef = 'Get'
--   Chunk N+1: NoRef       = '(' (mit optionalem Whitespace)
--   Chunk N+2: FunctionRef = '<SubParameter>'  (z.B. 'LayoutName')
--   Chunk N+3: NoRef       = ')...'
-- Bei dynamischen Aufrufen (Get($name) oder Get(Abs(...))) bleibt SubParameter
-- NULL (Chunk N+2 ist VariableReference, FieldRef oder eine andere Funktion
-- die in der fm_spec-Referenz NICHT als is_get_function markiert ist).
-- Die Get-Familie ist hier auf 'Get' beschränkt; lokalisierte Tokens (Holen,
-- Recibir, …) erscheinen im DDR praktisch nicht, weil FM die FunctionRefs auf
-- den kanonischen Namen normalisiert. Bei Bedarf erweiterbar.

CREATE TABLE IF NOT EXISTS GetSubparameterMap (
    Calc_UUID VARCHAR NOT NULL,
    File_Name VARCHAR NOT NULL,
    Get_Chunk_Index BIGINT NOT NULL,   -- Index des Get-FunctionRef-Chunks
    SubParameter VARCHAR,               -- z.B. 'ApplicationVersion', NULL bei dynamisch
    PRIMARY KEY (Calc_UUID, File_Name, Get_Chunk_Index)
);

-- Idempotenz: bestehende Einträge der aktuellen Datei entfernen
DELETE FROM GetSubparameterMap WHERE TRUE;

INSERT INTO GetSubparameterMap
WITH file_chunks AS (
    SELECT d.*
    FROM DDR_Calculations d
    WHERE TRUE
),
chunks_with_lead AS (
    SELECT
        Calc_UUID, File_Name, Chunk_Index, Chunk_Type, Chunk_Content,
        LEAD(Chunk_Type, 1) OVER w AS Next_Type,
        LEAD(Chunk_Type, 2) OVER w AS Next2_Type,
        LEAD(Chunk_Content, 2) OVER w AS Next2_Content,
        LEAD(Chunk_Type, 3) OVER w AS Next3_Type,
        LEAD(Chunk_Content, 3) OVER w AS Next3_Content
    FROM file_chunks
    WINDOW w AS (PARTITION BY Calc_UUID, File_Name ORDER BY Chunk_Index)
)
SELECT
    Calc_UUID,
    File_Name,
    Chunk_Index AS Get_Chunk_Index,
    CASE
        -- B-R6: struktureller Ersatz für die (nie implementierte) Whitelist —
        -- der Sub-Parameter ist nur dann echt, wenn NACH ihm direkt die
        -- schließende Klammer folgt (Chunk N+3 = NoRef, beginnt mit ')').
        -- Get(Abs(…)) hat an N+3 ein '(' → korrekt NULL statt SubParameter='Abs'.
        -- N+3 fehlt (Formel endet) → tolerant behandeln wie bisher.
        WHEN Next_Type = 'NoRef' AND Next2_Type = 'FunctionRef'
         AND (Next3_Type IS NULL OR (Next3_Type = 'NoRef' AND regexp_matches(
                regexp_replace(COALESCE(regexp_extract(Next3_Content, '>([^<]+)</Chunk>', 1), ''),
                               '&#(0*(9|10|13)|[xX]0*(9|[aAdD]));', ' ', 'g'),
                '^\s*\)')))
            THEN regexp_extract(Next2_Content, '>([^<]+)</Chunk>', 1)
        ELSE NULL
    END AS SubParameter
FROM chunks_with_lead
WHERE Chunk_Type = 'FunctionRef'
  AND regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Get'
-- B-R8: Dedup gegen Dup-Chunk-Merge-Artefakte (BrojDva-Klasse) — sonst PK-Crash;
-- deterministisch (SubParameter NULLS LAST → befüllter Eintrag gewinnt).
QUALIFY ROW_NUMBER() OVER (PARTITION BY Calc_UUID, File_Name, Chunk_Index
                           ORDER BY SubParameter NULLS LAST) = 1;


-- ============================================
-- XMLCalcReferences
-- ============================================
-- Resolved DDR-Refs (FieldRef + CustomFunctionRef) aus allen Calculation-Quellen:
--   - FieldsForTables (Calculated, AutoEnter-Calc) via DDR_Hash / AE_Calc_Hash
--   - CustomFunctionsCatalog via DDR_Hash
--   - StepsForScripts via DDRREF-Hashes im Parameters_XML
--   - LayoutObjects via DDRREF-Hashes im Object_XML
-- Plugin-Funktionen landen in PluginFunctionUsages (separate Tabelle, da kein
-- ObjectCatalog-Eintrag vorhanden).
CREATE TABLE IF NOT EXISTS XMLCalcReferences (
    Source_UUID VARCHAR,         -- Script_UUID, Field_UUID, CF_UUID oder LayoutObject_UUID
    Source_Type VARCHAR,         -- 'Script', 'Field', 'CustomFunction', 'LayoutObject'
    Source_Subkey VARCHAR,       -- Step_Index (Steps), NULL (Field/CF/LayoutObject)
    Subrole VARCHAR,             -- 'Hide','Tooltip','Condition_1','action','1','2',NULL
    Calc_Hash VARCHAR,
    Ref_Type VARCHAR,            -- 'field' | 'customfunction' | 'pluginfunction' | 'variable'
    Ref_UUID VARCHAR,            -- Field-UUID (NULL bei CF/Plugin/Variable)
    Ref_Name VARCHAR,            -- Field-/CF-/Plugin-Name oder Variable-Name (mit Präfix)
    File_Name VARCHAR,
    TO_Name VARCHAR,             -- TO-Name aus <TableOccurrenceReference> (NULL bei CF/Plugin/Var)
    TO_UUID VARCHAR,             -- TO-UUID analog
    -- v2.0 Erweiterungen:
    Variable_Scope VARCHAR,      -- nur Ref_Type='variable': 'local'|'global'|'superglobal'|'let_local'
    Usage_Type VARCHAR,          -- nur Ref_Type='variable': 'read' (Calc-Chunk-Refs sind immer Lesungen)
    -- v2.1 Erweiterung:
    Ref_SubName VARCHAR,         -- nur Ref_Type='pluginfunction' bei Container-Plugins
                                 -- (heute: MBS) — fachlicher Funktionsname aus dem
                                 -- ersten quoted String des Folge-NoRef-Chunks.
    -- UUID-Healing (Schema 1.19.0): FileMaker-interne @id des Referenz-Elements aus dem
    -- FieldRef-Chunk (Tripel id+name+UUID) — disambiguiert Intra-File-UUID-Duplikate in
    -- der P4-Rewrite-Stufe. Nur bei Ref_Type='field' befüllbar (andere Chunk-Typen tragen
    -- nur den Namen als Text). TO_Ref_ID = @id der eingebetteten TableOccurrenceReference
    -- (FieldReference/@id ist TABELLEN-lokal, Feld-Schlüssel zweistufig über die TO).
    Ref_ID BIGINT,
    TO_Ref_ID BIGINT
);

-- Additive Migration: Spalten für Bestands-DBs nachziehen. ADD COLUMN IF NOT EXISTS
-- ist idempotent. Reihenfolge identisch zu CREATE TABLE — positionsbasierte INSERTs
-- bleiben konsistent über beide Schema-Pfade.
ALTER TABLE XMLCalcReferences ADD COLUMN IF NOT EXISTS TO_Name VARCHAR;
ALTER TABLE XMLCalcReferences ADD COLUMN IF NOT EXISTS TO_UUID VARCHAR;
ALTER TABLE XMLCalcReferences ADD COLUMN IF NOT EXISTS Variable_Scope VARCHAR;
ALTER TABLE XMLCalcReferences ADD COLUMN IF NOT EXISTS Usage_Type VARCHAR;
ALTER TABLE XMLCalcReferences ADD COLUMN IF NOT EXISTS Ref_SubName VARCHAR;
ALTER TABLE XMLCalcReferences ADD COLUMN IF NOT EXISTS Ref_ID BIGINT;
ALTER TABLE XMLCalcReferences ADD COLUMN IF NOT EXISTS TO_Ref_ID BIGINT;

CREATE TABLE IF NOT EXISTS PluginFunctionUsages (
    Source_UUID VARCHAR,
    Source_Type VARCHAR,
    Source_Subkey VARCHAR,       -- Step_Index oder NULL
    Subrole VARCHAR,
    Plugin_Function_Name VARCHAR,
    Calc_Hash VARCHAR,
    File_Name VARCHAR,
    -- Positionsbezogene Spalten,
    -- damit (Source, Calc_UUID, Plugin_Chunk_Index) eindeutig auf einen SubName
    -- in MBS_SubnameMap mappt. Calc_Hash-Joins explodieren wegen Hash-Dedup
    -- (1 Hash → bis zu 58k Calc_UUIDs); diese beiden Spalten lösen das.
    Calc_UUID VARCHAR,
    Plugin_Chunk_Index BIGINT
);

-- Additive Migration für Bestands-DBs (Reihenfolge identisch zum CREATE TABLE).
ALTER TABLE PluginFunctionUsages ADD COLUMN IF NOT EXISTS Calc_UUID VARCHAR;
ALTER TABLE PluginFunctionUsages ADD COLUMN IF NOT EXISTS Plugin_Chunk_Index BIGINT;

-- Idempotenz: bestehende Einträge der aktuellen Datei entfernen
DELETE FROM XMLCalcReferences WHERE TRUE;

DELETE FROM PluginFunctionUsages WHERE TRUE;

-- ============================================
-- B-R1 — Kanonische Chunk-Menge + einmalige DDRREF-Extraktion (TEMP)
-- ============================================
-- (1) _ddr_chunks_by_hash: genau EINE Chunk-Folge pro (File_Name, Calc_Hash).
-- DDR_Calculations führt jede Calculation einzeln (Calc_UUID); identische
-- Formeln teilen den Calc_Hash (Spitze: 1 Hash → 63k Calc_UUIDs). Ein direkter
-- Hash-Join fächert auf JEDE Kopie auf und produzierte ~95 % exakte Duplikate
-- in XMLCalcReferences (4,3 M statt ~200 k Zeilen). Die Chunk-Folge ist per
-- Hash-Definition inhaltsgleich → der Repräsentant min(Calc_UUID) genügt allen
-- Hash-Joins (alle `JOIN … ON <hash> = d.Calc_Hash`-Blöcke unten). Die
-- Calc_UUID-verankerten Pässe (A.1/A.3 MBS_SubnameMap/GetSubparameterMap,
-- A.9 Menü-Anker) bleiben bewusst auf DDR_Calculations — sie sind positions-
-- bezogen pro Calculation und fächern nicht auf.
-- TEMP: pro Slice-Connection lokal (partitionierter P2-Lauf bleibt read-only
-- auf den Quell-Views).
CREATE OR REPLACE TEMP TABLE _ddr_chunks_by_hash AS
SELECT d.*
FROM DDR_Calculations d
JOIN (
    SELECT File_Name, Calc_Hash, min(Calc_UUID) AS canon_uuid
    FROM DDR_Calculations
    GROUP BY File_Name, Calc_Hash
) c
  ON d.File_Name = c.File_Name
 AND d.Calc_Hash = c.Calc_Hash
 AND d.Calc_UUID = c.canon_uuid;

-- (2) _step_hashes / _layout_obj_hashes: die DDRREF-Hash-Extraktion lief bisher
-- als 6+6 identische Inline-CTEs = ~24 regexp_extract_all-Vollscans über die
-- größten Blob-Spalten (Parameters_XML, Object_XML). Hier EINMAL materialisiert,
-- beide Regex-Gruppen in EINEM Pass (Gruppe 0 unnesten, Hash/Subrole aus dem
-- kurzen Match nachextrahieren — bit-identisch zu den Parallel-Listen, empirisch
-- EXCEPT ALL beidseitig 0 auf dem Korpus).
CREATE OR REPLACE TEMP TABLE _step_hashes AS
SELECT
    Script_UUID, Step_Index, File_Name,
    regexp_extract(m, 'hash="([^"]+)"', 1) AS Calc_Hash,
    regexp_extract(m, '>_[A-F0-9-]{36}_([^<]+)</DDRREF>', 1) AS Subrole
FROM (
    SELECT
        s.Script_UUID,
        s.Step_Index::VARCHAR AS Step_Index,
        s.File_Name,
        unnest(regexp_extract_all(s.Parameters_XML,
            'kind="ChunkList" hash="([^"]+)"[^>]*>_[A-F0-9-]{36}_([^<]+)</DDRREF>')) AS m
    FROM StepsForScripts s
    WHERE s.Parameters_XML LIKE '%DDRREF%'
);

CREATE OR REPLACE TEMP TABLE _layout_obj_hashes AS
SELECT
    Object_UUID, File_Name,
    regexp_extract(m, 'hash="([^"]+)"', 1) AS Calc_Hash,
    regexp_extract(m, '>_[A-F0-9-]{36}_([^<]+)</DDRREF>', 1) AS Subrole
FROM (
    SELECT
        lo.Object_UUID,
        lo.File_Name,
        unnest(regexp_extract_all(lo.Object_XML,
            'kind="ChunkList" hash="([^"]+)"[^>]*>_[A-F0-9-]{36}_([^<]+)</DDRREF>')) AS m
    FROM LayoutObjects lo
    WHERE lo.Object_XML LIKE '%DDRREF%'
);

-- ============================================
-- A.2 — Refs aus Calculated Fields & AutoEnter-Calc (direkter DDR_Hash-Match)
-- ============================================

-- A.2.1 FieldRef in Calculated Fields (DDR_Hash)
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, NULL,
    d.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    d.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.DDR_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef'
  AND f.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.2.2 CustomFunctionRef in Calculated Fields (DDR_Hash)
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, NULL,
    d.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,  -- Variable_Scope, Usage_Type
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.DDR_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef'
  AND f.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.2.3 PluginFunctionRef in Calculated Fields → PluginFunctionUsages
INSERT INTO PluginFunctionUsages
SELECT
    f.Field_UUID, 'Field', NULL, NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.Calc_Hash,
    d.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.DDR_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND f.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.2.4 FieldRef in AutoEnter-Calc (AE_Calc_Hash) — Subrole 'auto_enter'
-- (Schema 1.22.0): unterscheidet den AutoEnter-Slot vom Haupt-Calc (Subrole
-- NULL) — Link_Role bleibt reads_field; v_calculation_links braucht die
-- Trennschärfe für die Slot-Zuordnung.
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'auto_enter',
    d.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    d.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.AE_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef'
  AND f.AE_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.2.5 CustomFunctionRef in AutoEnter-Calc (AE_Calc_Hash) — Subrole 'auto_enter'
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'auto_enter',
    d.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,  -- Variable_Scope, Usage_Type
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.AE_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef'
  AND f.AE_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.2.6 PluginFunctionRef in AutoEnter-Calc → PluginFunctionUsages — Subrole 'auto_enter'
INSERT INTO PluginFunctionUsages
SELECT
    f.Field_UUID, 'Field', NULL, 'auto_enter',
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.Calc_Hash,
    d.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.AE_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND f.AE_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.2.7 FieldRef in Validierungs-Calc (Validation_Calc_Hash) — Subrole 'validation'
-- markiert die Quelle, damit Block 30 (Catalog) die Kante als validates_by_calc
-- statt reads_field emittiert. Schließt die Where-used-Lücke für Felder, die NUR
-- in einer Feldvalidierung („Überprüfung durch Berechnung") referenziert werden.
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'validation',
    d.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    d.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,
    NULL,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.Validation_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef'
  AND f.Validation_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.2.8 CustomFunctionRef in Validierungs-Calc (Validation_Calc_Hash) — Subrole 'validation'
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'validation',
    d.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    NULL,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.Validation_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef'
  AND f.Validation_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.2.9 PluginFunctionRef in Validierungs-Calc → PluginFunctionUsages
-- (Where-used-Vollständigkeit; die Plugin-Kante bleibt calls_pluginfunction).
INSERT INTO PluginFunctionUsages
SELECT
    f.Field_UUID, 'Field', NULL, 'validation',
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.Calc_Hash,
    d.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.Validation_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND f.Validation_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.2.10 FieldRef in der eigenen Fehlermeldungs-Berechnung (Validation_Message_Calc_Hash).
-- <MessageCalc> ist Teil der Validierungs-Konfiguration → Link_Role bleibt
-- validates_by_calc (Block 30 akzeptiert beide Subroles); ein nur dort
-- referenziertes Feld wäre sonst Where-used-unsichtbar. Subrole seit 1.22.0
-- 'validation_message' (statt 'validation') — trennt die Fehlermeldungs- von
-- der Prüf-Berechnung (v_calculation_links-Slot-Zuordnung).
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'validation_message',
    d.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    d.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,
    NULL,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.Validation_Message_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef'
  AND f.Validation_Message_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.2.11 CustomFunctionRef in der Fehlermeldungs-Berechnung (Validation_Message_Calc_Hash)
-- Subrole 'validation_message' (s. A.2.10).
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'validation_message',
    d.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    NULL,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.Validation_Message_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef'
  AND f.Validation_Message_Calc_Hash IS NOT NULL
  AND TRUE;

-- ============================================
-- A.3 — Refs aus CustomFunctions (direkter DDR_Hash-Match)
-- ============================================

-- A.3.1 FieldRef in CustomFunctions
INSERT INTO XMLCalcReferences
SELECT
    cf.CF_UUID, 'CustomFunction', NULL, NULL,
    d.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    d.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM CustomFunctionsCatalog cf
JOIN _ddr_chunks_by_hash d ON cf.DDR_Hash = d.Calc_Hash AND cf.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef'
  AND cf.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.3.2 CustomFunctionRef in CustomFunctions (CF→CF Aufrufe)
INSERT INTO XMLCalcReferences
SELECT
    cf.CF_UUID, 'CustomFunction', NULL, NULL,
    d.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,  -- Variable_Scope, Usage_Type
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM CustomFunctionsCatalog cf
JOIN _ddr_chunks_by_hash d ON cf.DDR_Hash = d.Calc_Hash AND cf.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef'
  AND cf.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.3.3 PluginFunctionRef in CustomFunctions → PluginFunctionUsages
INSERT INTO PluginFunctionUsages
SELECT
    cf.CF_UUID, 'CustomFunction', NULL, NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.Calc_Hash,
    d.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM CustomFunctionsCatalog cf
JOIN _ddr_chunks_by_hash d ON cf.DDR_Hash = d.Calc_Hash AND cf.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND cf.DDR_Hash IS NOT NULL
  AND TRUE;

-- ============================================
-- A.4 — Refs aus Script-Steps (DDRREF-Hashes via Regex)
-- ============================================
-- DDRREF-Pattern: kind="ChunkList" hash="<HEX>" ...>_<UUID>_<SLOT></DDRREF>
-- Slot-Index ist FileMaker-spezifisch (Step-Typ-abhängig). Wir speichern ihn
-- als Subrole, ohne semantische Auflösung.

-- A.4.1 FieldRef in Script-Steps
-- step_hashes: einmal materialisiert als _step_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    sh.Script_UUID, 'Script', sh.Step_Index, sh.Subrole,
    sh.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    sh.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM _step_hashes sh
JOIN _ddr_chunks_by_hash d
  ON sh.Calc_Hash = d.Calc_Hash
 AND sh.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef';

-- A.4.2 CustomFunctionRef in Script-Steps
-- step_hashes: einmal materialisiert als _step_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    sh.Script_UUID, 'Script', sh.Step_Index, sh.Subrole,
    sh.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    sh.File_Name,
    NULL, NULL,
    NULL, NULL,  -- Variable_Scope, Usage_Type
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _step_hashes sh
JOIN _ddr_chunks_by_hash d
  ON sh.Calc_Hash = d.Calc_Hash
 AND sh.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef';

-- A.4.3 PluginFunctionRef in Script-Steps → PluginFunctionUsages
-- step_hashes: einmal materialisiert als _step_hashes (s. o.)
INSERT INTO PluginFunctionUsages
SELECT
    sh.Script_UUID, 'Script', sh.Step_Index, sh.Subrole,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    sh.Calc_Hash,
    sh.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM _step_hashes sh
JOIN _ddr_chunks_by_hash d
  ON sh.Calc_Hash = d.Calc_Hash
 AND sh.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef';

-- ============================================
-- A.5 — Refs aus LayoutObjects (DDRREF-Hashes via Regex)
-- ============================================
-- Subrole: semantischer Suffix aus dem DDRREF (z.B. Hide, Tooltip, Condition_1,
-- action, ScriptTrigger_*, Label, TabPanel, Portal, Placeholder, WebViewer).

-- A.5.1 FieldRef in LayoutObjects
-- layout_obj_hashes: einmal materialisiert als _layout_obj_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    loh.Object_UUID, 'LayoutObject', NULL, loh.Subrole,
    loh.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    loh.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM _layout_obj_hashes loh
JOIN _ddr_chunks_by_hash d
  ON loh.Calc_Hash = d.Calc_Hash
 AND loh.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef';

-- A.5.1b Fehlklassifizierte %X:-Chunks in DisplayCalculations → FieldRef-Rettung (Schema 1.27.0).
-- FileMaker chunked eine TYPISIERTE Layoutformel mit einzelner Feldreferenz
-- (<<ƒ:%N:Zahl>>) als <Chunk type="VariableReference">%N:Zahl</Chunk> — Ergebnistyp-
-- Präfix + Feldname als Variablen-Literal, die echte FieldRef fehlt (die Quelle
-- lügt, gleiche Defekt-Kategorie wie 'Function Missing'). Rettung: Präfix strippen,
-- Rest als Feldname gegen die Kontext-TO der ChunkList auflösen. Kontext-Join über
-- den Anker-NAMEN (DDR_ChunkListContexts) — nie über den Hash: identische Formeln
-- teilen den Hash, jeder Anker trägt seine eigene TO. Qualifizierte Namen
-- (TO::Feld) lösen über den TO-Namensteil (Equi-Join auf vorberechnetem
-- qual_to_name, NULL matcht nie). Feld-Join via TableOccurrenceCatalog →
-- FieldsForTables (NIE über ObjectCatalog-Namen); externe TOs (Basistabelle in
-- anderer Datei) bleiben konservativ ungelöst — kein Insert, kein Phantom.
-- P3 A.3 verwirft dieselben Chunks aus der Variablen-Extraktion;
-- P6 v_check_display_prefix_chunks zählt sie als Info-Finding.
INSERT INTO XMLCalcReferences
WITH mischunk AS (
    SELECT
        loh.Object_UUID, loh.Subrole, loh.Calc_Hash, loh.File_Name,
        html_unescape(regexp_replace(
            regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
            '^%[A-Z]+:', '')) AS ref_token
    FROM _layout_obj_hashes loh
    JOIN _ddr_chunks_by_hash d
      ON loh.Calc_Hash = d.Calc_Hash
     AND loh.File_Name = d.File_Name
    WHERE d.Chunk_Type = 'VariableReference'
      AND loh.Subrole LIKE 'DisplayCalculations\_%' ESCAPE '\'
      AND regexp_matches(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:')
      -- Präfix + '$' = ECHTE Variable hinter dem Ergebnistyp (<<ƒ:%N:$$var>>) —
      -- keine Feld-Rettung; die Variablen-Extraktion behält sie mit gestripptem
      -- Namen (A.6.10 / P3 A.3, 2.20.0).
      AND NOT regexp_matches(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:\$')
),
tokenized AS (
    SELECT
        m.*,
        -- ${…}-Unwrap: bei Namenskollision Feld ↔ CustomFunction serialisiert
        -- FileMaker die FELD-Referenz gequotet (${Text}) — für den
        -- FieldsForTables-Join muss der nackte Name stehen (fixture-verifiziert).
        regexp_replace(
            CASE WHEN m.ref_token LIKE '%::%' THEN split_part(m.ref_token, '::', 2)
                 ELSE m.ref_token END,
            '^\$\{(.*)\}$', '\1') AS field_name,
        regexp_replace(
            CASE WHEN m.ref_token LIKE '%::%' THEN split_part(m.ref_token, '::', 1)
                 END,
            '^\$\{(.*)\}$', '\1') AS qual_to_name
    FROM mischunk m
),
resolved_to AS (
    SELECT
        t.*,
        COALESCE(t_qual.TO_Name, t_ctx.TO_Name) AS to_name,
        COALESCE(t_qual.TO_UUID, t_ctx.TO_UUID) AS to_uuid,
        COALESCE(t_qual.BT_Name, t_ctx.BT_Name) AS bt_name,
        COALESCE(t_qual.TO_ID,   t_ctx.TO_ID)   AS to_id
    FROM tokenized t
    LEFT JOIN DDR_ChunkListContexts ctx
           ON upper(ctx.Calc_UUID) = upper('_' || t.Object_UUID || '_' || t.Subrole)
          AND ctx.File_Name = t.File_Name
    LEFT JOIN TableOccurrenceCatalog t_ctx
           ON t_ctx.TO_UUID   = ctx.Context_TO_UUID
          AND t_ctx.File_Name = t.File_Name
    LEFT JOIN TableOccurrenceCatalog t_qual
           ON t_qual.TO_Name   = t.qual_to_name
          AND t_qual.File_Name = t.File_Name
)
SELECT
    r.Object_UUID, 'LayoutObject', NULL, r.Subrole,
    r.Calc_Hash, 'field',
    fft.Field_UUID,
    r.field_name,
    r.File_Name,
    r.to_name, r.to_uuid,
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,  -- Feld-@id unbekannt (Chunk trägt nur den Namen)
    r.to_id AS TO_Ref_ID
FROM resolved_to r
JOIN FieldsForTables fft
  ON fft.Table_Name = r.bt_name
 AND fft.Field_Name = r.field_name
 AND fft.File_Name  = r.File_Name;

-- A.5.1c Leere DisplayCalculations-ChunkList → Feldreferenzen aus Text_Content (Schema 1.27.0).
-- Bei %X:-typisierten Layoutformeln mit AUSDRUCK schreibt FileMaker eine LEERE
-- ChunkList (Hash = md5('')) — Formel, Feld- und Funktionsreferenzen fehlen im
-- DDR-Teil komplett (lautloser Where-used-Verlust). Minimalziel: Feld-Kanten
-- retten. Die lokalisierte Formel kommt aus Text_Content (i-tes <<ƒ:…>>-
-- Vorkommen, Index aus dem Anker-Suffix, (?s) für mehrzeilige Formeln) und wird
-- gegen die Feldnamen der Kontext-TO gematcht (Wortgrenzen-Check: Nachbar-
-- zeichen des ersten Vorkommens kein Identifier-Zeichen). Anker-Quelle ist
-- DDR_ChunkListContexts (Chunk_Count = 0) — NICHT _layout_obj_hashes über den
-- Hash: der Leerhash ist dateiweit identisch und würde kreuzprodukt-artig auf
-- jeden leeren Anker fächern. Bewusste Grenzen (Minimalziel):
-- Felder nur aus der Kontext-TO (keine qualifizierten Fremd-TO-Refs), keine
-- BUILTIN-Funktionsauflösung (Namen sind LOKALISIERT, z. B. 'Abschneiden' ≠
-- 'Truncate' — Ausbaustufe via fm_spec-Emission-Namen), String-Literale nicht
-- ausgenommen. Seit 2.20.0 zusätzlich gerettet: CustomFunction-Refs (CF-Zweig
-- unten — CF-Namen sind locale-fest) und Variablen (P3 A.6c, syntaktisch
-- eindeutig). Die Calc-Instanz dazu legt P4 (b_disp) an;
-- P6 v_check_display_empty_chunklist meldet die Fälle als Import-Finding.
INSERT INTO XMLCalcReferences
WITH empty_disp AS (
    SELECT
        ctx.File_Name,
        upper(regexp_extract(ctx.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1)) AS Anchor_UUID,
        regexp_replace(ctx.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', '')      AS Subrole,
        ctx.Calc_Hash,
        ctx.Context_TO_UUID,
        TRY_CAST(regexp_extract(ctx.Calc_UUID, '_([0-9]+)$', 1) AS BIGINT) AS Disp_Index
    FROM DDR_ChunkListContexts ctx
    WHERE ctx.Chunk_Count = 0
      AND ctx.Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
),
lo1 AS (
    SELECT Object_UUID, File_Name, Text_Content,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    WHERE Text_Content LIKE '%<<%'
),
formulas AS (
    SELECT
        e.File_Name, e.Subrole, e.Calc_Hash, e.Context_TO_UUID,
        lo.Object_UUID,
        regexp_replace(
            regexp_extract_all(lo.Text_Content, '(?s)<<ƒ:(.*?)>>', 1)[e.Disp_Index + 1],
            '^%[A-Z]+:', '') AS formula
    FROM empty_disp e
    JOIN lo1 lo
      ON upper(lo.Object_UUID) = e.Anchor_UUID
     AND lo.File_Name = e.File_Name
     AND lo.rn = 1
),
ctx_fields AS (
    SELECT
        f.*,
        t.TO_Name, t.TO_ID,
        fft.Field_Name, fft.Field_UUID,
        strpos(f.formula, fft.Field_Name) AS hit_pos,
        -- ${…}-Quoting-Treffer: bei Namenskollision Feld ↔ CustomFunction
        -- serialisiert FileMaker die FELD-Referenz IMMER als ${Name} — der
        -- gequotete Treffer ist damit definitiv das Feld (fixture-verifiziert).
        strpos(f.formula, '${' || fft.Field_Name || '}') AS qhit_pos,
        EXISTS (SELECT 1 FROM CustomFunctionsCatalog cfc
                 WHERE cfc.CF_Name = fft.Field_Name AND cfc.File_Name = f.File_Name
                   AND (cfc.Folder_Type IS NULL OR cfc.Folder_Type = 'False')
                   AND NOT COALESCE(cfc.Is_Separator, FALSE)) AS cf_collision
    FROM formulas f
    JOIN TableOccurrenceCatalog t
      ON t.TO_UUID   = f.Context_TO_UUID
     AND t.File_Name = f.File_Name
    JOIN FieldsForTables fft
      ON fft.Table_Name = t.BT_Name
     AND fft.File_Name  = f.File_Name
    WHERE f.formula IS NOT NULL AND f.formula <> ''
),
-- (2.20.0) CustomFunction-Namen im Formeltext — anders als Builtin-Funktionen
-- sind CF-Namen NICHT lokalisiert und damit sauber matchbar. Ungequotete
-- Vorkommen meinen bei Namenskollision die CF (das Feld wäre ${…}-gequotet).
ctx_cfs AS (
    SELECT
        f.*,
        cf.CF_Name,
        strpos(f.formula, cf.CF_Name) AS hit_pos
    FROM formulas f
    JOIN CustomFunctionsCatalog cf
      ON cf.File_Name = f.File_Name
     AND (cf.Folder_Type IS NULL OR cf.Folder_Type = 'False')
     AND NOT COALESCE(cf.Is_Separator, FALSE)
    WHERE f.formula IS NOT NULL AND f.formula <> ''
)
-- Feld-Zweig: gequoteter Treffer (${Name}) gewinnt immer; ungequotete Treffer
-- nur ohne CF-Namenskollision (sonst meint der nackte Name die CF). Die
-- Vorgänger-Klasse verwirft zusätzlich '$' und '{' (Variablen/Quoting).
SELECT DISTINCT
    c.Object_UUID, 'LayoutObject', NULL, c.Subrole,
    c.Calc_Hash, 'field',
    c.Field_UUID,
    c.Field_Name,
    c.File_Name,
    c.TO_Name, c.Context_TO_UUID,
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    c.TO_ID AS TO_Ref_ID
FROM ctx_fields c
WHERE c.qhit_pos > 0
   OR (NOT c.cf_collision
       AND c.hit_pos > 0
       AND (c.hit_pos = 1
            OR NOT regexp_matches(substr(c.formula, c.hit_pos - 1, 1), '[0-9A-Za-zÄÖÜäöüß_${]'))
       AND (c.hit_pos + length(c.Field_Name) > length(c.formula)
            OR NOT regexp_matches(substr(c.formula, c.hit_pos + length(c.Field_Name), 1), '[0-9A-Za-zÄÖÜäöüß_]')))

UNION ALL

-- CF-Zweig (A.5.1d): Ref_UUID bleibt NULL — Block 31 löst calls_customfunction
-- über Ref_Name + File_Name (datei-lokal, wie alle CF-Refs).
SELECT DISTINCT
    c.Object_UUID, 'LayoutObject', NULL, c.Subrole,
    c.Calc_Hash, 'customfunction',
    NULL,
    c.CF_Name,
    c.File_Name,
    NULL, NULL,
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM ctx_cfs c
WHERE c.hit_pos > 0
  AND (c.hit_pos = 1
       OR NOT regexp_matches(substr(c.formula, c.hit_pos - 1, 1), '[0-9A-Za-zÄÖÜäöüß_${]'))
  AND (c.hit_pos + length(c.CF_Name) > length(c.formula)
       OR NOT regexp_matches(substr(c.formula, c.hit_pos + length(c.CF_Name), 1), '[0-9A-Za-zÄÖÜäöüß_]'));

-- A.5.2 CustomFunctionRef in LayoutObjects
-- layout_obj_hashes: einmal materialisiert als _layout_obj_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    loh.Object_UUID, 'LayoutObject', NULL, loh.Subrole,
    loh.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    loh.File_Name,
    NULL, NULL,
    NULL, NULL,  -- Variable_Scope, Usage_Type
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _layout_obj_hashes loh
JOIN _ddr_chunks_by_hash d
  ON loh.Calc_Hash = d.Calc_Hash
 AND loh.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef';

-- A.5.3 PluginFunctionRef in LayoutObjects → PluginFunctionUsages
-- layout_obj_hashes: einmal materialisiert als _layout_obj_hashes (s. o.)
INSERT INTO PluginFunctionUsages
SELECT
    loh.Object_UUID, 'LayoutObject', NULL, loh.Subrole,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    loh.Calc_Hash,
    loh.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM _layout_obj_hashes loh
JOIN _ddr_chunks_by_hash d
  ON loh.Calc_Hash = d.Calc_Hash
 AND loh.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef';


-- ============================================
-- A.6 — Plugin- und Variable-Refs in XMLCalcReferences
-- ============================================
-- 5 Quellen × 2 neue Ref-Typen = 10 INSERT-Blöcke.
-- PluginFunction-Refs sind hier zusätzlich zu PluginFunctionUsages enthalten,
-- damit der Tokens-Output sie als Refs ausliefern kann.
-- Variable-Refs (immer 'read') ergänzen die Set-Variable-Definitionen aus
-- XMLStepReferences (Usage_Type='set') zur bidirektionalen Cross-Step-Navigation.

-- A.6.1 PluginFunctionRef in Calculated Fields
-- Ref_SubName aus MBS_SubnameMap (NULL für Nicht-Container-Plugins).
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, NULL,
    d.Calc_Hash, 'pluginfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    m.SubName,  -- Ref_SubName
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.DDR_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
LEFT JOIN MBS_SubnameMap m
       ON m.Calc_UUID = d.Calc_UUID
      AND m.File_Name = d.File_Name
      AND m.Plugin_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND f.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.6.2 VariableReference in Calculated Fields
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, NULL,
    d.Calc_Hash, 'variable',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    CASE
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$$%' THEN 'superglobal'
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.DDR_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'VariableReference'
  AND f.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.6.3 PluginFunctionRef in AutoEnter-Calc — Subrole 'auto_enter' (1.22.0)
-- Ref_SubName aus MBS_SubnameMap (NULL für Nicht-Container-Plugins).
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'auto_enter',
    d.Calc_Hash, 'pluginfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    m.SubName,  -- Ref_SubName
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.AE_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
LEFT JOIN MBS_SubnameMap m
       ON m.Calc_UUID = d.Calc_UUID
      AND m.File_Name = d.File_Name
      AND m.Plugin_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND f.AE_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.6.4 VariableReference in AutoEnter-Calc — Subrole 'auto_enter' (1.22.0;
-- Variable-Links laufen über VariableUsages/P3, die Subrole ist hier reine
-- Slot-Provenienz der XMLCalcReferences-Zeile).
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'auto_enter',
    d.Calc_Hash, 'variable',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    CASE
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$$%' THEN 'superglobal'
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.AE_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
WHERE d.Chunk_Type = 'VariableReference'
  AND f.AE_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.6.5 PluginFunctionRef in CustomFunctions
-- Ref_SubName aus MBS_SubnameMap (NULL für Nicht-Container-Plugins).
INSERT INTO XMLCalcReferences
SELECT
    cf.CF_UUID, 'CustomFunction', NULL, NULL,
    d.Calc_Hash, 'pluginfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    m.SubName,  -- Ref_SubName
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM CustomFunctionsCatalog cf
JOIN _ddr_chunks_by_hash d ON cf.DDR_Hash = d.Calc_Hash AND cf.File_Name = d.File_Name
LEFT JOIN MBS_SubnameMap m
       ON m.Calc_UUID = d.Calc_UUID
      AND m.File_Name = d.File_Name
      AND m.Plugin_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND cf.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.6.6 VariableReference in CustomFunctions
INSERT INTO XMLCalcReferences
SELECT
    cf.CF_UUID, 'CustomFunction', NULL, NULL,
    d.Calc_Hash, 'variable',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    CASE
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$$%' THEN 'superglobal'
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM CustomFunctionsCatalog cf
JOIN _ddr_chunks_by_hash d ON cf.DDR_Hash = d.Calc_Hash AND cf.File_Name = d.File_Name
WHERE d.Chunk_Type = 'VariableReference'
  AND cf.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.6.7 PluginFunctionRef in Script-Steps
-- Ref_SubName aus MBS_SubnameMap (NULL für Nicht-Container-Plugins).
-- step_hashes: einmal materialisiert als _step_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    sh.Script_UUID, 'Script', sh.Step_Index, sh.Subrole,
    sh.Calc_Hash, 'pluginfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    sh.File_Name,
    NULL, NULL,
    NULL, NULL,
    m.SubName,  -- Ref_SubName
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _step_hashes sh
JOIN _ddr_chunks_by_hash d
  ON sh.Calc_Hash = d.Calc_Hash
 AND sh.File_Name = d.File_Name
LEFT JOIN MBS_SubnameMap m
       ON m.Calc_UUID = d.Calc_UUID
      AND m.File_Name = d.File_Name
      AND m.Plugin_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'PluginFunctionRef';

-- A.6.8 VariableReference in Script-Steps
-- step_hashes: einmal materialisiert als _step_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    sh.Script_UUID, 'Script', sh.Step_Index, sh.Subrole,
    sh.Calc_Hash, 'variable',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    sh.File_Name,
    NULL, NULL,
    CASE
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$$%' THEN 'superglobal'
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _step_hashes sh
JOIN _ddr_chunks_by_hash d
  ON sh.Calc_Hash = d.Calc_Hash
 AND sh.File_Name = d.File_Name
WHERE d.Chunk_Type = 'VariableReference';

-- A.6.9 PluginFunctionRef in LayoutObjects
-- Ref_SubName aus MBS_SubnameMap (NULL für Nicht-Container-Plugins).
-- layout_obj_hashes: einmal materialisiert als _layout_obj_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    loh.Object_UUID, 'LayoutObject', NULL, loh.Subrole,
    loh.Calc_Hash, 'pluginfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    loh.File_Name,
    NULL, NULL,
    NULL, NULL,
    m.SubName,  -- Ref_SubName
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _layout_obj_hashes loh
JOIN _ddr_chunks_by_hash d
  ON loh.Calc_Hash = d.Calc_Hash
 AND loh.File_Name = d.File_Name
LEFT JOIN MBS_SubnameMap m
       ON m.Calc_UUID = d.Calc_UUID
      AND m.File_Name = d.File_Name
      AND m.Plugin_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'PluginFunctionRef';

-- A.6.10 VariableReference in LayoutObjects
-- layout_obj_hashes: einmal materialisiert als _layout_obj_hashes (s. o.)
-- %X:-Präfix-Behandlung (2.20.0, Display-Kontext): Präfix + Feldname
-- (fehlklassifizierte FieldRef, <<ƒ:%N:Zahl>>) wird ausgeschlossen — Rettung
-- als FieldRef in A.5.1b, Verwurf analog P3 A.3; Präfix + '$' (<<ƒ:%N:$$var>>)
-- ist eine ECHTE Variable hinter dem Ergebnistyp und bleibt mit gestripptem
-- Namen drin (fixture-verifiziert).
INSERT INTO XMLCalcReferences
SELECT
    loh.Object_UUID, 'LayoutObject', NULL, loh.Subrole,
    loh.Calc_Hash, 'variable',
    NULL,
    v.var_name,
    loh.File_Name,
    NULL, NULL,
    CASE
        WHEN v.var_name LIKE '$$$%' THEN 'superglobal'
        WHEN v.var_name LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _layout_obj_hashes loh
JOIN _ddr_chunks_by_hash d
  ON loh.Calc_Hash = d.Calc_Hash
 AND loh.File_Name = d.File_Name
CROSS JOIN LATERAL (
    SELECT CASE WHEN loh.Subrole LIKE 'DisplayCalculations\_%' ESCAPE '\'
                 AND regexp_matches(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:\$')
                THEN regexp_replace(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:', '')
                ELSE regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1)
           END AS var_name
) v
WHERE d.Chunk_Type = 'VariableReference'
  AND NOT (loh.Subrole LIKE 'DisplayCalculations\_%' ESCAPE '\'
           AND regexp_matches(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:')
           AND NOT regexp_matches(regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:\$'));

-- A.6.10b Variablen aus geretteten Display-Formeln → XMLCalcReferences (2.20.0)
-- Slot-skopiertes Spiegelbild von P3 A.6c: bei leerer DisplayCalculations-
-- ChunkList werden Variablen aus der Text_Content-Formel geborgen — hier als
-- XMLCalcReferences-Zeile mit Subrole (Symmetrie zu den chunk-basierten
-- Variable-Rows der intakten Slots; A.6c bedient nur VariableUsages ohne
-- Slot-Bezug). Konsumenten: Referenz-Tokens + synthetische D2-Tokenisierung
-- der API (Instanz-genaue Ref-Menge je Slot). Anker-Quelle DDR_ChunkListContexts
-- — nie der dateiweit geteilte Leerhash; String-Literale vor dem Match
-- gestrippt; ${…}-gequotete FELD-Namen matcht die Klasse nicht ('{' nach '$').
INSERT INTO XMLCalcReferences
WITH empty_disp AS (
    SELECT
        ctx.File_Name,
        upper(regexp_extract(ctx.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1)) AS Anchor_UUID,
        regexp_replace(ctx.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', '')      AS Subrole,
        ctx.Calc_Hash,
        TRY_CAST(regexp_extract(ctx.Calc_UUID, '_([0-9]+)$', 1) AS BIGINT) AS Disp_Index
    FROM DDR_ChunkListContexts ctx
    WHERE ctx.Chunk_Count = 0
      AND ctx.Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
),
lo1 AS (
    SELECT Object_UUID, File_Name, Text_Content,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    WHERE Text_Content LIKE '%<<%'
),
formulas AS (
    SELECT
        e.File_Name, e.Subrole, e.Calc_Hash,
        lo.Object_UUID,
        regexp_replace(
            regexp_replace(
                regexp_extract_all(lo.Text_Content, '(?s)<<ƒ:(.*?)>>', 1)[e.Disp_Index + 1],
                '^%[A-Z]+:', ''),
            '"[^"]*"', '', 'g') AS formula_noliterals
    FROM empty_disp e
    JOIN lo1 lo
      ON upper(lo.Object_UUID) = e.Anchor_UUID
     AND lo.File_Name = e.File_Name
     AND lo.rn = 1
)
SELECT DISTINCT
    f.Object_UUID, 'LayoutObject', NULL, f.Subrole,
    f.Calc_Hash, 'variable',
    NULL,
    v.var_name,
    f.File_Name,
    NULL, NULL,
    CASE
        WHEN v.var_name LIKE '$$$%' THEN 'superglobal'
        WHEN v.var_name LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM formulas f
CROSS JOIN LATERAL unnest(
    regexp_extract_all(f.formula_noliterals, '\$\$?\$?[\p{L}_][\p{L}\p{N}_]*')
) as v(var_name)
WHERE f.formula_noliterals IS NOT NULL;


-- ============================================
-- A.7 — Built-in FunctionRef in XMLCalcReferences
-- ============================================
-- Built-in FileMaker-Funktionen (Get, Case, If, Length, …) erscheinen im DDR als
-- FunctionRef-Chunks. Wir spiegeln sie als Ref_Type='function' in XMLCalcReferences
-- für die fünf Quell-Kontexte. Built-ins haben keine UUID in der FileMaker-Lösung —
-- die kanonische Identität liegt in fm_spec.functions / function_name_lookup.
--
-- Für den Token 'Get' wird zusätzlich Ref_SubName aus GetSubparameterMap befüllt
-- (Pendant zur PluginFunction-Sub-Function-Auflösung).

-- A.7.1 FunctionRef in Calculated Fields (DDR_Hash)
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, NULL,
    d.Calc_Hash, 'function',
    NULL,  -- Ref_UUID: built-in functions haben keine UUID
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) AS Ref_Name,
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    CASE WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Get'
         THEN g.SubParameter ELSE NULL END,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.DDR_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
LEFT JOIN GetSubparameterMap g
       ON g.Calc_UUID = d.Calc_UUID
      AND g.File_Name = d.File_Name
      AND g.Get_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'FunctionRef'
  AND f.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.7.2 FunctionRef in AutoEnter-Calc (AE_Calc_Hash) — Subrole 'auto_enter'
-- (1.22.0): calls_function-Kanten des AutoEnter-Slots werden damit in
-- v_calculation_links dem richtigen Slot zugeordnet.
INSERT INTO XMLCalcReferences
SELECT
    f.Field_UUID, 'Field', NULL, 'auto_enter',
    d.Calc_Hash, 'function',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    CASE WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Get'
         THEN g.SubParameter ELSE NULL END,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM FieldsForTables f
JOIN _ddr_chunks_by_hash d ON f.AE_Calc_Hash = d.Calc_Hash AND f.File_Name = d.File_Name
LEFT JOIN GetSubparameterMap g
       ON g.Calc_UUID = d.Calc_UUID
      AND g.File_Name = d.File_Name
      AND g.Get_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'FunctionRef'
  AND f.AE_Calc_Hash IS NOT NULL
  AND TRUE;

-- A.7.3 FunctionRef in CustomFunctions
INSERT INTO XMLCalcReferences
SELECT
    cf.CF_UUID, 'CustomFunction', NULL, NULL,
    d.Calc_Hash, 'function',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    CASE WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Get'
         THEN g.SubParameter ELSE NULL END,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM CustomFunctionsCatalog cf
JOIN _ddr_chunks_by_hash d ON cf.DDR_Hash = d.Calc_Hash AND cf.File_Name = d.File_Name
LEFT JOIN GetSubparameterMap g
       ON g.Calc_UUID = d.Calc_UUID
      AND g.File_Name = d.File_Name
      AND g.Get_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'FunctionRef'
  AND cf.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.7.4 FunctionRef in Script-Steps
-- step_hashes: einmal materialisiert als _step_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    sh.Script_UUID, 'Script', sh.Step_Index, sh.Subrole,
    sh.Calc_Hash, 'function',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    sh.File_Name,
    NULL, NULL,
    NULL, NULL,
    CASE WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Get'
         THEN g.SubParameter ELSE NULL END,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _step_hashes sh
JOIN _ddr_chunks_by_hash d
  ON sh.Calc_Hash = d.Calc_Hash
 AND sh.File_Name = d.File_Name
LEFT JOIN GetSubparameterMap g
       ON g.Calc_UUID = d.Calc_UUID
      AND g.File_Name = d.File_Name
      AND g.Get_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'FunctionRef';

-- A.7.5 FunctionRef in LayoutObjects
-- layout_obj_hashes: einmal materialisiert als _layout_obj_hashes (s. o.)
INSERT INTO XMLCalcReferences
SELECT
    loh.Object_UUID, 'LayoutObject', NULL, loh.Subrole,
    loh.Calc_Hash, 'function',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    loh.File_Name,
    NULL, NULL,
    NULL, NULL,
    CASE WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Get'
         THEN g.SubParameter ELSE NULL END,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _layout_obj_hashes loh
JOIN _ddr_chunks_by_hash d
  ON loh.Calc_Hash = d.Calc_Hash
 AND loh.File_Name = d.File_Name
LEFT JOIN GetSubparameterMap g
       ON g.Calc_UUID = d.Calc_UUID
      AND g.File_Name = d.File_Name
      AND g.Get_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'FunctionRef';


-- ============================================
-- A.8 — Refs aus Custom Record Privileges (PrivilegeSetRecordAccess)
--
-- Custom Record Privileges, Graph-Integration (alle Ref-Typen):
-- Record-Access-Calcs (View/Edit/Create/Delete bei @access="Calculation")
-- tragen ChunkList-Hashes nach demselben Muster wie Calculated Fields & CFs.
-- Der DDR_Hash → DDR_Calculations.Calc_Hash-JOIN macht ihre Refs sichtbar.
--
-- Wirkung: schließt die Where-Used-Lücke für Felder/Variablen/CFs/Plugins, die
-- NUR in einer Record-Access-Calc vorkommen (sonst fälschlich als "ungenutzt").
-- Diese Zeilen werden vom generischen Durchlauf in create_universal_catalogs.sql
-- automatisch zu Links mit Source_Type='PrivilegeSet':
--   * FieldRef           (A.8.1) → reads_field            (Link 30)
--   * CustomFunctionRef  (A.8.3) → calls_customfunction   (Link 31)
--   * PluginFunctionRef  (A.8.4, via PluginFunctionUsages) → calls_pluginfunction (Link 34)
-- VariableReference (A.8.2) hat KEINEN generischen XMLCalcReferences→Link-Pass;
-- ihr reads_variable-Link entsteht über VariableUsages (Context_Type=
-- 'record_access_calc') in create_universal_catalogs.sql. Die XMLCalcReferences-
-- Zeile dient hier der Token-/REST-Symmetrie (tokens[] kann die Variable als Ref
-- ausliefern). Subrole trägt durchgängig "<Operation>:<Tabelle>" für feinere
-- Filterung. Cross-File ist möglich (Calc liegt im Set der nutzenden Datei,
-- referenzierte UUID kann fremd sein).
-- ============================================

-- A.8.1 FieldRef in Custom Record Privileges (DDR_Hash)
INSERT INTO XMLCalcReferences
SELECT
    ra.PrivilegeSet_UUID, 'PrivilegeSet', NULL,
    ra.Operation || ':' || COALESCE(ra.BaseTable_Name, '<New>'),  -- Subrole
    d.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    d.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,  -- Variable_Scope, Usage_Type (nur für Ref_Type='variable')
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM PrivilegeSetRecordAccess ra
JOIN _ddr_chunks_by_hash d ON ra.DDR_Hash = d.Calc_Hash AND ra.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef'
  AND ra.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.8.2 VariableReference in Custom Record Privileges (DDR_Hash)
-- Gespiegelt von A.6.2 (VariableReference in Calculated Fields). Schreibt die
-- Variable als Ref nach XMLCalcReferences (Token-/REST-Symmetrie);
-- der eigentliche reads_variable-Link entsteht über VariableUsages.
INSERT INTO XMLCalcReferences
SELECT
    ra.PrivilegeSet_UUID, 'PrivilegeSet', NULL,
    ra.Operation || ':' || COALESCE(ra.BaseTable_Name, '<New>'),  -- Subrole
    d.Calc_Hash, 'variable',
    NULL,                                                          -- Ref_UUID (Variablen: NULL)
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),       -- Ref_Name = $$Var
    d.File_Name,
    NULL, NULL,                                                   -- TO_Name, TO_UUID
    CASE
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$$%' THEN 'superglobal'
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM PrivilegeSetRecordAccess ra
JOIN _ddr_chunks_by_hash d ON ra.DDR_Hash = d.Calc_Hash AND ra.File_Name = d.File_Name
WHERE d.Chunk_Type = 'VariableReference'
  AND ra.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.8.3 CustomFunctionRef in Custom Record Privileges (DDR_Hash)
-- Gespiegelt von A.2.2 (CustomFunctionRef in Calculated Fields). Wird vom
-- generischen Durchlauf (create_universal_catalogs.sql Link 31) zu
-- calls_customfunction-Links mit Source_Type='PrivilegeSet' aufgelöst.
INSERT INTO XMLCalcReferences
SELECT
    ra.PrivilegeSet_UUID, 'PrivilegeSet', NULL,
    ra.Operation || ':' || COALESCE(ra.BaseTable_Name, '<New>'),  -- Subrole
    d.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),       -- Ref_Name = CF-Name
    d.File_Name,
    NULL, NULL,
    NULL, NULL,  -- Variable_Scope, Usage_Type
    NULL,  -- Ref_SubName (nur für Ref_Type='pluginfunction' bei Container-Plugins)
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM PrivilegeSetRecordAccess ra
JOIN _ddr_chunks_by_hash d ON ra.DDR_Hash = d.Calc_Hash AND ra.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef'
  AND ra.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.8.4 PluginFunctionRef in Custom Record Privileges → PluginFunctionUsages
-- Gespiegelt von A.2.3 (PluginFunctionRef in Calculated Fields). Schreibt nach
-- PluginFunctionUsages (NICHT direkt nach XMLCalcReferences-Link-Pfad), da
-- create_universal_catalogs.sql Link 34 (calls_pluginfunction) aus dieser Tabelle
-- speist. Positionsbezug (Calc_UUID, Plugin_Chunk_Index) macht den SubName-JOIN
-- mit MBS_SubnameMap eindeutig. Subrole trägt "<Operation>:<Tabelle>".
INSERT INTO PluginFunctionUsages
SELECT
    ra.PrivilegeSet_UUID, 'PrivilegeSet', NULL,
    ra.Operation || ':' || COALESCE(ra.BaseTable_Name, '<New>'),  -- Subrole
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),       -- Plugin_Function_Name
    d.Calc_Hash,
    d.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM PrivilegeSetRecordAccess ra
JOIN _ddr_chunks_by_hash d ON ra.DDR_Hash = d.Calc_Hash AND ra.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND ra.DDR_Hash IS NOT NULL
  AND TRUE;

-- A.8.5 PluginFunctionRef in Custom Record Privileges → XMLCalcReferences
-- Zusätzlich zur PluginFunctionUsages-Zeile (A.8.4): macht den Plugin-Aufruf
-- auch im Token-/REST-Output als Ref sichtbar (analog A.6.1 für Felder).
-- Ref_SubName aus MBS_SubnameMap (NULL für Nicht-Container-Plugins).
INSERT INTO XMLCalcReferences
SELECT
    ra.PrivilegeSet_UUID, 'PrivilegeSet', NULL,
    ra.Operation || ':' || COALESCE(ra.BaseTable_Name, '<New>'),  -- Subrole
    d.Calc_Hash, 'pluginfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),       -- Ref_Name = Plugin-Funktion
    d.File_Name,
    NULL, NULL,
    NULL, NULL,  -- Variable_Scope, Usage_Type
    m.SubName,  -- Ref_SubName
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM PrivilegeSetRecordAccess ra
JOIN _ddr_chunks_by_hash d ON ra.DDR_Hash = d.Calc_Hash AND ra.File_Name = d.File_Name
LEFT JOIN MBS_SubnameMap m
       ON m.Calc_UUID = d.Calc_UUID
      AND m.File_Name = d.File_Name
      AND m.Plugin_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'PluginFunctionRef'
  AND ra.DDR_Hash IS NOT NULL
  AND TRUE;


-- ============================================
-- A.9 — Refs aus Custom Menus (CustomMenu + CustomMenuItem, AP-3B)
-- ============================================
-- Menü-Formeln (Install-/Title-Bedingungen auf Menü-Ebene, Install-/Name-Calcs
-- auf Item-Ebene) trugen bislang KEINE Graph-Kanten → Felder/Variablen/CFs/
-- Plugins, die NUR in einer Menü-Formel vorkommen, erschienen fälschlich
-- „ungenutzt". Analog zum PrivilegeSet-Pass (A.8): der Anker `_<UUID>_<kind>`
-- der Calc identifiziert das Menü (CustomMenuCatalog) bzw. Item
-- (CustomMenuItemCatalog); der DDR_Hash-Join macht die Refs sichtbar.
-- Die Kanten selbst (reads_field / calls_customfunction / calls_function /
-- calls_pluginfunction) entstehen automatisch im generischen P4-Durchlauf
-- (Blöcke 30–34, Ref_Type-gefiltert, Source_Type-agnostisch, Subrole → Link_Subrole).
-- VariableReference → reads_variable läuft über VariableUsages (P3, custom_menu_calc).
-- Subrole = calc_kind (Install | Title | Name).

-- Wartbarkeit: die Menü-Anker-Map (CustomMenu + CustomMenuItem, upper(UUID))
-- war 6× byte-identisch inline in A.9.1–A.9.6 → Drift-Risiko. Einmal als TEMP hoisten.
-- Klein (~10k Zeilen, <1 MB → keine OOM-Relevanz). Partitions-sicher: jede P2-Slice baut
-- ihre eigene TEMP aus den gefilterten src-Views; der Join bleibt File_Name-skopiert, die
-- Union über die Slices == Single-Pass (bit-identisch). resolve.sql ist nicht streamifiziert.
CREATE TEMP TABLE _menu_anchors AS
    SELECT upper(Menu_UUID) AS Anchor_UUID, File_Name, 'CustomMenu' AS Src_Type, Menu_UUID AS Src_UUID FROM CustomMenuCatalog
    UNION ALL
    SELECT upper(Item_UUID), File_Name, 'CustomMenuItem', Item_UUID FROM CustomMenuItemCatalog;

-- A.9.1 FieldRef in Menü-Formeln
INSERT INTO XMLCalcReferences
SELECT
    o.Src_UUID, o.Src_Type, NULL,
    regexp_replace(d.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', ''),      -- Subrole = Install|Title|Name
    d.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    d.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL, NULL,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM DDR_Calculations d
JOIN _menu_anchors o ON o.Anchor_UUID = upper(regexp_extract(d.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
   AND o.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef';

-- A.9.2 VariableReference in Menü-Formeln (Token-/REST-Symmetrie; reads_variable-Link via VariableUsages)
INSERT INTO XMLCalcReferences
SELECT
    o.Src_UUID, o.Src_Type, NULL,
    regexp_replace(d.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', ''),
    d.Calc_Hash, 'variable',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    CASE
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$$%' THEN 'superglobal'
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM DDR_Calculations d
JOIN _menu_anchors o ON o.Anchor_UUID = upper(regexp_extract(d.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
   AND o.File_Name = d.File_Name
WHERE d.Chunk_Type = 'VariableReference';

-- A.9.3 CustomFunctionRef in Menü-Formeln
INSERT INTO XMLCalcReferences
SELECT
    o.Src_UUID, o.Src_Type, NULL,
    regexp_replace(d.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', ''),
    d.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL, NULL,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM DDR_Calculations d
JOIN _menu_anchors o ON o.Anchor_UUID = upper(regexp_extract(d.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
   AND o.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef';

-- A.9.4 PluginFunctionRef in Menü-Formeln → PluginFunctionUsages (speist P4-Block 34)
INSERT INTO PluginFunctionUsages
SELECT
    o.Src_UUID, o.Src_Type, NULL,
    regexp_replace(d.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', ''),
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.Calc_Hash,
    d.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM DDR_Calculations d
JOIN _menu_anchors o ON o.Anchor_UUID = upper(regexp_extract(d.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
   AND o.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef';

-- A.9.5 PluginFunctionRef in Menü-Formeln → XMLCalcReferences (Token-/REST-Symmetrie)
INSERT INTO XMLCalcReferences
SELECT
    o.Src_UUID, o.Src_Type, NULL,
    regexp_replace(d.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', ''),
    d.Calc_Hash, 'pluginfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    m.SubName,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM DDR_Calculations d
JOIN _menu_anchors o ON o.Anchor_UUID = upper(regexp_extract(d.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
   AND o.File_Name = d.File_Name
LEFT JOIN MBS_SubnameMap m
       ON m.Calc_UUID = d.Calc_UUID
      AND m.File_Name = d.File_Name
      AND m.Plugin_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'PluginFunctionRef';

-- A.9.6 Built-in FunctionRef in Menü-Formeln (→ calls_function, analog A.7 + LayoutObject)
-- Menü-Install-/Title-/Name-Bedingungen bestehen praktisch nur aus Built-ins
-- (Get, Abs, If …) + Literalen; ohne diesen Pass hätte der CustomMenu-Graph keine
-- operationalen Formel-Kanten. Get(<SubName>) wird via GetSubparameterMap aufgelöst.
INSERT INTO XMLCalcReferences
SELECT
    o.Src_UUID, o.Src_Type, NULL,
    regexp_replace(d.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', ''),      -- Subrole = Install|Title|Name
    d.Calc_Hash, 'function',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    CASE WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Get'
         THEN g.SubParameter ELSE NULL END,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM DDR_Calculations d
JOIN _menu_anchors o ON o.Anchor_UUID = upper(regexp_extract(d.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
   AND o.File_Name = d.File_Name
LEFT JOIN GetSubparameterMap g
       ON g.Calc_UUID = d.Calc_UUID
      AND g.File_Name = d.File_Name
      AND g.Get_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'FunctionRef';


-- ============================================
-- A.12 — Refs aus Layout-/File-Level-Trigger-Parametern (Schema 1.22.0)
-- ============================================
-- Layout- und File-Level-ScriptTrigger tragen ihre Parameter-Berechnung als
-- DDRREF im Trigger-Fragment (ScriptTriggers.Trigger_XML, nur für diese beiden
-- Owner-Typen persistiert — Object-Level-Trigger stecken in
-- LayoutObjects.Object_XML und laufen über _layout_obj_hashes/A.5–A.7).
-- Vor 1.22.0 waren diese Anker (z.B. 21× ScriptTrigger_103 im Referenz-Korpus)
-- ohne Owner-Kanten: ein NUR im Layout-Trigger-Parameter gelesenes Feld war
-- Where-used-unsichtbar. Source_Type = Owner_Type ('Layout'|'File'),
-- Subrole = DDRREF-Suffix ('ScriptTrigger_<id>' — identisch zur
-- LayoutObject-Konvention, matcht CalculationsCatalog.Calc_Kind_Raw).
-- Struktur analog A.5/A.9: eigene Hash-Ernte, dann je Chunk-Typ ein Insert.
-- Läuft VOR dem Entity-Decode-Post-Pass (Namen werden zentral dekodiert) und
-- VOR A.10 (PluginFunctionUsages-Zeilen werden MBS-qualifiziert).
CREATE OR REPLACE TEMP TABLE _trigger_hashes AS
SELECT
    Owner_UUID, Owner_Type, File_Name,
    regexp_extract(m, 'hash="([^"]+)"', 1) AS Calc_Hash,
    regexp_extract(m, '>_[A-F0-9-]{36}_([^<]+)</DDRREF>', 1) AS Subrole
FROM (
    SELECT
        st.Owner_UUID,
        st.Owner_Type,
        st.File_Name,
        unnest(regexp_extract_all(st.Trigger_XML,
            'kind="ChunkList" hash="([^"]+)"[^>]*>_[A-F0-9-]{36}_([^<]+)</DDRREF>')) AS m
    FROM ScriptTriggers st
    WHERE st.Owner_Type IN ('Layout', 'File')
      AND st.Trigger_XML LIKE '%DDRREF%'
);

-- A.12.1 FieldRef in Trigger-Parametern
INSERT INTO XMLCalcReferences
SELECT
    th.Owner_UUID, th.Owner_Type, NULL, th.Subrole,
    d.Calc_Hash, 'field',
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1),
    regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1),
    d.File_Name,
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), ''),
    NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), ''),
    NULL, NULL,  -- Variable_Scope, Usage_Type
    NULL,        -- Ref_SubName
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'FieldReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS Ref_ID,
    TRY_CAST(NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]* id="([^"]+)"', 1), '') AS BIGINT) AS TO_Ref_ID
FROM _trigger_hashes th
JOIN _ddr_chunks_by_hash d ON th.Calc_Hash = d.Calc_Hash AND th.File_Name = d.File_Name
WHERE d.Chunk_Type = 'FieldRef';

-- A.12.2 CustomFunctionRef in Trigger-Parametern
INSERT INTO XMLCalcReferences
SELECT
    th.Owner_UUID, th.Owner_Type, NULL, th.Subrole,
    d.Calc_Hash, 'customfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    NULL,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _trigger_hashes th
JOIN _ddr_chunks_by_hash d ON th.Calc_Hash = d.Calc_Hash AND th.File_Name = d.File_Name
WHERE d.Chunk_Type = 'CustomFunctionRef';

-- A.12.3 Built-in FunctionRef in Trigger-Parametern (Get(<Sub>) via GetSubparameterMap)
INSERT INTO XMLCalcReferences
SELECT
    th.Owner_UUID, th.Owner_Type, NULL, th.Subrole,
    d.Calc_Hash, 'function',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    CASE WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Get'
         THEN g.SubParameter ELSE NULL END,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _trigger_hashes th
JOIN _ddr_chunks_by_hash d ON th.Calc_Hash = d.Calc_Hash AND th.File_Name = d.File_Name
LEFT JOIN GetSubparameterMap g
       ON g.Calc_UUID = d.Calc_UUID
      AND g.File_Name = d.File_Name
      AND g.Get_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'FunctionRef';

-- A.12.4 VariableReference in Trigger-Parametern (Provenienz-Zeile; die
-- reads_variable-Links laufen wie überall über VariableUsages/P3)
INSERT INTO XMLCalcReferences
SELECT
    th.Owner_UUID, th.Owner_Type, NULL, th.Subrole,
    d.Calc_Hash, 'variable',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    CASE
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$$%' THEN 'superglobal'
        WHEN regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) LIKE '$$%'  THEN 'global'
        ELSE 'local'
    END,
    'read',
    NULL,
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _trigger_hashes th
JOIN _ddr_chunks_by_hash d ON th.Calc_Hash = d.Calc_Hash AND th.File_Name = d.File_Name
WHERE d.Chunk_Type = 'VariableReference'
  AND regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) <> 'Function Missing';

-- A.12.5 PluginFunctionRef in Trigger-Parametern → PluginFunctionUsages
-- (speist P4-Block 34; A.10 qualifiziert MBS-Aufrufe anschließend)
INSERT INTO PluginFunctionUsages
SELECT
    th.Owner_UUID, th.Owner_Type, NULL, th.Subrole,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.Calc_Hash,
    d.File_Name,
    d.Calc_UUID,
    d.Chunk_Index
FROM _trigger_hashes th
JOIN _ddr_chunks_by_hash d ON th.Calc_Hash = d.Calc_Hash AND th.File_Name = d.File_Name
WHERE d.Chunk_Type = 'PluginFunctionRef';

-- A.12.6 PluginFunctionRef in Trigger-Parametern → XMLCalcReferences
-- (Token-/REST-Symmetrie, analog A.9.5)
INSERT INTO XMLCalcReferences
SELECT
    th.Owner_UUID, th.Owner_Type, NULL, th.Subrole,
    d.Calc_Hash, 'pluginfunction',
    NULL,
    regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1),
    d.File_Name,
    NULL, NULL,
    NULL, NULL,
    m.SubName,  -- Ref_SubName
    NULL AS Ref_ID,
    NULL AS TO_Ref_ID
FROM _trigger_hashes th
JOIN _ddr_chunks_by_hash d ON th.Calc_Hash = d.Calc_Hash AND th.File_Name = d.File_Name
LEFT JOIN MBS_SubnameMap m
       ON m.Calc_UUID = d.Calc_UUID
      AND m.File_Name = d.File_Name
      AND m.Plugin_Chunk_Index = d.Chunk_Index
WHERE d.Chunk_Type = 'PluginFunctionRef';


-- ============================================
-- Entity-Decode (zentraler Post-Pass)
-- ============================================
-- XMLCalcReferences und PluginFunctionUsages werden AUSSCHLIESSLICH aus rohen
-- DDR_Calculations-Chunks befüllt (Field-/CF-/Plugin-/Function-/Variable-Namen
-- per regexp_extract aus dem Chunk-String). Der Roh-String trägt un-dekodierte
-- XML-Entities (`Datens&#xE4;tze`, `Schl&#xFC;ssel`), die Regex NICHT dekodiert.
-- Ein einziger Decode-Pass hier normalisiert alle Namensspalten zentral, BEVOR
-- Phase 4 daraus md5-UUIDs/ObjectLinks baut → UUID-Konsistenz garantiert.
-- (Die UUID-/Chunk-Index-Spalten bleiben unberührt; die SubName-JOINs liefen
-- bereits oben über Chunk_Index, nicht über Namen.) Idempotent: html_unescape
-- lässt entity-freie Strings unverändert; LIKE-Guard spart den No-op-Scan.
-- wa_entity_decode-gegatet (Default ON): WHERE-Guard schaltet den Decode komplett ab,
-- wenn das Flag OFF ist (No-op, kein Schreibzugriff) — siehe Flag-Definition oben.
UPDATE XMLCalcReferences    SET Ref_Name    = html_unescape(Ref_Name)    WHERE getvariable('wa_entity_decode') AND Ref_Name    LIKE '%&%';
UPDATE XMLCalcReferences    SET TO_Name     = html_unescape(TO_Name)     WHERE getvariable('wa_entity_decode') AND TO_Name     LIKE '%&%';
-- Ref_SubName: Get(<SubName>) trägt den lokalisierten Funktionsnamen (→ BuiltinFunction
-- `Get(AnzahlGefundeneDatensätze)`); MBS-SubNames sind ASCII und vom LIKE-Guard ausgenommen.
UPDATE XMLCalcReferences    SET Ref_SubName = html_unescape(Ref_SubName) WHERE getvariable('wa_entity_decode') AND Ref_SubName LIKE '%&%';
UPDATE PluginFunctionUsages SET Plugin_Function_Name = html_unescape(Plugin_Function_Name) WHERE getvariable('wa_entity_decode') AND Plugin_Function_Name LIKE '%&%';
-- B-R6: auch die GetSubparameterMap-TABELLE dekodieren (der Pass oben dekodiert nur
-- die Kopie in XMLCalcReferences.Ref_SubName — Direkt-Konsumenten der Map sahen
-- `Datens&#xE4;tze…` als SubParameter, 1.887 Zeilen im Korpus).
UPDATE GetSubparameterMap SET SubParameter = html_unescape(SubParameter) WHERE getvariable('wa_entity_decode') AND SubParameter LIKE '%&%';


-- ============================================
-- A.10 — MBS-Methode qualifizieren (AP-5A / D-6)
-- ============================================
-- `PluginFunctionUsages.Plugin_Function_Name` trägt für MBS-Aufrufe nur den äußeren
-- Funktionsnamen `MBS`; die fachliche Methode (FM.RunScript, List.AddValue, IsError …)
-- steckt im 1. String-Argument und ist bereits in MBS_SubnameMap extrahiert (Proximity-
-- Paarung, key = (Calc_UUID, File_Name, Plugin_Chunk_Index) — validiert eindeutig, kein
-- Fan-out). Qualifizieren zu `MBS:<Methode>` (Prefix `MBS` erhalten, rückwärtskompatibel).
-- Downstream: P4-Block 25/34 registrieren dann granulare PluginFunction-Objekte
-- `MBS:FM.RunScript` statt eines Sammel-`MBS`. Nicht auflösbare (SubName NULL, ~9 %)
-- bleiben generisch `MBS`. Voll-Key-Join (NICHT nur Calc_UUID — das paart falsch).
UPDATE PluginFunctionUsages p
SET Plugin_Function_Name = 'MBS:' || m.SubName
FROM MBS_SubnameMap m
WHERE p.Plugin_Function_Name = 'MBS'
  AND m.Calc_UUID = p.Calc_UUID
  AND m.File_Name = p.File_Name
  AND m.Plugin_Chunk_Index = p.Plugin_Chunk_Index
  AND m.SubName IS NOT NULL;
