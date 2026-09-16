-- Distinct object types among the rule's findings — options dataset for the
-- object-type Select. Deliberately independent of the calc_slot and
-- object_type filters so the option list stays stable while filtering;
-- respects the file/scope filters.
WITH slots AS (
    SELECT lo.File_Name, lo.Layout_ID, lo.Object_Type,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc_text
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    WHERE c.Calc_Role IN ('hide', 'field_entry', 'tooltip', 'button_label')
)
SELECT DISTINCT s.Object_Type AS value, s.Object_Type AS label
FROM slots s
JOIN Layouts l ON s.Layout_ID = l.L_ID AND s.File_Name = l.File_Name
WHERE trim(s.calc_text) LIKE '/*%' AND trim(s.calc_text) LIKE '%*/'
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY value;
