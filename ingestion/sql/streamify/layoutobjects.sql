-- streamify-Override für LayoutObjects.
-- Ersetzt den read_xml_objects-DOM-Read (ganzes Dokument) durch per-Record-SAX-
-- Streaming auf dem vom Renamer eindeutig gemachten Anker LC_Layout. Nur die ersten
-- CTEs (raw_layouts/layouts_resolved/layout_parts) ändern sich; die rekursive
-- Objekt-Extraktion + INSERT bleiben identisch zur Basis. Ergebnis ist bit-identisch
-- zur DOM-Basis BIS AUF die Roh-Spalte Object_XML (SAX-Serialisierung, semantisch
-- äquivalent — Downstream-Invarianz bewiesen).
WITH RECURSIVE filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
-- STREAMING: ein Record je LC_Layout; PartsList-Subtree als VARCHAR (Klasse-C).
layouts_resolved AS (
    SELECT
        "id"::BIGINT as Layout_ID,
        '<PartsList>' || PartsList || '</PartsList>' as parts_wrapped
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='LC_Layout',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'id':'BIGINT','PartsList':'VARCHAR'}
    )
    WHERE PartsList IS NOT NULL
),
layout_parts AS (
    SELECT
        Layout_ID,
        unnest(xml_extract_elements(parts_wrapped, '/PartsList/Part')) as part_xml
    FROM layouts_resolved
),
parts_resolved AS (
    SELECT
        Layout_ID,
        xml_extract_text(part_xml, '/Part/@type')[1] as Part_Type,
        part_xml
    FROM layout_parts
),
root_objects AS (
    SELECT
        Layout_ID,
        Part_Type,
        xml_extract_text(object_xml, '/LayoutObject/@id')[1]::BIGINT as Object_ID,
        fm_canon_layout_type(
            xml_extract_text(object_xml, '/LayoutObject/@type')[1],
            xml_extract_text(object_xml, '/LayoutObject/@kind')[1]::BIGINT,
            object_xml) as Object_Type,
        xml_unescape(xml_extract_text(object_xml, '/LayoutObject/@name')[1]) as Object_Name,
        xml_extract_text(object_xml, '/LayoutObject/@kind')[1]::BIGINT as Object_Kind,
        xml_extract_text(object_xml, '/LayoutObject/@hash')[1] as Object_Hash,
        xml_extract_text(object_xml, '/LayoutObject/UUID')[1] as Object_UUID,
        xml_extract_text(object_xml, '/LayoutObject/Bounds/@top')[1]::BIGINT as Bounds_Top,
        xml_extract_text(object_xml, '/LayoutObject/Bounds/@left')[1]::BIGINT as Bounds_Left,
        xml_extract_text(object_xml, '/LayoutObject/Bounds/@bottom')[1]::BIGINT as Bounds_Bottom,
        xml_extract_text(object_xml, '/LayoutObject/Bounds/@right')[1]::BIGINT as Bounds_Right,
        NULL::BIGINT as Parent_Object_ID,
        0 as Nesting_Level,
        t.z_order::BIGINT as Z_Order,
        xml_extract_text(object_xml, '/LayoutObject/Conditions/Hide/Calculation/Text')[1] as Hide_Calculation_Text,
        xml_extract_text(object_xml, '/LayoutObject/Tooltip/Calculation/Text')[1] as Tooltip_Calculation_Text,
        COALESCE(
            xml_extract_text(object_xml, '/LayoutObject/Button/Label/Calculation/Text')[1],
            xml_extract_text(object_xml, '/LayoutObject/GroupedButton/Label/Calculation/Text')[1],
            xml_extract_text(object_xml, '/LayoutObject/PopoverButton/Label/Calculation/Text')[1]
        ) as Label_Calculation_Text,
        array_to_string(
            xml_extract_text(object_xml, '/LayoutObject/ScriptTriggers/ScriptTrigger/ScriptReference/Calculation/Text'),
            E'\n'
        ) as ScriptTrigger_Parameter_Text,
        xml_extract_text(object_xml, '/LayoutObject/Text/StyledText/Data')[1] as Text_Content,
        object_xml
    FROM parts_resolved
    CROSS JOIN LATERAL unnest(
        xml_extract_elements(part_xml, '/Part/ObjectList/LayoutObject')
    ) WITH ORDINALITY AS t(object_xml, z_order)
),
nested_objects AS (
    SELECT
        Layout_ID, Part_Type, Object_ID, Object_Type, Object_Name, Object_Kind,
        Object_Hash, Object_UUID, Bounds_Top, Bounds_Left, Bounds_Bottom, Bounds_Right,
        Parent_Object_ID, Nesting_Level, Z_Order,
        Hide_Calculation_Text, Tooltip_Calculation_Text, Label_Calculation_Text,
        ScriptTrigger_Parameter_Text, Text_Content, object_xml
    FROM root_objects

    UNION ALL

    SELECT
        parent.Layout_ID,
        parent.Part_Type,
        xml_extract_text(child_xml, '/LayoutObject/@id')[1]::BIGINT as Object_ID,
        fm_canon_layout_type(
            xml_extract_text(child_xml, '/LayoutObject/@type')[1],
            xml_extract_text(child_xml, '/LayoutObject/@kind')[1]::BIGINT,
            child_xml) as Object_Type,
        xml_unescape(xml_extract_text(child_xml, '/LayoutObject/@name')[1]) as Object_Name,
        xml_extract_text(child_xml, '/LayoutObject/@kind')[1]::BIGINT as Object_Kind,
        xml_extract_text(child_xml, '/LayoutObject/@hash')[1] as Object_Hash,
        xml_extract_text(child_xml, '/LayoutObject/UUID')[1] as Object_UUID,
        xml_extract_text(child_xml, '/LayoutObject/Bounds/@top')[1]::BIGINT as Bounds_Top,
        xml_extract_text(child_xml, '/LayoutObject/Bounds/@left')[1]::BIGINT as Bounds_Left,
        xml_extract_text(child_xml, '/LayoutObject/Bounds/@bottom')[1]::BIGINT as Bounds_Bottom,
        xml_extract_text(child_xml, '/LayoutObject/Bounds/@right')[1]::BIGINT as Bounds_Right,
        parent.Object_ID as Parent_Object_ID,
        parent.Nesting_Level + 1 as Nesting_Level,
        t.z_order::BIGINT as Z_Order,
        xml_extract_text(child_xml, '/LayoutObject/Conditions/Hide/Calculation/Text')[1] as Hide_Calculation_Text,
        xml_extract_text(child_xml, '/LayoutObject/Tooltip/Calculation/Text')[1] as Tooltip_Calculation_Text,
        COALESCE(
            xml_extract_text(child_xml, '/LayoutObject/Button/Label/Calculation/Text')[1],
            xml_extract_text(child_xml, '/LayoutObject/GroupedButton/Label/Calculation/Text')[1],
            xml_extract_text(child_xml, '/LayoutObject/PopoverButton/Label/Calculation/Text')[1]
        ) as Label_Calculation_Text,
        array_to_string(
            xml_extract_text(child_xml, '/LayoutObject/ScriptTriggers/ScriptTrigger/ScriptReference/Calculation/Text'),
            E'\n'
        ) as ScriptTrigger_Parameter_Text,
        COALESCE(
            xml_extract_text(child_xml, '/LayoutObject/Text/StyledText/Data')[1],
            xml_extract_text(child_xml, '/LayoutObject/Title/Text')[1]
        ) as Text_Content,
        child_xml as object_xml
    FROM nested_objects parent
    CROSS JOIN LATERAL unnest(
        -- DIREKTE Kind-Achsen — identisch zur DOM-Basis (Begründung dort).
        CASE
            WHEN parent.Object_Type = 'Popover Button'
                THEN xml_extract_elements(parent.object_xml, '/LayoutObject/PopoverButton/LayoutObject')
            WHEN parent.Object_Type = 'PopoverPanel'
                THEN xml_extract_elements(parent.object_xml, '/LayoutObject/ObjectList/LayoutObject')
            ELSE xml_extract_elements(parent.object_xml, '/LayoutObject/*/ObjectList/LayoutObject')
        END
    ) WITH ORDINALITY AS t(child_xml, z_order)
    WHERE parent.Object_Type IN (
        'Portal','Group','Tab Control','Panel','Container','Button Bar',
        'Slide Control','Grouped Button','PopoverPanel','Popover Button'
    )
)
INSERT INTO LayoutObjects
SELECT
    Layout_ID,
    Part_Type,
    Object_ID,
    Object_Type,
    Object_Name,
    Object_Kind,
    Object_Hash,
    -- NULL-PK-Guard — identisch zur DOM-Basis (Begründung dort).
    -- UUID-Healing (H2): fm_heal_pick um den Guard herum — identisch zur DOM-Basis:
    -- bei NULL-UUID ist _is_survivor TRUE (Guard-md5 ist bereits zeilen-eindeutig
    -- und wird NIE geheilt); Copy-Paste-Zwillinge (gleiche UUID, verschiedene
    -- (Layout_ID, Object_ID)) erhalten die deterministische Ersatz-UUID.
    -- Identität = (Layout_ID, Object_ID) — die S0-3-Zähl-Identität des Zensus.
    fm_heal_pick(_is_survivor, 'LayoutObjects', fn.File_Name,
        COALESCE(Object_UUID, md5(
            'LayoutObjectNoUUID|' ||
            COALESCE(Layout_ID::VARCHAR, '') || '|' ||
            COALESCE(Object_ID::VARCHAR, '') || '|' ||
            COALESCE(Object_Type, '') || '|' ||
            COALESCE(Part_Type, '') || '|' ||
            COALESCE(Nesting_Level::VARCHAR, '') || '|' ||
            COALESCE(Z_Order::VARCHAR, '')
        )),
        'layout_id=' || COALESCE(Layout_ID::VARCHAR, '') ||
        '·object_id=' || COALESCE(Object_ID::VARCHAR, '')) as Object_UUID,
    Bounds_Top,
    Bounds_Left,
    Bounds_Bottom,
    Bounds_Right,
    Parent_Object_ID,
    Nesting_Level,
    Z_Order,
    ws_restore(Hide_Calculation_Text) as Hide_Calculation_Text,
    ws_restore(Tooltip_Calculation_Text) as Tooltip_Calculation_Text,
    ws_restore(Label_Calculation_Text) as Label_Calculation_Text,
    ws_restore(ScriptTrigger_Parameter_Text) as ScriptTrigger_Parameter_Text,
    ws_restore(Text_Content) as Text_Content,
    ws_restore(object_xml::VARCHAR) as Object_XML,
    fn.File_Name as File_Name
