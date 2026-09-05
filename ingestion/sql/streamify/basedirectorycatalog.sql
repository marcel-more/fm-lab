-- streamify-Override für BaseDirectoryCatalog.
-- BaseDirectory trägt Identität in Attributen (@name/@id/@relativeTo) + UUID-Kind →
-- typisierte STRUCT[]-Capture (gepatchtes webbed) auf dem eindeutigen
-- BaseDirectoryCatalog-Anker. Keine Roh-Spalte → voll bit-identisch erwartet.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_dir AS (
    SELECT unnest(BaseDirectory) AS d
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='BaseDirectoryCatalog',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'BaseDirectory':'STRUCT("name" VARCHAR, "id" BIGINT, "relativeTo" VARCHAR, "UUID" STRUCT("#text" VARCHAR))[]'}
    )
    WHERE BaseDirectory IS NOT NULL
)
INSERT INTO BaseDirectoryCatalog
SELECT
    d.name as BD_Name,
    d.id::BIGINT as BD_ID,
    d.relativeTo as BD_RelativeTo,
    d.UUID."#text" as BD_UUID,
    fn.File_Name as File_Name
FROM raw_dir
CROSS JOIN filename_normalized fn
WHERE d.id IS NOT NULL
ON CONFLICT (BD_UUID, File_Name) DO UPDATE SET
    BD_Name = EXCLUDED.BD_Name,
    BD_ID = EXCLUDED.BD_ID,
    BD_RelativeTo = EXCLUDED.BD_RelativeTo;
