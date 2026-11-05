-- Distinct object types among the rule's findings — options dataset for the
-- object-type Select. Deliberately independent of the defect and object_type
-- filters so the option list stays stable while filtering; respects the
-- file/scope filters and the max_len slider (it decides what is a finding at
-- all).
SELECT DISTINCT Object_Type AS value, Object_Type AS label
FROM ObjectCatalog
WHERE Object_Type IN ('Script', 'Field', 'Layout', 'CustomFunction', 'TableOccurrence',
                      'BaseTable', 'ValueList', 'CustomMenu', 'CustomMenuSet',
                      'ExternalDataSource', 'Account', 'PrivilegeSet', 'Folder')
  AND Object_Name IS NOT NULL
  AND length(Object_Name) > CAST(COALESCE(getvariable('max_len'), '80') AS INTEGER)
  AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY value;