-- DETERMINISTISCHES DEDUP (Chunk-Invarianz) — identisch zur DOM-Basis:
-- mit den direkten Kind-Achsen bleibt nur die bekannte Doppel-Serialisierung
-- (Part-Root + GroupedButton-ObjectList, 12 Korpus-Fälle); pro Identität
-- gewinnt die flachste Emission (min Nesting_Level). NULL-UUID-Objekte bleiben erhalten.
-- UUID-Healing (H2): Partition um Object_ID ERWEITERT — (Layout_ID, Object_UUID,
-- Object_ID) ist exakt der Doppel-Serialisierungs-Schlüssel (S0-3): die 12 Korpus-
-- Fälle (gleiche Object_ID) kollabieren weiterhin, echte Copy-Paste-Zwillinge
-- (gleiche UUID, VERSCHIEDENE Object_ID) überleben jetzt bis zur Heilung statt
-- vor dem Upsert verworfen zu werden. _is_survivor über die Roh-Emissionen ist
-- äquivalent zur Sicht nach dem Dedup (identische Identität → identisches MIN).
FROM (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY Layout_ID, Object_UUID, Object_ID
                           ORDER BY Nesting_Level ASC, Parent_Object_ID NULLS FIRST, Z_Order DESC) AS _dedup_rn,
        (Object_UUID IS NULL OR Layout_ID IS NULL OR Object_ID IS NULL  -- kein Diskriminator → nie heilen
         OR (Layout_ID, Object_ID) =
            MIN((Layout_ID, Object_ID)) OVER (PARTITION BY Object_UUID)) AS _is_survivor
    FROM nested_objects
) nested_objects
CROSS JOIN filename_normalized fn
WHERE Object_UUID IS NULL OR _dedup_rn = 1
ON CONFLICT (Object_UUID, File_Name) DO UPDATE SET
    Layout_ID = EXCLUDED.Layout_ID,
    Part_Type = EXCLUDED.Part_Type,
    Object_ID = EXCLUDED.Object_ID,
    Object_Type = EXCLUDED.Object_Type,
    Object_Name = EXCLUDED.Object_Name,
    Object_Kind = EXCLUDED.Object_Kind,
    Object_Hash = EXCLUDED.Object_Hash,
    Bounds_Top = EXCLUDED.Bounds_Top,
    Bounds_Left = EXCLUDED.Bounds_Left,
    Bounds_Bottom = EXCLUDED.Bounds_Bottom,
    Bounds_Right = EXCLUDED.Bounds_Right,
    Parent_Object_ID = EXCLUDED.Parent_Object_ID,
    Nesting_Level = EXCLUDED.Nesting_Level,
    Z_Order = EXCLUDED.Z_Order,
    Hide_Calculation_Text = EXCLUDED.Hide_Calculation_Text,
    Tooltip_Calculation_Text = EXCLUDED.Tooltip_Calculation_Text,
    Label_Calculation_Text = EXCLUDED.Label_Calculation_Text,
    ScriptTrigger_Parameter_Text = EXCLUDED.ScriptTrigger_Parameter_Text,
    Text_Content = EXCLUDED.Text_Content,
    Object_XML = EXCLUDED.Object_XML;

