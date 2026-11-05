-- Hand-maintained wrapper around the rule core (layout_stacked_duplicate_object).
WITH sib AS (
    SELECT File_Name, Layout_ID, COALESCE(Parent_Object_ID, -1) AS parent_scope, Part_Type,
           Object_ID, Object_Type,
           Bounds_Left AS bl, Bounds_Top AS bt, Bounds_Right AS br, Bounds_Bottom AS bb
    FROM LayoutObjects
    WHERE Object_Type NOT IN ('Panel', 'PopoverPanel')
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT a.File_Name) AS affected_files
FROM sib a
JOIN sib b ON a.File_Name = b.File_Name AND a.Layout_ID = b.Layout_ID
 AND a.parent_scope = b.parent_scope
 AND a.Part_Type IS NOT DISTINCT FROM b.Part_Type
 AND a.Object_Type = b.Object_Type
 AND a.Object_ID < b.Object_ID
 AND a.bl = b.bl AND a.bt = b.bt AND a.br = b.br AND a.bb = b.bb
JOIN Layouts ly ON a.Layout_ID = ly.L_ID AND a.File_Name = ly.File_Name
WHERE (getvariable('file') IS NULL OR a.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
