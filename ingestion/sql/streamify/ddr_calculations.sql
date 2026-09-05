-- streamify-Override für DDR_Calculations.
-- Wie DDR_ScriptSteps: auf dem eindeutigen DDR_INFO ankern, Calculation-Kind als
-- VARCHAR kapseln (Klasse-C), Calc-Elemente re-extrahieren. Calc_UUID via Regex auf
-- Element-NAMEN, Calc_Hash via xml_extract. HINWEIS: Chunk_Content fällt für chunks
-- ohne direkten Text auf chunk_xml::VARCHAR (Roh-Serialisierung) zurück → kann unter
-- SAX abweichen (Option-1: abgeleitete Tabellen bleiben identisch, da xml_extract
-- decodiert). Chunk-Extraktion + INSERT identisch zur Basis.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
ddr_calc_raw AS (
    SELECT
        unnest(xml_extract_elements('<Calculation>' || Calculation || '</Calculation>', '/Calculation/ObjectList/*')) as calc_elem
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='DDR_INFO',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'Calculation':'VARCHAR'}
    )
    WHERE Calculation IS NOT NULL
),
calc_with_chunk_lists AS (
    SELECT
        regexp_extract(
            calc_elem::VARCHAR,
            '<(_[^\s>]+)',
            1
        ) as Calc_UUID,
        xml_extract_text(calc_elem, '//*/@hash')[1] as Calc_Hash,
        xml_extract_elements(calc_elem, '//ChunkList/Chunk') as chunks
    FROM ddr_calc_raw
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
INSERT INTO DDR_Calculations
SELECT
    Calc_UUID,
    Calc_Hash,
    chunk_index as Chunk_Index,
    xml_extract_text(chunk_xml, '/Chunk/@type')[1] as Chunk_Type,
    -- ws_restore — identisch zur DOM-Basis (Begründung dort).
    ws_restore(COALESCE(
        xml_extract_text(chunk_xml, 'text()')[1],
        chunk_xml::VARCHAR
    )) as Chunk_Content,
    fn.File_Name as File_Name
FROM calc_with_chunks
CROSS JOIN filename_normalized fn
ON CONFLICT (Calc_UUID, Chunk_Index, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Type = EXCLUDED.Chunk_Type,
    Chunk_Content = EXCLUDED.Chunk_Content;

-- DDR_ChunkListContexts: zweiter Pass über dieselben ObjectList-Einträge
-- (Begründung + Pfad-Semantik in der DOM-Basis). Extraktion identisch zur
-- Basis, nur der ddr_calc_raw-Anker ist der SAX-Read.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
ddr_calc_raw AS (
    SELECT
        unnest(xml_extract_elements('<Calculation>' || Calculation || '</Calculation>', '/Calculation/ObjectList/*')) as calc_elem
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='DDR_INFO',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'Calculation':'VARCHAR'}
    )
    WHERE Calculation IS NOT NULL
),
chunk_list_ctx AS (
    SELECT
        regexp_extract(calc_elem::VARCHAR, '<(_[^\s>]+)', 1) as Calc_UUID,
        xml_extract_text(calc_elem, '//*/@hash')[1] as Calc_Hash,
        len(xml_extract_elements(calc_elem, '//ChunkList/Chunk')) as Chunk_Count,
        TRY_CAST(NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@id')[1], '') AS BIGINT) as Context_TO_ID,
        NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@name')[1], '') as Context_TO_Name,
        NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@UUID')[1], '') as Context_TO_UUID
    FROM ddr_calc_raw
    WHERE xml_extract_text(calc_elem, '//*/@datatype')[1] = 'ChunkList'
)
INSERT INTO DDR_ChunkListContexts
SELECT
    c.Calc_UUID,
    c.Calc_Hash,
    c.Chunk_Count,
    c.Context_TO_ID,
    c.Context_TO_Name,
    c.Context_TO_UUID,
    fn.File_Name
FROM chunk_list_ctx c
CROSS JOIN filename_normalized fn
WHERE c.Calc_UUID IS NOT NULL AND c.Calc_UUID <> ''
ON CONFLICT (Calc_UUID, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Count = EXCLUDED.Chunk_Count,
    Context_TO_ID = EXCLUDED.Context_TO_ID,
    Context_TO_Name = EXCLUDED.Context_TO_Name,
    Context_TO_UUID = EXCLUDED.Context_TO_UUID;
