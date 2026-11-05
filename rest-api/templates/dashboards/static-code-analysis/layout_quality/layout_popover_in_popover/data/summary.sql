-- Hand-maintained wrapper around the rule core (layout_popover_in_popover).
WITH RECURSIVE chain AS (
    SELECT File_Name, Layout_ID, Object_UUID, Parent_Object_ID
    FROM LayoutObjects
    WHERE Object_Type = 'Popover Button'
    UNION ALL
    SELECT c.File_Name, c.Layout_ID, c.Object_UUID, p.Parent_Object_ID
    FROM chain c
    JOIN LayoutObjects p ON c.Parent_Object_ID = p.Object_ID
     AND c.Layout_ID = p.Layout_ID AND c.File_Name = p.File_Name
),
nested AS (
    SELECT DISTINCT ch.File_Name, ch.Layout_ID, ch.Object_UUID
    FROM chain ch
    JOIN LayoutObjects anc ON ch.Parent_Object_ID = anc.Object_ID
     AND ch.Layout_ID = anc.Layout_ID AND ch.File_Name = anc.File_Name
    WHERE anc.Object_Type = 'PopoverPanel'
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT l.L_UUID) AS affected_layouts,
       COUNT(DISTINCT n.File_Name) AS affected_files
FROM nested n
JOIN Layouts l ON n.Layout_ID = l.L_ID AND n.File_Name = l.File_Name
WHERE (getvariable('file') IS NULL OR n.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
