-- Hand-maintained wrapper around the rule core (field_index_minimal_locked).
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT f.Table_Name || '|' || f.File_Name) AS affected_tables,
       COUNT(DISTINCT f.File_Name) AS affected_files
FROM FieldsForTables f
WHERE f.Storage_Index = 'Minimal' AND f.Storage_AutoIndex
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR f.Field_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
