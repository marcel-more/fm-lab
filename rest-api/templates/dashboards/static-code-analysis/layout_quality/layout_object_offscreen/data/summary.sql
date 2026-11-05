-- Hand-maintained wrapper around the rule core (layout_object_offscreen).
WITH layout_box AS (
    SELECT ly.File_Name, ly.L_ID, ly.L_UUID, ly.L_Width,
           (SELECT SUM(lp.Part_Size) FROM LayoutParts lp
             WHERE lp.Layout_ID = ly.L_ID AND lp.File_Name = ly.File_Name) AS l_height
    FROM Layouts ly
    WHERE (ly.Folder_Type IS NULL OR ly.Folder_Type = 'False')
      AND NOT COALESCE(ly.Is_Separator, FALSE)
),
outside AS (
    SELECT lo.File_Name, b.L_UUID,
           GREATEST(lo.Bounds_Right - b.L_Width, lo.Bounds_Bottom - b.l_height,
                    -lo.Bounds_Left, -lo.Bounds_Top) AS overshoot,
           CASE WHEN lo.Bounds_Left >= b.L_Width OR lo.Bounds_Top >= b.l_height
                     OR lo.Bounds_Right <= 0 OR lo.Bounds_Bottom <= 0
                THEN 'complete' ELSE 'partial' END AS extent
    FROM LayoutObjects lo
    JOIN layout_box b ON lo.Layout_ID = b.L_ID AND lo.File_Name = b.File_Name
    WHERE lo.Nesting_Level = 0
      AND (lo.Bounds_Left < 0 OR lo.Bounds_Top < 0
           OR lo.Bounds_Right > b.L_Width OR lo.Bounds_Bottom > b.l_height)
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE extent = 'complete') AS complete_count,
       COUNT(*) FILTER (WHERE extent = 'partial') AS partial_count,
       COUNT(DISTINCT L_UUID) AS affected_layouts
FROM outside o
WHERE o.overshoot > CAST(COALESCE(getvariable('tolerance'), '0') AS INTEGER)
  AND (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR o.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
