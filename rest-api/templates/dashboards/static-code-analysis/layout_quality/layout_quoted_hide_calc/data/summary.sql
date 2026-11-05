-- Hand-maintained wrapper around the rule core (layout_quoted_hide_calc).
-- Counts both slots the rule covers: the hide condition and (since converter
-- 2.30.0) the field-entry condition of a layout object.
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE c.Calc_Role = 'hide') AS hide_count,
       COUNT(*) FILTER (WHERE c.Calc_Role = 'field_entry') AS entry_count,
       COUNT(DISTINCT l.L_UUID) AS affected_layouts,
       COUNT(DISTINCT lo.File_Name) AS affected_files
FROM CalculationsCatalog c
JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
JOIN Layouts l ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
WHERE c.Calc_Role IN ('hide', 'field_entry')
  AND trim(COALESCE(c.Formula_Text, c.Display_Text)) LIKE '"%"'
  AND NOT trim(COALESCE(c.Formula_Text, c.Display_Text)) LIKE '"%"%"'
  AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
