-- streamify-Override für StepsForScripts.
-- read_xml_objects(ganzes Dokument) → per-Record-SAX-Streaming auf dem vom Renamer
-- eindeutig gemachten Anker SFS_Script. ScriptReference (nested-Attr-STRUCT, via
-- gepatchtem webbed) liefert Script_ID/Name/UUID; ObjectList-Subtree als VARCHAR
-- (Klasse-C) → Steps re-extrahiert. Step-Extraktion + INSERT identisch zur Basis.
-- Bit-identisch zur DOM-Basis bis auf die Roh-Spalten Step_XML/Parameters_XML
-- (SAX-Serialisierung, semantisch äquivalent — Downstream-Invarianz).
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
scripts_resolved AS (
    SELECT
        ScriptReference.id::BIGINT as Script_ID,
        ScriptReference.name as Script_Name,
        ScriptReference.UUID as Script_UUID,
        '<ObjectList>' || ObjectList || '</ObjectList>' as steps_wrapped
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='SFS_Script',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'ScriptReference': 'STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)',
            'ObjectList': 'VARCHAR'
        }
    )
    WHERE ObjectList IS NOT NULL
),
script_steps AS (
    SELECT
        Script_ID,
        Script_Name,
        Script_UUID,
        unnest(xml_extract_elements(steps_wrapped, '/ObjectList/Step')) as step_xml
    FROM scripts_resolved
),
-- UUID-Healing (H2): Step_UUID + Identitätsfelder EINMAL extrahieren (der finale
-- SELECT liest sie als Spalten — kein Doppel-Parse), dann Survivor-Window.
-- Steps haben im SaXML KEINE Instanz-ID (/Step/@id ist die Step-TYP-ID!) —
-- Identität ist (Script_ID, Step_Index); nur positions-stabil (dokumentierte
-- Einschränkung). Doppel-Serialisierung (gleiche UUID UND gleiche
-- Identität) kollabiert weiterhin: identischer Diskriminator → identische
-- Ersatz-UUID → ON CONFLICT greift wie bisher (3A-Weiche automatisch).
-- Intra-Chunk-Sicht: chunk-übergreifende Paare heilt der catmerge-Nachschlag.
-- Die XPaths auf step_xml sind identisch zur DOM-Basis (gleiches Step-Fragment;
-- nur die CTE-Quellen davor sind SAX-spezifisch).
steps_extracted AS (
    SELECT
        Script_ID, Script_Name, Script_UUID, step_xml,
        xml_extract_text(step_xml, '/Step/@index')[1]::BIGINT as Step_Index,
        xml_extract_text(step_xml, '/Step/@id')[1]::BIGINT as Step_ID,
        xml_extract_text(step_xml, '/Step/UUID')[1] as Step_UUID
    FROM script_steps
),
steps_healed AS (
    SELECT s.*,
           (s.Step_UUID IS NULL OR s.Script_ID IS NULL OR s.Step_Index IS NULL  -- kein Diskriminator → nie heilen
            OR (s.Script_ID, s.Step_Index) =
               MIN((s.Script_ID, s.Step_Index)) OVER (PARTITION BY s.Step_UUID)) AS is_survivor
    FROM steps_extracted s
)
-- Explizite Spaltenliste (18 P1-Spalten): P3 verbreitert die Tabelle um die
-- abgeleitete Spalte Inserted_Text (ALTER TABLE, details:~1037). Ein spaltenloser
-- INSERT bricht dann auf dem sequentiellen Incremental-Pfad (P1 direkt gegen die
-- bestehende Master-/Test-DB, JOBS=1) mit "excluded has 18 columns … 19 specified".
-- Der Parallel-Pfad (frische Teil-DBs + INSERT BY NAME) war nie betroffen.
INSERT INTO StepsForScripts (
    Script_ID, Script_Name, Script_UUID, Step_Index, Step_ID, Step_Name,
    Is_Enabled, Step_UUID, DDR_Hash, DDR_UUID, Parameters_XML, Step_XML,
    Parameter_Type, Variable_Name, Calculation_Text, Boolean_Type, Boolean_Value,
    File_Name)
SELECT
    Script_ID,
    Script_Name,
    Script_UUID,
    Step_Index,
    Step_ID,
    xml_extract_text(step_xml, '/Step/@name')[1] as Step_Name,
    xml_extract_text(step_xml, '/Step/@enable')[1] = 'True' as Is_Enabled,
    fm_heal_pick(is_survivor, 'StepsForScripts', fn.File_Name, Step_UUID,
                 'script_id=' || Script_ID::VARCHAR || '·step_index=' || Step_Index::VARCHAR) as Step_UUID,
    xml_extract_text(step_xml, '/Step/DDRREF[@kind="StepText"]/@hash')[1] as DDR_Hash,
    regexp_replace(
        xml_extract_text(step_xml, '/Step/DDRREF[@kind="StepText"]')[1],
        '^_',
        ''
    ) as DDR_UUID,
    ws_restore(xml_extract_elements(step_xml, '/Step/ParameterValues')[1]::VARCHAR) as Parameters_XML,
    ws_restore(step_xml::VARCHAR) as Step_XML,
    xml_extract_text(step_xml, '//Parameter/@type')[1] as Parameter_Type,
    xml_extract_text(step_xml, '//Parameter[@type="Variable"]/Name/@value')[1] as Variable_Name,
    -- not(ancestor::repetition): schließt eine BERECHNETE Repetition der Ziel-Feldreferenz
    -- aus, die sonst (in Dokument-Reihenfolge vorn) statt der eigentlichen Berechnung
    -- gegriffen würde. Muss mit der DOM-Fassung (convert_xml_01_extract.sql) identisch bleiben.
    -- not(ancestor::Bounds): analog Basis-Block — ohne Namens-Berechnung rückte sonst
    -- die erste Geometrie-Berechnung (<Bounds><height>…) als Calculation_Text nach.
    ws_restore(xml_extract_text(step_xml, '//Calculation[not(ancestor::repetition)][not(ancestor::Bounds)]/Text')[1]) as Calculation_Text,
    xml_extract_text(step_xml, '//Boolean/@type')[1] as Boolean_Type,
    xml_extract_text(step_xml, '//Boolean/@value')[1] as Boolean_Value,
    fn.File_Name as File_Name
