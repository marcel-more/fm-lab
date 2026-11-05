-- Hand-maintained wrapper around the rule core (name_quoted).
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT Object_Type) AS affected_object_types,
       COUNT(DISTINCT File_Name) AS affected_files
FROM ObjectCatalog
WHERE Object_Type IN ('Script', 'Field', 'Layout', 'CustomFunction', 'TableOccurrence',
                      'BaseTable', 'ValueList', 'CustomMenu', 'CustomMenuSet',
                      'ExternalDataSource', 'Account', 'PrivilegeSet', 'Folder')
  AND Object_Name LIKE '"%"'
  AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
