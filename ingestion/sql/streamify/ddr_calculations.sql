-- streamify-Override für DDR_Calculations.
-- Wie DDR_ScriptSteps: auf dem eindeutigen DDR_INFO ankern, Calculation-Kind als
-- VARCHAR kapseln (Klasse-C), Calc-Elemente re-extrahieren. Calc_UUID via Regex auf
-- Element-NAMEN, Calc_Hash via xml_extract. HINWEIS: Chunk_Content fällt für chunks
-- ohne direkten Text auf chunk_xml::VARCHAR (Roh-Serialisierung) zurück → kann unter
-- SAX abweichen (Option-1: abgeleitete Tabellen bleiben identisch, da xml_extract
-- decodiert). Ab hier identisch zur Basis: EIN materialisierter Parse (_ddr_calc_raw),
-- Chunk-/Kontext-Ableitung, Profil-Blöcke (saxml22 direkt, saxml23 mit Staging der
-- DisplayCalculations-Anker) — nur der ddr_calc_raw-Anker ist der SAX-Read.
CREATE OR REPLACE TEMP TABLE _ddr_calc_raw AS
SELECT
    unnest(xml_extract_elements('<Calculation>' || Calculation || '</Calculation>', '/Calculation/ObjectList/*')) as calc_elem
FROM read_xml(
    getvariable('fm_xml'),
    record_element='DDR_INFO',
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'Calculation':'VARCHAR'}
)
WHERE Calculation IS NOT NULL;

-- Chunk-Index in XML-Dokumentreihenfolge:
-- Zwei parallele unnest()-Aufrufe iterieren synchron pro Zeile. Die Chunk-Liste
-- und ein begleitendes generate_series mit derselben Länge erzeugen einen
-- deterministischen, lesegerechten Chunk_Index. Vorgängerlösung mit
-- ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) war nicht-deterministisch.
-- Slot-Suffix erhalten: '_<UUID>_<Slot>' (numerisch UND benannt,
-- formatunabhängig bis zum ersten Whitespace/'>'). Die alte Variante
-- '<_([0-9A-F-]+)' schnitt den Slot ab → verschiedene Slots derselben
-- UUID kollidierten im PK (Calc_UUID, Chunk_Index, File_Name) und
-- überschrieben sich per ON CONFLICT DO UPDATE (~36-41% Definitionsverlust).
-- Calc_UUID wird nirgends mit Objekt-UUIDs gejoint (alle Objekt-Joins
-- laufen über Calc_Hash), daher ist die Bedeutungsänderung
-- "Objekt-UUID" → "Berechnungs-Instanz-ID (UUID+Slot)" unkritisch.
CREATE OR REPLACE TEMP TABLE _ddr_calc_chunks AS
WITH calc_with_chunk_lists AS (
    SELECT
        regexp_extract(calc_elem::VARCHAR, '<(_[^\s>]+)', 1) as Calc_UUID,
        xml_extract_text(calc_elem, '//*/@hash')[1] as Calc_Hash,
        xml_extract_elements(calc_elem, '//ChunkList/Chunk') as chunks
    FROM _ddr_calc_raw
    WHERE xml_extract_text(calc_elem, '//*/@datatype')[1] = 'ChunkList'
),
calc_with_chunks AS (
    SELECT
        Calc_UUID,
        Calc_Hash,
        unnest(chunks) as chunk_xml,
        unnest(generate_series(1, len(chunks))) as chunk_index
    FROM calc_with_chunk_lists
)
SELECT
    Calc_UUID,
    Calc_Hash,
    chunk_index as Chunk_Index,
    xml_extract_text(chunk_xml, '/Chunk/@type')[1] as Chunk_Type,
    -- ws_restore: Chunk_Content ist Formel-Text — ohne Restore leakte der
    -- 0x7F-Sentinel bei CR-haltigen Formeln in alle Downstream-Konsumenten
    -- (Variablen-Parser, Menü-Kanten, Referenz-Regexe).
    ws_restore(COALESCE(
        xml_extract_text(chunk_xml, 'text()')[1],
        chunk_xml::VARCHAR
    )) as Chunk_Content,
    getvariable('fm_file') as File_Name
FROM calc_with_chunks;

