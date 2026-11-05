-- Hand-maintained COUNT wrapper over the explorer's object list — keep the
-- filter block in sync with data/objects.sql (all filters apply, no limit),
-- so the KPI numbers always describe the full filtered set, not the page.
WITH RECURSIVE rooted AS (
    SELECT File_Name, Layout_ID, Object_ID, Object_ID AS root_id
    FROM LayoutObjects
    WHERE Parent_Object_ID IS NULL
    UNION ALL
    SELECT c.File_Name, c.Layout_ID, c.Object_ID, r.root_id
    FROM LayoutObjects c
    JOIN rooted r ON c.Parent_Object_ID = r.Object_ID
     AND c.Layout_ID = r.Layout_ID AND c.File_Name = r.File_Name
)
SELECT
    COUNT(*) AS object_count,
    COUNT(DISTINCT ly.L_UUID) AS layout_count,
    COUNT(DISTINCT lo.File_Name) AS file_count
FROM LayoutObjects lo
JOIN rooted rt ON rt.Object_ID = lo.Object_ID
 AND rt.Layout_ID = lo.Layout_ID AND rt.File_Name = lo.File_Name
JOIN LayoutObjects root ON root.Object_ID = rt.root_id
 AND root.Layout_ID = lo.Layout_ID AND root.File_Name = lo.File_Name
JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
WHERE (getvariable('part') IS NULL OR lo.Part_Type = getvariable('part'))
  AND (getvariable('object_type') IS NULL OR lo.Object_Type = getvariable('object_type'))
  AND (getvariable('w_min') IS NULL OR (lo.Bounds_Right - lo.Bounds_Left) >= CAST(getvariable('w_min') AS INTEGER))
  AND (getvariable('w_max') IS NULL OR (lo.Bounds_Right - lo.Bounds_Left) <= CAST(getvariable('w_max') AS INTEGER))
  AND (getvariable('h_min') IS NULL OR (lo.Bounds_Bottom - lo.Bounds_Top) >= CAST(getvariable('h_min') AS INTEGER))
  AND (getvariable('h_max') IS NULL OR (lo.Bounds_Bottom - lo.Bounds_Top) <= CAST(getvariable('h_max') AS INTEGER))
  AND (getvariable('x_min') IS NULL OR root.Bounds_Right > CAST(getvariable('x_min') AS INTEGER))
  AND (getvariable('x_max') IS NULL OR root.Bounds_Left < CAST(getvariable('x_max') AS INTEGER))
  AND (getvariable('y_min') IS NULL OR root.Bounds_Bottom > CAST(getvariable('y_min') AS INTEGER))
  AND (getvariable('y_max') IS NULL OR root.Bounds_Top < CAST(getvariable('y_max') AS INTEGER))
  AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
