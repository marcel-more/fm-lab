-- Hand-maintained COUNT wrapper embedding the findings core of rule (unused_privilege_set).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'unused-privilege-set' AS rule_id, 'info' AS severity,
    oc.File_Name AS file_name, oc.Object_UUID AS nav_uuid, oc.Object_Name AS object_name,
    'Privilege set is assigned to no account' AS message,
    row_number() OVER (ORDER BY oc.File_Name, oc.Object_Name) AS row_key
FROM ObjectCatalog oc
WHERE oc.Object_Type = 'PrivilegeSet'
  AND oc.Object_Name NOT IN ('[Full Access]', '[Data Entry Only]', '[Read-Only Access]')
  AND NOT EXISTS (SELECT 1 FROM ObjectLinks ol WHERE ol.Target_UUID = oc.Object_UUID AND ol.Link_Role = 'privilege_set')
  AND (getvariable('file') IS NULL OR oc.File_Name = getvariable('file'))
ORDER BY oc.File_Name, oc.Object_Name
) _summary;
