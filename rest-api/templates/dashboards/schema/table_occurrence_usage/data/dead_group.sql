-- The other table occurrences of the selected TO's dead group (connected dead
-- subtree of the relationship graph) — they can be cleaned up together.
WITH sel AS (
    SELECT Dead_Group_ID, File_Name
    FROM v_table_occurrence_class
    WHERE TO_UUID = NULLIF(CAST(getvariable('to_uuid') AS VARCHAR), '')
      AND File_Name = NULLIF(CAST(getvariable('to_file') AS VARCHAR), '')
      AND Dead_Group_ID IS NOT NULL
)
SELECT c.TO_UUID AS nav_uuid, c.TO_Name AS to_name, c.BT_Name AS base_table,
       c.File_Name AS file_name, c.Relationship_Count AS relationships
FROM v_table_occurrence_class c
JOIN sel s ON s.Dead_Group_ID = c.Dead_Group_ID AND s.File_Name = c.File_Name
ORDER BY c.TO_Name;
