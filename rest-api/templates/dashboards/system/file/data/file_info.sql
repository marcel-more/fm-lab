-- One wide row (empty when the file does not exist). Feeds the hero "Dateiinfo":
--   metrics (object/link counts, FM version, DDR, last import) +
--   the File-Options settings as display tokens. Booleans are emitted as the
--   canonical badge tokens 'yes'/'no'/'on'/'off'/'none' → localised in the UI via
--   dashboard:cellValues (raw values, front-end i18n — no German baked into SQL).
WITH o AS (SELECT * FROM FileOptionsCatalog WHERE File_Name = :file)
SELECT
    f.File_Name,
    f.FileMaker_Version AS fm_version,
    CASE WHEN f.Has_DDR_INFO THEN 'yes' ELSE 'no' END AS has_ddr,
    f.Import_Timestamp AS import_ts,
    (SELECT COUNT(*) FROM ObjectCatalog WHERE File_Name = :file) AS total_objects,
    (SELECT COUNT(*) FROM ObjectLinks   WHERE Source_File = :file) AS total_links,
    -- File-Options settings (display tokens)
    o.Min_Version AS min_version,
    CASE WHEN o.Login_Type = '1' THEN COALESCE(o.Login_AccountName, 'on') ELSE 'off' END AS auto_login,
    CASE WHEN COALESCE(o.Save_Password_Keychain, FALSE) THEN 'yes' ELSE 'no' END AS save_credentials,
    CASE WHEN COALESCE(o.Show_SignIn_Fields, FALSE)     THEN 'yes' ELSE 'no' END AS show_signin,
    CASE WHEN o.Encryption_Type = '0' OR o.Encryption_Type IS NULL
         THEN 'none' ELSE o.Encryption_Type END AS encryption,
    CASE WHEN COALESCE(o.Hide_WebDirect_Sharing, FALSE) THEN 'yes' ELSE 'no' END AS hide_webdirect,
    CASE WHEN COALESCE(o.Hide_Client_Sharing, FALSE)    THEN 'yes' ELSE 'no' END AS hide_client,
    CASE WHEN COALESCE(o.Spelling_Underline, FALSE)     THEN 'yes' ELSE 'no' END AS spelling,
    COALESCE(o.Default_Layout_Name, '—') AS start_layout_name
FROM FilesCatalog f
LEFT JOIN o ON o.File_Name = f.File_Name
WHERE f.File_Name = :file;