FROM steps_healed
CROSS JOIN filename_normalized fn
ON CONFLICT (Step_UUID, File_Name) DO UPDATE SET
    Script_ID = EXCLUDED.Script_ID,
    Script_Name = EXCLUDED.Script_Name,
    Script_UUID = EXCLUDED.Script_UUID,
    Step_Index = EXCLUDED.Step_Index,
    Step_ID = EXCLUDED.Step_ID,
    Step_Name = EXCLUDED.Step_Name,
    Is_Enabled = EXCLUDED.Is_Enabled,
    DDR_Hash = EXCLUDED.DDR_Hash,
    DDR_UUID = EXCLUDED.DDR_UUID,
    Parameters_XML = EXCLUDED.Parameters_XML,
    Step_XML = EXCLUDED.Step_XML,
    Parameter_Type = EXCLUDED.Parameter_Type,
    Variable_Name = EXCLUDED.Variable_Name,
    Calculation_Text = EXCLUDED.Calculation_Text,
    Boolean_Type = EXCLUDED.Boolean_Type,
    Boolean_Value = EXCLUDED.Boolean_Value;

-- Zensus (Dup-Absorption): geparste Step-Records dieses Laufs/Chunks — SAX-Fassung,
-- quellgleich zum Zensus im DOM-Block der Basis (dort begründet): Script-Records
-- streamen, Steps nur ZÄHLEN (keine Spalten-Extrakte). Gleicher WHERE-Filter wie
-- der Katalog-INSERT oben (ObjectList IS NOT NULL; Scripts ohne Steps zählen 0).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'StepsForScripts', 'Step_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT,
       COALESCE(SUM(len(xml_extract_elements('<ObjectList>' || ObjectList || '</ObjectList>', '/ObjectList/Step'))), 0)
FROM read_xml(
    getvariable('fm_xml'),
    record_element='SFS_Script',
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'ObjectList': 'VARCHAR'}
)
WHERE ObjectList IS NOT NULL
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (StepsForScripts, 1.17.0) — SAX-Fassung, quellgleich zum
-- Detail-Block der DOM-Basis (dort begründet): dups zuerst (nur UUID-Extrakt pro
-- Step), die teuren Extrakte laufen NUR auf den Dup-Zeilen. Script_Name kommt hier
-- direkt aus dem ScriptReference-Struct (kein Re-Parse nötig).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'StepsForScripts'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH det_steps AS (
    SELECT
        Script_ID,
        Script_Name,
        unnest(xml_extract_elements('<ObjectList>' || ObjectList || '</ObjectList>', '/ObjectList/Step')) as step_xml
    FROM (
        SELECT
            ScriptReference.id::BIGINT as Script_ID,
            ScriptReference.name as Script_Name,
            ObjectList
        FROM read_xml(
            getvariable('fm_xml'),
            record_element='SFS_Script',
            maximum_file_size=getvariable('dom_threshold'),
            streaming=getvariable('use_streaming'),
            columns={
                'ScriptReference': 'STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)',
                'ObjectList': 'VARCHAR'
            }
        )
        WHERE ObjectList IS NOT NULL
    )
),
src AS (
    SELECT
        Script_ID,
        Script_Name,
        step_xml,
        xml_extract_text(step_xml, '/Step/UUID')[1] AS Object_UUID,
        xml_extract_text(step_xml, '/Step/@index')[1]::BIGINT AS Step_Index,
        ROW_NUMBER() OVER () AS xml_ord
    FROM det_steps
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H2): Survivor-/Heal-Markierung, identische Logik wie im Katalog-
-- INSERT oben (Identität = (Script_ID, Step_Index); Doppel-Serialisierung —
-- gleiche UUID+Identität — bleibt 'absorbed'). Chunk-lokale Sicht: chunk-
-- übergreifende Paare erfasst der catmerge-Nachschlag (Chunk_Seq = -1).
marked AS (
    SELECT s.*,
           (s.Script_ID IS NULL OR s.Step_Index IS NULL
            OR (s.Script_ID, s.Step_Index) =
               MIN((s.Script_ID, s.Step_Index)) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.Script_ID, s.Step_Index
                              ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'StepsForScripts' AS Catalog,
    s.Object_UUID,
    xml_extract_text(s.step_xml, '/Step/@name')[1] AS Object_Name,
    'ScriptStep' AS Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    xml_unescape(s.Script_Name) AS Parent_Name,
    -- @index ist 0-basiert; user-facing Step-Nummer = index + 1 (Konvention Step_Index).
    'Step ' || (s.Step_Index + 1)::VARCHAR AS Position,
    left(
        xml_extract_text(s.step_xml, '/Step/@name')[1]
        || COALESCE(' — ' || ws_restore(xml_extract_text(s.step_xml,
               '//Calculation[not(ancestor::repetition)][not(ancestor::Bounds)]/Text')[1]), ''),
        500) AS Display_Text,
    left(ws_restore(s.step_xml::VARCHAR), 4000) AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('StepsForScripts', getvariable('fm_file'), s.Object_UUID,
                           'script_id=' || s.Script_ID::VARCHAR || '·step_index=' || s.Step_Index::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'script_id=' || s.Script_ID::VARCHAR || '·step_index=' || s.Step_Index::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;
