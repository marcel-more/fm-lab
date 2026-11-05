-- Hand-maintained COUNT wrapper embedding the findings core of rule (password_field_plaintext).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'warning'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'password-field-plaintext' AS rule_id, 'warning' AS severity,
    f.File_Name AS file_name, f.Table_Name AS table_name, f.Field_Name AS field_name,
    CASE WHEN COALESCE(fo.Encryption_Type, '0') = '0' THEN 'None' ELSE 'Enabled' END AS encryption_at_rest,
    f.Field_UUID AS nav_uuid,
    f.Table_Name || '::' || f.Field_Name AS qualified_name,
    row_number() OVER (ORDER BY f.File_Name, f.Table_Name, f.Field_Name) AS row_key
FROM FieldsForTables f
LEFT JOIN FileOptionsCatalog fo ON fo.File_Name = f.File_Name
WHERE regexp_matches(LOWER(f.Field_Name), '(password|passwort|kennwort|\bpin\b)')
  AND f.Field_Type = 'Normal' AND COALESCE(f.Is_Global, '') <> 'True'
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
ORDER BY f.File_Name, f.Table_Name, f.Field_Name
) _summary;
