-- Hide-object and field-entry conditions that consist of a single quoted string
-- literal with no inner quotes — a constant, not a calculation; usually pasted
-- together with its quotes. Translated from fmCheckMate
-- ReportBrokenCalculationQuoted.
-- Formula source is the CalculationsCatalog hide / field_entry instance of the
-- object (single source for all calculation slots). The field-entry formula
-- (FileMaker's "governed by a formula" entry mode; only FileMaker 26 exports
-- carry its text) is a slot of its own since converter 2.30.0 and shares the
-- defect class — FileMaker offers the same condition editor for both slots.
-- LayoutObjects contributes the geometry and typing of the owning object.
-- msg_id picks the localized message per slot (manifest messages.quoted /
-- messages.quoted_entry) for the layout deep link.
SELECT 'layout-quoted-hide-calc' AS rule_id, 'error' AS severity,
    lo.File_Name AS file_name, l.L_UUID AS nav_uuid, l.L_Name AS layout_name,
    lo.Object_UUID AS object_uuid, lo.Object_Type AS object_type, lo.Object_Name AS object_name,
    lo.Part_Type AS part_type,
    CASE c.Calc_Role WHEN 'field_entry' THEN 'entry' ELSE 'hide' END AS calc_slot,
    CASE c.Calc_Role WHEN 'field_entry' THEN 'quoted_entry' ELSE 'quoted' END AS msg_id,
    lo.Bounds_Left AS x, lo.Bounds_Top AS y, (lo.Bounds_Right - lo.Bounds_Left) AS w, (lo.Bounds_Bottom - lo.Bounds_Top) AS h,
    CASE c.Calc_Role WHEN 'field_entry' THEN 'Field-entry condition' ELSE 'Hide condition' END
        || ' is a quoted string constant, not a calculation — ' || trim(COALESCE(c.Formula_Text, c.Display_Text)) AS message,
    row_number() OVER (ORDER BY lo.File_Name, l.L_Name, lo.Object_UUID, c.Calc_Role) AS row_key
FROM CalculationsCatalog c
JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
JOIN Layouts l ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
WHERE c.Calc_Role IN ('hide', 'field_entry')
  AND trim(COALESCE(c.Formula_Text, c.Display_Text)) LIKE '"%"'
  AND NOT trim(COALESCE(c.Formula_Text, c.Display_Text)) LIKE '"%"%"'
  AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY row_key
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
