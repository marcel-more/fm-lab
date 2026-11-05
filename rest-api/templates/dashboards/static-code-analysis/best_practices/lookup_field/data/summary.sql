-- Hand-maintained COUNT wrapper embedding the findings core of rule (lookup_field).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'lookup-field' AS rule_id, 'info' AS severity,
    f.File_Name AS file_name, f.Field_UUID AS nav_uuid, f.Table_Name AS table_name, f.Field_Name AS field_name,
    COALESCE(f.Lookup_TO_Name, '') || '::' || COALESCE(f.Lookup_Field_Name, '') AS source,
    row_number() OVER (ORDER BY f.File_Name, f.Table_Name, f.Field_Name) AS row_key
FROM FieldsForTables f
WHERE f.AutoEnter_Type = 'Looked_up'
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
ORDER BY f.File_Name, f.Table_Name, f.Field_Name
) _summary;
