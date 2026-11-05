-- Auto-login account ("log in using — account name"), 0 or 1 row.
-- Shown whenever an auto-login account is configured (Login_Type='1'), even when
-- the referenced account cannot be resolved to an object (target_uuid NULL → the
-- row simply is not navigable). LEFT JOIN via the auto_login_account graph link.
SELECT
    o.Login_AccountName AS target_name,
    ol.Target_UUID      AS target_uuid,
    o.File_Name
FROM FileOptionsCatalog o
LEFT JOIN ObjectLinks ol
  ON ol.Link_Role = 'auto_login_account' AND ol.Source_File = o.File_Name
WHERE o.File_Name = :file
  AND o.Login_Type = '1'
  AND o.Login_AccountName IS NOT NULL;
