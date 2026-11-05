-- Hand-maintained wrapper around the rule core (layout_repetition_out_of_range).
WITH leaf AS (
    SELECT lo.*
    FROM LayoutObjects lo
    WHERE lo.Object_XML LIKE '%<FieldReference%'
      AND NOT EXISTS (SELECT 1 FROM LayoutObjects k
                      WHERE k.Parent_Object_ID = lo.Object_ID
                        AND k.Layout_ID = lo.Layout_ID
                        AND k.File_Name = lo.File_Name)
),
shown AS (
    SELECT l.File_Name, l.Layout_ID, l.Object_UUID,
           TRY_CAST(regexp_extract(l.Object_XML, '<FieldReference[^>]*repetition="(\d+)"', 1) AS INTEGER) AS repetition,
           ol.Target_UUID AS field_uuid
    FROM leaf l
    JOIN ObjectLinks ol ON ol.Source_UUID = l.Object_UUID AND ol.Link_Role = 'displays_field'
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT s.File_Name) AS affected_files
FROM shown s
JOIN FieldsForTables f ON s.field_uuid = f.Field_UUID
JOIN Layouts ly ON s.Layout_ID = ly.L_ID AND s.File_Name = ly.File_Name
WHERE s.repetition IS NOT NULL
  AND f.Max_Repetitions IS NOT NULL
  AND s.repetition > f.Max_Repetitions
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
