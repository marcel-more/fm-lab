-- KPI-Hülle über den findings-core (ohne LIMIT): Treffer + betroffene Dateien.
SELECT
    COUNT(*)                    AS finding_count,
    'warning'                   AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
    WITH pw AS (
        SELECT f.Field_UUID, f.File_Name, f.Table_Name, f.Field_Name
        FROM FieldsForTables f
        WHERE regexp_matches(LOWER(f.Field_Name), '(password|passwort|kennwort|\bpin\b)')
          AND f.Field_Type = 'Normal' AND COALESCE(f.Is_Global, '') <> 'True'
    )
    SELECT lo.File_Name AS file_name
    FROM ObjectLinks ol
    JOIN pw ON pw.Field_UUID = ol.Target_UUID AND pw.File_Name IS NOT DISTINCT FROM ol.Target_File
    JOIN LayoutObjects lo ON lo.Object_UUID = ol.Source_UUID AND lo.File_Name = ol.Source_File
    JOIN Layouts l ON l.L_ID = lo.Layout_ID AND l.File_Name = lo.File_Name
    WHERE ol.Link_Role = 'displays_field'
      AND ol.Source_Type = 'LayoutObject'
      AND lo.Object_XML NOT LIKE '%<Display Style="7"%'
      AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
) _summary;
