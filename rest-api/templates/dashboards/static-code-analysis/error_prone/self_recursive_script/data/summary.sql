-- Hand-maintained COUNT wrapper embedding the findings core of rule (self_recursive_script).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'self-recursive-script' AS rule_id, 'info' AS severity,
    oc.File_Name AS file_name, oc.Object_UUID AS nav_uuid, oc.Object_Name AS script_name,
    'Script calls itself (recursion)' AS message,
    row_number() OVER (ORDER BY oc.File_Name, oc.Object_Name) AS row_key
FROM ObjectLinks ol
JOIN ObjectCatalog oc ON oc.Object_UUID = ol.Source_UUID AND oc.File_Name = ol.Source_File AND oc.Object_Type = 'Script'
WHERE ol.Link_Role = 'calls_script' AND ol.Source_UUID = ol.Target_UUID AND ol.Source_File IS NOT DISTINCT FROM ol.Target_File AND (getvariable('file') IS NULL OR oc.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR oc.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
GROUP BY oc.File_Name, oc.Object_UUID, oc.Object_Name
ORDER BY oc.File_Name, oc.Object_Name
) _summary;
