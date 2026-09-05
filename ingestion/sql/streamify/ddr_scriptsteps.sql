-- streamify-Override für DDR_ScriptSteps.
-- DDR-Elemente haben dynamische Namen (<_UUID>) → kein per-Record-Anker. Stattdessen
-- auf dem EINDEUTIGEN DDR_INFO ankern (kein Renamer nötig) und das Script-Kind als
-- VARCHAR kapseln (Klasse-C), dann die Step-Elemente re-extrahieren. Vermeidet den
-- read_xml_objects-Whole-Doc-DOM. Speichert KEINE Roh-Spalte (Step_UUID via Regex auf
-- Element-NAMEN, Step_Hash/Step_Text via xml_extract) → voll bit-identisch erwartet.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
ddr_script_raw AS (
    SELECT
        unnest(xml_extract_elements('<Script>' || Script || '</Script>', '/Script/ObjectList/*')) as step_elem
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='DDR_INFO',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'Script':'VARCHAR'}
    )
    WHERE Script IS NOT NULL
)
INSERT INTO DDR_ScriptSteps
SELECT
    -- UUID-lose StepText-Records (button-eingebettete Einzel-Steps: <_ hash="…">, ohne
    -- Element-UUID) fallen auf 'hash:'||Step_Hash zurück. Ohne diesen Fallback kollidieren
    -- ALLE UUID-losen Records auf dem leeren PK (Step_UUID='') und ON CONFLICT behält pro
    -- Datei nur EINEN — die Button-Step-Klartexte gingen so verloren (via DDRREF-Hash
    -- auflösbar für die LayoutObject-Detailansicht).
    COALESCE(
        NULLIF(
            regexp_extract(
                step_elem::VARCHAR,
                '<_([0-9A-Fa-f-]+)',   -- Hex-Klasse case-tolerant wie die P2/P3-Anker ([0-9A-Fa-f-]{36})
                1
            ),
            ''
        ),
        'hash:' || xml_extract_text(step_elem, '//*/@hash')[1]
    ) as Step_UUID,
    xml_extract_text(step_elem, '//*/@hash')[1] as Step_Hash,
    ws_restore(xml_extract_text(step_elem, '//text()')[1]) as Step_Text,
    fn.File_Name as File_Name
FROM ddr_script_raw
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(step_elem, '//*/@datatype')[1] = 'StepText'
ON CONFLICT (Step_UUID, File_Name) DO UPDATE SET
    Step_Hash = EXCLUDED.Step_Hash,
    Step_Text = EXCLUDED.Step_Text;
