-- Distinct object types among the rule's findings — options dataset for the
-- object-type Select. Deliberately independent of the suffix-class chip and of
-- the object_type filter itself so the option list stays stable while
-- filtering; respects the file/scope filters.
WITH named AS (
    SELECT Object_UUID, Object_Type, Object_Name, File_Name
    FROM ObjectCatalog
    WHERE Object_Type IN ('Script', 'Field', 'Layout', 'CustomFunction', 'TableOccurrence',
                          'BaseTable', 'ValueList', 'CustomMenu', 'CustomMenuSet',
                          'ExternalDataSource', 'Account', 'PrivilegeSet', 'Folder')
      AND Object_Name IS NOT NULL
      AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
)
SELECT DISTINCT Object_Type AS value, Object_Type AS label
FROM named
WHERE Object_Name LIKE '% Copy' OR Object_Name LIKE '% copy' OR Object_Name LIKE '% Kopie'
   OR regexp_matches(Object_Name, ' [0-9]{1,4}$')
ORDER BY value;
