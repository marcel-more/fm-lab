-- Hand-maintained wrapper around the rule core (layout_object_occluded).
WITH sib AS (
    SELECT File_Name, Layout_ID, COALESCE(Parent_Object_ID, -1) AS parent_scope, Part_Type,
           Object_ID, Object_UUID, Object_Type, Z_Order,
           Bounds_Left AS bl, Bounds_Top AS bt, Bounds_Right AS br, Bounds_Bottom AS bb
    FROM LayoutObjects
),
covered AS (
    SELECT DISTINCT o.File_Name, o.Layout_ID, o.Object_UUID
    FROM sib o
    JOIN sib c ON o.File_Name = c.File_Name AND o.Layout_ID = c.Layout_ID
     AND o.parent_scope = c.parent_scope
     AND o.Part_Type IS NOT DISTINCT FROM c.Part_Type
     AND o.Object_ID <> c.Object_ID
    WHERE c.Object_Type IN ('Portal', 'Tab Control', 'Slide Control')
      AND o.Object_Type NOT IN ('Popover Button', 'PopoverPanel')
      AND c.Z_Order > o.Z_Order
      AND o.bl >= c.bl AND o.bt >= c.bt AND o.br <= c.br AND o.bb <= c.bb
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT o.File_Name) AS affected_files
FROM covered o
JOIN Layouts ly ON o.Layout_ID = ly.L_ID AND o.File_Name = ly.File_Name
WHERE (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
