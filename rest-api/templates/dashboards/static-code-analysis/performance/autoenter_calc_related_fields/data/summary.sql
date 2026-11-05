-- Hand-maintained COUNT wrapper for rule (autoenter_calc_related_fields).
-- Keep filters (file filter + scope block) in sync with data/findings.sql.
SELECT
    COUNT(*) AS finding_count,
    'info' AS severity,
    COUNT(DISTINCT Table_Name || '|' || File_Name) AS affected_tables,
    COUNT(DISTINCT File_Name) AS affected_files
FROM FieldsForTables f
WHERE f.AE_Calc_Text LIKE '%::%'
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR f.Field_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
