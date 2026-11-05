-- Hand-maintained wrapper around the rule core (name_trailing_whitespace).
-- The defect chips must show their true totals, so the defect filter is NOT
-- applied here.
WITH named AS (
    SELECT Object_UUID, Object_Type, Object_Name, File_Name
    FROM ObjectCatalog
    WHERE Object_Type IN ('Script', 'Field', 'Layout', 'CustomFunction', 'TableOccurrence',
                          'BaseTable', 'ValueList', 'CustomMenu', 'CustomMenuSet',
                          'ExternalDataSource', 'Account', 'PrivilegeSet', 'Folder')
      AND Object_Name IS NOT NULL AND trim(Object_Name) <> ''
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE regexp_matches(Object_Name, '[ \t]$')
                          AND NOT regexp_matches(Object_Name, '^[ \t]')) AS trailing_count,
       COUNT(*) FILTER (WHERE regexp_matches(Object_Name, '^[ \t]')
                          AND NOT regexp_matches(Object_Name, '[ \t]$')) AS leading_count,
       COUNT(*) FILTER (WHERE regexp_matches(Object_Name, '^[ \t]')
                         AND regexp_matches(Object_Name, '[ \t]$')) AS both_count,
       COUNT(DISTINCT File_Name) AS affected_files
FROM named
WHERE Object_Name <> trim(Object_Name)
  AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
