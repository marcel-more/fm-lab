-- streamify-Override für LayoutParts.
-- read_xml_objects(ganzes Dokument) → per-Record-SAX-Streaming auf LC_Layout;
-- PartsList-Subtree als VARCHAR (Klasse-C) → Parts re-extrahiert. LayoutParts speichert
-- KEINE Roh-XML-Spalte → voll bit-identisch zur DOM-Basis erwartet. Part-Extraktion
-- + INSERT identisch zur Basis.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
layouts_resolved AS (
    SELECT
        "id"::BIGINT as Layout_ID,
        "name" as Layout_Name,
        '<PartsList>' || PartsList || '</PartsList>' as parts_wrapped
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='LC_Layout',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'id':'BIGINT','name':'VARCHAR','PartsList':'VARCHAR'}
    )
    WHERE "id" IS NOT NULL AND PartsList IS NOT NULL
),
layout_parts_list AS (
    SELECT
        Layout_ID,
        Layout_Name,
        xml_extract_elements(parts_wrapped, '/PartsList/Part') as parts
    FROM layouts_resolved
),
layout_parts AS (
    -- Zip-Unnest: unnest() und generate_subscripts() laufen positionsgleich →
    -- Part_Seq = Listenposition (XML-Reihenfolge, 1-basiert).
    SELECT
        Layout_ID,
        Layout_Name,
        unnest(parts) as part_xml,
        generate_subscripts(parts, 1) as Part_Seq
    FROM layout_parts_list
),
parts_extracted AS (
    SELECT
        Layout_ID,
        Layout_Name,
        Part_Seq,
        xml_extract_text(part_xml, '/Part/@type')[1] as Part_Type,
        xml_extract_text(part_xml, '/Part/@kind')[1]::BIGINT as Part_Kind,
        xml_extract_text(part_xml, '/Part/Definition/@type')[1] as Definition_Type,
        xml_extract_text(part_xml, '/Part/Definition/@kind')[1]::BIGINT as Definition_Kind,
        xml_extract_text(part_xml, '/Part/Definition/@size')[1]::BIGINT as Part_Size,
        xml_extract_text(part_xml, '/Part/Definition/@absolute')[1]::BIGINT as Part_Absolute,
        xml_extract_text(part_xml, '/Part/Definition/@Options')[1]::BIGINT as Part_Options,
        list_count(xml_extract_elements(part_xml, '/Part/ObjectList/LayoutObject')) as Object_Count,
        xml_extract_text(part_xml, '/Part/Definition/FieldReference/@id')[1]::BIGINT as Break_Field_ID,
        xml_unescape(xml_extract_text(part_xml, '/Part/Definition/FieldReference/@name')[1]) as Break_Field_Name,
        xml_extract_text(part_xml, '/Part/Definition/FieldReference/@UUID')[1] as Break_Field_UUID,
        xml_unescape(xml_extract_text(part_xml, '/Part/Definition/FieldReference/TableOccurrenceReference/@name')[1]) as Break_TO_Name,
        xml_extract_text(part_xml, '/Part/Definition/FieldReference/TableOccurrenceReference/@UUID')[1] as Break_TO_UUID
    FROM layout_parts
)
INSERT INTO LayoutParts
SELECT
    Layout_ID,
    Layout_Name,
    Part_Seq,
    Part_Type,
    Part_Kind,
    Definition_Type,
    Definition_Kind,
    Part_Size,
    Part_Absolute,
    Part_Options,
    Object_Count,
    -- Leere Platzhalter-Referenz (id=0, leerer Name — Body/Header/Footer tragen
    -- sie flächig) → NULL-Quintett; nur echte FieldReferences bleiben stehen.
    CASE WHEN Break_Field_ID != 0 THEN Break_Field_ID END as Break_Field_ID,
    CASE WHEN Break_Field_ID != 0 THEN Break_Field_Name END as Break_Field_Name,
    CASE WHEN Break_Field_ID != 0 THEN Break_Field_UUID END as Break_Field_UUID,
    CASE WHEN Break_Field_ID != 0 THEN Break_TO_Name END as Break_TO_Name,
    CASE WHEN Break_Field_ID != 0 THEN Break_TO_UUID END as Break_TO_UUID,
    fn.File_Name as File_Name
FROM parts_extracted
CROSS JOIN filename_normalized fn
ON CONFLICT (Layout_ID, Part_Seq, File_Name) DO UPDATE SET
    Layout_Name = EXCLUDED.Layout_Name,
    Part_Type = EXCLUDED.Part_Type,
    Part_Kind = EXCLUDED.Part_Kind,
    Definition_Type = EXCLUDED.Definition_Type,
    Definition_Kind = EXCLUDED.Definition_Kind,
    Part_Size = EXCLUDED.Part_Size,
    Part_Absolute = EXCLUDED.Part_Absolute,
    Part_Options = EXCLUDED.Part_Options,
    Object_Count = EXCLUDED.Object_Count,
    Break_Field_ID = EXCLUDED.Break_Field_ID,
    Break_Field_Name = EXCLUDED.Break_Field_Name,
    Break_Field_UUID = EXCLUDED.Break_Field_UUID,
    Break_TO_Name = EXCLUDED.Break_TO_Name,
    Break_TO_UUID = EXCLUDED.Break_TO_UUID;
