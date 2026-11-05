-- Hand-maintained COUNT wrapper embedding the findings core of rule (account_disabled).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'account-disabled' AS rule_id, 'info' AS severity,
    a.File_Name AS file_name, a.Account_UUID AS nav_uuid, a.Account_Name AS account_name, a.PrivilegeSet_Name AS privilege_set,
    row_number() OVER (ORDER BY a.File_Name, a.Account_Name) AS row_key
FROM AccountsCatalog a
WHERE a.Is_Enabled = 'False'
  AND (getvariable('file') IS NULL OR a.File_Name = getvariable('file'))
ORDER BY a.File_Name, a.Account_Name
) _summary;
