-- Hand-maintained COUNT wrapper embedding the findings core of rule (empty_layout).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'empty-layout' AS rule_id, 'info' AS severity,
    l.File_Name AS file_name, l.L_UUID AS nav_uuid, l.L_Name AS layout_name,
    'Layout has no objects' AS message,
    row_number() OVER (ORDER BY l.File_Name, l.L_Name) AS row_key
FROM Layouts l
WHERE NOT EXISTS (SELECT 1 FROM LayoutObjects o WHERE o.Layout_ID = l.L_ID AND o.File_Name = l.File_Name)
  -- Only real layouts: folders (Folder_Type='True') and separators
  -- (Folder_Type='Marker' or Is_Separator) are not real layouts.
  AND (l.Folder_Type IS NULL OR l.Folder_Type = 'False') AND NOT l.Is_Separator
  AND (getvariable('file') IS NULL OR l.File_Name = getvariable('file'))
ORDER BY l.File_Name, l.L_Name
) _summary;