-- Kontext je ChunkList-Anker (auch leere ChunkLists). '/*/TableOccurrenceReference'
-- greift NUR das direkte Kind des Ankers — FieldRef-Chunks nesten eigene
-- TableOccurrenceReferences tiefer (unter ChunkList/Chunk/FieldReference) und
-- bleiben bewusst außen vor.
CREATE OR REPLACE TEMP TABLE _ddr_calc_ctx AS
SELECT
    regexp_extract(calc_elem::VARCHAR, '<(_[^\s>]+)', 1) as Calc_UUID,
    xml_extract_text(calc_elem, '//*/@hash')[1] as Calc_Hash,
    len(xml_extract_elements(calc_elem, '//ChunkList/Chunk')) as Chunk_Count,
    TRY_CAST(NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@id')[1], '') AS BIGINT) as Context_TO_ID,
    NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@name')[1], '') as Context_TO_Name,
    NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@UUID')[1], '') as Context_TO_UUID,
    getvariable('fm_file') as File_Name
FROM _ddr_calc_raw
WHERE xml_extract_text(calc_elem, '//*/@datatype')[1] = 'ChunkList';

-- Profil saxml22: alle Anker direkt in die DDR-Tabellen (22 polstert nicht).
-- @P1_PROFILE:saxml22@
INSERT INTO DDR_Calculations
SELECT Calc_UUID, Calc_Hash, Chunk_Index, Chunk_Type, Chunk_Content, File_Name
FROM _ddr_calc_chunks
ON CONFLICT (Calc_UUID, Chunk_Index, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Type = EXCLUDED.Chunk_Type,
    Chunk_Content = EXCLUDED.Chunk_Content;

INSERT INTO DDR_ChunkListContexts
SELECT Calc_UUID, Calc_Hash, Chunk_Count, Context_TO_ID, Context_TO_Name, Context_TO_UUID, File_Name
FROM _ddr_calc_ctx
WHERE Calc_UUID IS NOT NULL AND Calc_UUID <> ''
ON CONFLICT (Calc_UUID, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Count = EXCLUDED.Chunk_Count,
    Context_TO_ID = EXCLUDED.Context_TO_ID,
    Context_TO_Name = EXCLUDED.Context_TO_Name,
    Context_TO_UUID = EXCLUDED.Context_TO_UUID;
-- @END_P1_PROFILE@

-- Profil saxml23: DisplayCalculations-Anker → Staging DDR_DisplayCalcAnchors23
-- (Promotion in P1d nach der Token-Regel), alle übrigen Anker direkt.
-- @P1_PROFILE:saxml23@
INSERT INTO DDR_Calculations
SELECT Calc_UUID, Calc_Hash, Chunk_Index, Chunk_Type, Chunk_Content, File_Name
FROM _ddr_calc_chunks
WHERE Calc_UUID NOT LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
ON CONFLICT (Calc_UUID, Chunk_Index, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Type = EXCLUDED.Chunk_Type,
    Chunk_Content = EXCLUDED.Chunk_Content;

INSERT INTO DDR_ChunkListContexts
SELECT Calc_UUID, Calc_Hash, Chunk_Count, Context_TO_ID, Context_TO_Name, Context_TO_UUID, File_Name
FROM _ddr_calc_ctx
WHERE Calc_UUID IS NOT NULL AND Calc_UUID <> ''
  AND Calc_UUID NOT LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
ON CONFLICT (Calc_UUID, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Count = EXCLUDED.Chunk_Count,
    Context_TO_ID = EXCLUDED.Context_TO_ID,
    Context_TO_Name = EXCLUDED.Context_TO_Name,
    Context_TO_UUID = EXCLUDED.Context_TO_UUID;

INSERT INTO DDR_DisplayCalcAnchors23
SELECT Calc_UUID, Calc_Hash, Chunk_Index, Chunk_Type, Chunk_Content,
       NULL, NULL, NULL, NULL,
       TRY_CAST(regexp_extract(Calc_UUID, '_DisplayCalculations_([0-9]+)$', 1) AS BIGINT),
       FALSE, File_Name
FROM _ddr_calc_chunks
WHERE Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
UNION ALL
SELECT Calc_UUID, Calc_Hash, 0, NULL, NULL,
       Chunk_Count, Context_TO_ID, Context_TO_Name, Context_TO_UUID,
       TRY_CAST(regexp_extract(Calc_UUID, '_DisplayCalculations_([0-9]+)$', 1) AS BIGINT),
       FALSE, File_Name
FROM _ddr_calc_ctx
WHERE Calc_UUID IS NOT NULL AND Calc_UUID <> ''
  AND Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
ON CONFLICT (Calc_UUID, Chunk_Index, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Type = EXCLUDED.Chunk_Type,
    Chunk_Content = EXCLUDED.Chunk_Content,
    Chunk_Count = EXCLUDED.Chunk_Count,
    Context_TO_ID = EXCLUDED.Context_TO_ID,
    Context_TO_Name = EXCLUDED.Context_TO_Name,
    Context_TO_UUID = EXCLUDED.Context_TO_UUID,
    Slot_Index = EXCLUDED.Slot_Index,
    Promoted = FALSE;
-- @END_P1_PROFILE@

DROP TABLE IF EXISTS _ddr_calc_chunks;
DROP TABLE IF EXISTS _ddr_calc_ctx;
DROP TABLE IF EXISTS _ddr_calc_raw;
