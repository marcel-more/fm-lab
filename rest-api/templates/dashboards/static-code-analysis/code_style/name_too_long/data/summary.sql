-- Hand-maintained wrapper around the rule core (name_too_long).
-- The defect chips must show their true totals under the current threshold, so
-- the defect filter is NOT applied here. The object-type select DOES narrow the
-- counts (it is a scoping filter, not a class chip) — except the slider
-- maximum, which stays on the longest name in scope so the slider does not jump
-- when a type is selected.
WITH named AS (
    SELECT Object_UUID, Object_Type, Object_Name, File_Name, length(Object_Name) AS name_length
    FROM ObjectCatalog
    WHERE Object_Type IN ('Script', 'Field', 'Layout', 'CustomFunction', 'TableOccurrence',
                          'BaseTable', 'ValueList', 'CustomMenu', 'CustomMenuSet',
                          'ExternalDataSource', 'Account', 'PrivilegeSet', 'Folder')
      AND Object_Name IS NOT NULL
      AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
)
SELECT COUNT(*) FILTER (WHERE in_type AND name_length > CAST(COALESCE(getvariable('max_len'), '80') AS INTEGER)) AS finding_count,
       COUNT(*) FILTER (WHERE in_type AND name_length > CAST(COALESCE(getvariable('max_len'), '80') AS INTEGER)
                          AND name_length < 100) AS too_long_count,
       COUNT(*) FILTER (WHERE in_type AND name_length >= 100) AS at_limit_count,
       COUNT(DISTINCT File_Name) FILTER (WHERE in_type AND name_length > CAST(COALESCE(getvariable('max_len'), '80') AS INTEGER)) AS affected_files,
       COALESCE(MAX(name_length), 100) AS longest_name
FROM (SELECT *, (getvariable('object_type') IS NULL OR Object_Type = getvariable('object_type')) AS in_type FROM named) t;
