-- Hand-maintained wrapper around the rule core (layout_group_of_one).
WITH single_groups AS (
    SELECT g.File_Name, g.Layout_ID, g.Object_UUID
    FROM LayoutObjects g
    JOIN LayoutObjects c ON c.Parent_Object_ID = g.Object_ID
     AND c.Layout_ID = g.Layout_ID AND c.File_Name = g.File_Name
    WHERE g.Object_Type = 'Group'
    GROUP BY g.File_Name, g.Layout_ID, g.Object_UUID
    HAVING COUNT(*) = 1
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT g.File_Name) AS affected_files
FROM single_groups g
JOIN Layouts ly ON g.Layout_ID = ly.L_ID AND g.File_Name = ly.File_Name
WHERE (getvariable('file') IS NULL OR g.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
