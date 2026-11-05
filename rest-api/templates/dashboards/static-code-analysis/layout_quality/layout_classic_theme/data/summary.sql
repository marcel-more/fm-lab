-- Hand-maintained wrapper around the rule core (layout_classic_theme).
-- Detection predicate kept byte-identical to findings.sql (raw-column OR chain —
-- see the reasoning there); any change must be applied to both.
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT ly.File_Name) AS affected_files
FROM Layouts ly
WHERE (ly.Folder_Type IS NULL OR ly.Folder_Type = 'False')
  AND NOT COALESCE(ly.Is_Separator, FALSE)
  AND (ly.L_Theme_Base = 'com.filemaker.theme.classic'
       OR ly.L_Theme_Name = 'com.filemaker.theme.classic'
       OR ly.L_Theme_ID IS NULL)
  AND (getvariable('file') IS NULL OR ly.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
