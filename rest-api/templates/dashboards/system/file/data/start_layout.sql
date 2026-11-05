-- Start layout ("switch to layout" on open), 0 or 1 row.
-- Row click → openObject on the layout.
SELECT
    o.Default_Layout_Name AS target_name,
    o.Default_Layout_UUID AS target_uuid,
    o.File_Name
FROM FileOptionsCatalog o
WHERE o.File_Name = :file
  AND o.Default_Layout_UUID IS NOT NULL;
