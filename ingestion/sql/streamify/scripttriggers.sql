-- streamify-Override für ScriptTriggers.
-- 3-Wege-UNION (File/Layout/Object-Level) — jede Quelle per SAX-Streaming auf einem
-- eindeutigen bzw. eindeutig-genug Anker, Subtree-VARCHAR-Capture → Trigger re-extrahiert:
--   - File:   record_element='Metadata' (Capture AddAction), Owner_UUID aus FilesCatalog
--             (== /FMSaveAsXML/@UUID, verifiziert; vermeidet einen Root-Read).
--   - Layout: record_element='LC_Layout' (Renamer-Anker), Capture ScriptTriggers + UUID.
--   - Object: record_element='LayoutObject' (eindeutig-genug, alle Objekte), dito.
-- Der Owner_UUID-md5-Fallback ist serialisierungs-unabhängig (extrahierte Felder, vgl.
-- Basis-SQL) → kein DOM-Fallback mehr nötig. ScriptTriggers speichert KEINE Roh-Spalte.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
file_triggers AS (
    SELECT
        'File' as Owner_Type,
        (SELECT File_UUID FROM FilesCatalog WHERE File_Name = getvariable('fm_file')) as Owner_UUID,
        unnest(xml_extract_elements('<AddAction>' || AddAction || '</AddAction>', '/AddAction/ScriptTriggers/ScriptTrigger')) as trigger_xml
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='Metadata',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'AddAction':'VARCHAR'}
    )
    WHERE AddAction IS NOT NULL
),
layout_triggers AS (
    SELECT
        'Layout' as Owner_Type,
        UUID."#text" as Owner_UUID,
        unnest(xml_extract_elements('<ScriptTriggers>' || ScriptTriggers || '</ScriptTriggers>', '/ScriptTriggers/ScriptTrigger')) as trigger_xml
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='LC_Layout',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'UUID':'STRUCT("#text" VARCHAR)','ScriptTriggers':'VARCHAR'}
    )
    WHERE ScriptTriggers IS NOT NULL
),
-- Object-Level: NICHT über record_element='LayoutObject' (webbed-SAX emittiert nur
-- TOP-LEVEL-Objekte als Records → Trigger auf VERSCHACHTELTEN Objekten in Portal/Tab/
-- Popover/Group gingen verloren; auf Großdatei bewiesen, T5 2026-06-16). Stattdessen
-- aus der bereits rekursiv (alle Tiefen) aufgebauten LayoutObjects-Tabelle ableiten —
-- deren Object_XML ist das vollständige <LayoutObject>-Fragment inkl. direktem
-- ScriptTriggers-Kind. /LayoutObject/ScriptTriggers/ScriptTrigger greift nur die
-- EIGENEN Trigger jedes Objekts (kein Doppelzählen; jedes Kind hat seine eigene Zeile).
-- Owner_UUID = LayoutObjects.Object_UUID (sauber extrahiert, serialisierungs-unabhängig).
-- Spart zugleich einen read_xml.
-- WICHTIG (Batch-Korrektheit, T6 2026-06-16): LayoutObjects AKKUMULIERT über Dateien,
-- wenn mehrere Dateien sequenziell in DIESELBE DB schreiben (batch --jobs 1: alle
-- Dateien → Master). Ohne File_Name-Scope läse Datei N auch die Objekte der Dateien
-- 1..N-1 und fügte deren Trigger erneut ein (mit File_Name = aktuelle Datei) →
-- O(Dateien²)-Explosion mit distinkten PKs. Daher ZWINGEND auf die aktuelle Datei
-- scopen (== fm_file, wie filename_normalized + ScriptTriggers.File_Name).
object_triggers AS (
    SELECT
        'LayoutObject' as Owner_Type,
        Object_UUID as Owner_UUID,
        unnest(xml_extract_elements(Object_XML, '/LayoutObject/ScriptTriggers/ScriptTrigger')) as trigger_xml
    FROM LayoutObjects
    WHERE Object_XML LIKE '%ScriptTrigger%'
      AND File_Name = getvariable('fm_file')
),
all_triggers AS (
    SELECT * FROM file_triggers
    UNION ALL SELECT * FROM layout_triggers
    UNION ALL SELECT * FROM object_triggers
)
INSERT INTO ScriptTriggers
SELECT
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@id')[1]::BIGINT as Trigger_ID,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@action')[1] as Trigger_Action,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@browseMode')[1] as Trigger_BrowseMode,

    xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/@id')[1]::BIGINT as Script_ID,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/@name')[1] as Script_Name,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/@UUID')[1] as Script_UUID,

    -- Serialisierungs-unabhängiger md5-Fallback (identisch zur Basis-SQL).
    COALESCE(t.Owner_UUID, md5(
        COALESCE(xml_extract_text(t.trigger_xml, '/ScriptTrigger/@id')[1], '') || '|' ||
        COALESCE(xml_extract_text(t.trigger_xml, '/ScriptTrigger/@action')[1], '') || '|' ||
        COALESCE(xml_extract_text(t.trigger_xml, '/ScriptTrigger/@browseMode')[1], '') || '|' ||
        COALESCE(xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/@UUID')[1], '') || '|' ||
        t.Owner_Type
    )) as Owner_UUID,
    t.Owner_Type,

    fn.File_Name as File_Name,

    -- Trigger_XML nur für Layout-/File-Level (Schema 1.22.0, s. Basis-SQL);
    -- Object-Level bleibt NULL (Blob liegt bereits in LayoutObjects.Object_XML).
    -- SAX-Capture kann in Serialisierungs-Details vom DOM-Pfad abweichen —
    -- Konsument (P2/A.12) liest nur Attribute + DDRREF-Text (robust).
    CASE WHEN t.Owner_Type IN ('Layout', 'File')
         THEN t.trigger_xml::VARCHAR END as Trigger_XML,

    -- Modus-Scope + Transaktions-Parameterfeld (Schema 1.24.0, s. Basis-SQL):
    -- Attribut fehlt = Modus aus / kein Parameterfeld. Attribut-Extraktion ist
    -- serialisierungs-unabhängig — DOM- und SAX-Pfad bleiben bit-identisch.
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@findMode')[1] as Trigger_FindMode,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@previewMode')[1] as Trigger_PreviewMode,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@scriptParameterFieldName')[1] as Trigger_ScriptParameter_FieldName,

    -- Parameter-Klartext (Schema 1.26.0, s. Basis-SQL): xml_extract_text
    -- dekodiert CDATA/Entities — DOM- und SAX-Capture landen auf demselben
    -- Wert, obwohl die Roh-Serialisierung divergieren kann.
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/Calculation/Text')[1] as Trigger_Parameter_Text

FROM all_triggers t
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(t.trigger_xml, '/ScriptTrigger/@id')[1] IS NOT NULL
ON CONFLICT (Trigger_ID, Owner_UUID, File_Name) DO UPDATE SET
    Trigger_Action = EXCLUDED.Trigger_Action,
    Trigger_BrowseMode = EXCLUDED.Trigger_BrowseMode,
    Script_ID = EXCLUDED.Script_ID,
    Script_Name = EXCLUDED.Script_Name,
    Script_UUID = EXCLUDED.Script_UUID,
    Owner_Type = EXCLUDED.Owner_Type,
    Trigger_XML = EXCLUDED.Trigger_XML,
    Trigger_FindMode = EXCLUDED.Trigger_FindMode,
    Trigger_PreviewMode = EXCLUDED.Trigger_PreviewMode,
    Trigger_ScriptParameter_FieldName = EXCLUDED.Trigger_ScriptParameter_FieldName,
    Trigger_Parameter_Text = EXCLUDED.Trigger_Parameter_Text;