-- Zensus (Dup-Absorption): Emissionsmenge des LayoutObjects-INSERTs — SAX-Fassung,
-- quellgleich zur TEMP-Stage im DOM-Block der Basis (dort begründet, inkl.
-- S0-3-Zähl-Semantik je (Layout_ID, Object_UUID, Object_ID) und Detail-Erfassung).
-- Schlanke Zweit-Rekursion über den LC_Layout-Stream (gleiche Kind-Achsen/Container-
-- Typen wie oben), nur Layout/ID/Typ/Name/UUID; NULL-UUID-Objekte einzeln
-- (md5-Fallback-PK).
CREATE OR REPLACE TEMP TABLE _lo_census AS
WITH RECURSIVE census_parts AS (
    SELECT
        Layout_ID,
        Layout_Name,
        unnest(xml_extract_elements(parts_wrapped, '/PartsList/Part')) as part_xml
    FROM (
        SELECT
            "id"::BIGINT as Layout_ID,
            xml_unescape("name") as Layout_Name,
            '<PartsList>' || PartsList || '</PartsList>' as parts_wrapped
        FROM read_xml(
            getvariable('fm_xml'),
            record_element='LC_Layout',
            maximum_file_size=getvariable('dom_threshold'),
            streaming=getvariable('use_streaming'),
            columns={'id':'BIGINT','name':'VARCHAR','PartsList':'VARCHAR'}
        )
        WHERE PartsList IS NOT NULL
    )
),
census_objects AS (
    SELECT
        Layout_ID,
        Layout_Name,
        xml_extract_text(object_xml, '/LayoutObject/@id')[1]::BIGINT as Object_ID,
        fm_canon_layout_type(
            xml_extract_text(object_xml, '/LayoutObject/@type')[1],
            xml_extract_text(object_xml, '/LayoutObject/@kind')[1]::BIGINT,
            object_xml) as Object_Type,
        xml_unescape(xml_extract_text(object_xml, '/LayoutObject/@name')[1]) as Object_Name,
        xml_extract_text(object_xml, '/LayoutObject/UUID')[1] as Object_UUID,
        object_xml
    FROM census_parts
    CROSS JOIN LATERAL unnest(
        xml_extract_elements(part_xml, '/Part/ObjectList/LayoutObject')
    ) AS t(object_xml)

    UNION ALL

    SELECT
        parent.Layout_ID,
        parent.Layout_Name,
        xml_extract_text(child_xml, '/LayoutObject/@id')[1]::BIGINT as Object_ID,
        fm_canon_layout_type(
            xml_extract_text(child_xml, '/LayoutObject/@type')[1],
            xml_extract_text(child_xml, '/LayoutObject/@kind')[1]::BIGINT,
            child_xml) as Object_Type,
        xml_unescape(xml_extract_text(child_xml, '/LayoutObject/@name')[1]) as Object_Name,
        xml_extract_text(child_xml, '/LayoutObject/UUID')[1] as Object_UUID,
        child_xml as object_xml
    FROM census_objects parent
    CROSS JOIN LATERAL unnest(
        CASE
            WHEN parent.Object_Type = 'Popover Button'
                THEN xml_extract_elements(parent.object_xml, '/LayoutObject/PopoverButton/LayoutObject')
            WHEN parent.Object_Type = 'PopoverPanel'
                THEN xml_extract_elements(parent.object_xml, '/LayoutObject/ObjectList/LayoutObject')
            ELSE xml_extract_elements(parent.object_xml, '/LayoutObject/*/ObjectList/LayoutObject')
        END
    ) AS t(child_xml)
    WHERE parent.Object_Type IN (
        'Portal',
        'Group',
        'Tab Control',
        'Panel',
        'Container',
        'Button Bar',
        'Slide Control',
        'Grouped Button',
        'PopoverPanel',
        'Popover Button'
    )
)
SELECT Layout_ID, Layout_Name, Object_ID, Object_Type, Object_Name, Object_UUID
FROM census_objects;

INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'LayoutObjects', 'Object_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT,
       COUNT(*) FILTER (WHERE Object_UUID IS NULL)
         + COUNT(DISTINCT (Layout_ID, Object_UUID, Object_ID)) FILTER (WHERE Object_UUID IS NOT NULL)
FROM _lo_census
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (LayoutObjects, 1.17.0) — identisch zur DOM-Basis:
-- Gruppierung auf (Layout_ID, Object_ID) kollabiert FileMakers Doppel-
-- Serialisierung; >1 verbleibende Vorkommen je UUID = echte Kollision.
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'LayoutObjects'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH occ AS (
    SELECT
        Object_UUID,
        Layout_ID,
        any_value(Layout_Name) AS Layout_Name,
        Object_ID,
        any_value(Object_Type) AS Object_Type,
        any_value(Object_Name) AS Object_Name
    FROM _lo_census
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID, Layout_ID, Object_ID
),
dups AS (
    SELECT Object_UUID FROM occ
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H2): Survivor-/Heal-Markierung analog Katalog-INSERT (Identität =
-- (Layout_ID, Object_ID) — occ ist bereits je Identität dedupliziert, daher kein
-- occ_within_id nötig; Doppel-Serialisierung ist hier schon kollabiert). Chunk-
-- lokale Sicht: chunk-übergreifende Paare erfasst der catmerge-Nachschlag.
marked AS (
    SELECT o.*,
           (o.Layout_ID IS NULL OR o.Object_ID IS NULL
            OR (o.Layout_ID, o.Object_ID) =
               MIN((o.Layout_ID, o.Object_ID)) OVER (PARTITION BY o.Object_UUID)) AS is_min_id
    FROM occ o
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'LayoutObjects' AS Catalog,
    o.Object_UUID,
    o.Object_Name,
    o.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY o.Object_UUID ORDER BY o.Layout_ID, o.Object_ID) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    o.Layout_Name AS Parent_Name,
    'Layout ' || COALESCE(o.Layout_ID::VARCHAR, '?') || ' · object id ' || COALESCE(o.Object_ID::VARCHAR, '?') AS Position,
    left(o.Object_Type || COALESCE(' "' || NULLIF(o.Object_Name, '') || '"', ''), 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT o.is_min_id
         THEN fm_heal_uuid('LayoutObjects', getvariable('fm_file'), o.Object_UUID,
                           'layout_id=' || COALESCE(o.Layout_ID::VARCHAR, '') ||
                           '·object_id=' || COALESCE(o.Object_ID::VARCHAR, '')) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN o.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'layout_id=' || COALESCE(o.Layout_ID::VARCHAR, '') ||
    '·object_id=' || COALESCE(o.Object_ID::VARCHAR, '') AS Discriminator
FROM marked o
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;

DROP TABLE IF EXISTS _lo_census;
