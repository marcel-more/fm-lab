-- streamify-Override für PasteIndexList.
-- Object ist attribut-only (<Object id=".."/>) → VARCHAR-Capture verlöre @id; daher
-- typisierte STRUCT[]-Capture (gepatchtes webbed, PR#98) direkt auf dem eindeutigen
-- PasteIndexList-Anker. Keine Roh-Spalte → voll bit-identisch erwartet.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
paste_objects AS (
    SELECT unnest(Object) AS obj
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='PasteIndexList',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'Object':'STRUCT(id BIGINT)[]'}
    )
    WHERE Object IS NOT NULL
)
INSERT INTO PasteIndexList
SELECT
    obj.id::BIGINT as Object_ID,
    ROW_NUMBER() OVER (ORDER BY obj.id::BIGINT) as List_Index,
    fn.File_Name as File_Name
FROM paste_objects
CROSS JOIN filename_normalized fn
WHERE obj.id IS NOT NULL
ON CONFLICT (Object_ID, File_Name) DO UPDATE SET
    List_Index = EXCLUDED.List_Index;
