-- Always exactly one row. Drives visibleWhen guards for the file view:
--   not_found         → true when the file name is not in FilesCatalog
--   has_triggers      → file has ≥1 file-level ScriptTrigger
--   has_start_layout  → "switch to layout" is configured
--   has_account       → auto-login account is configured
--   has_change_meta   → the file's objects carry change stamps (catalog schema 1.35.0+)
SELECT
    (SELECT COUNT(*) FROM FilesCatalog WHERE File_Name = :file) = 0 AS not_found,
    (SELECT COUNT(*) FROM ScriptTriggers
       WHERE File_Name = :file AND Owner_Type = 'File') > 0 AS has_triggers,
    (SELECT COUNT(*) FROM FileOptionsCatalog
       WHERE File_Name = :file AND Default_Layout_UUID IS NOT NULL) > 0 AS has_start_layout,
    (SELECT COUNT(*) FROM FileOptionsCatalog
       WHERE File_Name = :file
         AND Login_Type = '1' AND Login_AccountName IS NOT NULL) > 0 AS has_account,
    (SELECT COUNT(*) FROM ObjectChangeMeta WHERE File_Name = :file) > 0 AS has_change_meta;
