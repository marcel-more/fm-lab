-- Hand-maintained COUNT wrapper embedding the findings core of rule (unused_external_data_source).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT
    'unused-external-data-source'   AS rule_id,
    'info' AS severity,
    oc.File_Name  AS file_name,
    oc.Object_UUID AS nav_uuid,
    oc.Object_Name AS object_name,
    'Unused External Data Source'    AS message,
    row_number() OVER (ORDER BY oc.File_Name, oc.Object_Name) AS row_key
FROM v_object_usage oc
WHERE oc.Object_Type = 'ExternalDataSource'
  AND oc.Usage_Class = 'unused'
  AND (getvariable('file') IS NULL OR oc.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR oc.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY oc.File_Name, oc.Object_Name
) _summary;
