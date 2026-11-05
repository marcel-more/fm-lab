-- Data-driven slider ceilings. Deliberately independent of the explorer's own
-- filters (part/type/size/window) so the slider ranges stay stable while
-- filtering — only the app-level file/scope narrowing applies. X/Y maxima come
-- from top-level bounds (layout-absolute); W/H maxima from all objects.
SELECT
    (SELECT COALESCE(max(lo.Bounds_Right - lo.Bounds_Left), 1) FROM LayoutObjects lo
      JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
      WHERE (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
        AND (getvariable('scope_uuids') IS NULL
             OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))) AS max_w,
    (SELECT COALESCE(max(lo.Bounds_Bottom - lo.Bounds_Top), 1) FROM LayoutObjects lo
      JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
      WHERE (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
        AND (getvariable('scope_uuids') IS NULL
             OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))) AS max_h,
    (SELECT COALESCE(max(lo.Bounds_Right), 1) FROM LayoutObjects lo
      JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
      WHERE lo.Parent_Object_ID IS NULL
        AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
        AND (getvariable('scope_uuids') IS NULL
             OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))) AS max_x,
    (SELECT COALESCE(max(lo.Bounds_Bottom), 1) FROM LayoutObjects lo
      JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
      WHERE lo.Parent_Object_ID IS NULL
        AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
        AND (getvariable('scope_uuids') IS NULL
             OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))) AS max_y;
