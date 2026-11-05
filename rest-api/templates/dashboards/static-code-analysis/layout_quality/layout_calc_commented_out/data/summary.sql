-- Hand-maintained wrapper around the rule core (layout_calc_commented_out).
-- The object-type select (getvariable('object_type')) narrows all counts;
-- the calc_slot filter is deliberately NOT applied here — the per-slot counts
-- feed the chip badges, which must always show the true per-slot totals.
WITH slots AS (
    SELECT lo.File_Name, lo.Layout_ID, lo.Object_Type,
           CASE c.Calc_Role WHEN 'button_label' THEN 'label'
                            WHEN 'field_entry'  THEN 'entry'
                            ELSE c.Calc_Role END AS calc_slot,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc_text
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    WHERE c.Calc_Role IN ('hide', 'field_entry', 'tooltip', 'button_label')
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'hide') AS hide_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'entry') AS entry_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'tooltip') AS tooltip_count,
       COUNT(*) FILTER (WHERE s.calc_slot = 'label') AS label_count,
       COUNT(DISTINCT l.L_UUID) AS affected_layouts,
       COUNT(DISTINCT s.File_Name) AS affected_files
FROM slots s
JOIN Layouts l ON s.Layout_ID = l.L_ID AND s.File_Name = l.File_Name
WHERE trim(s.calc_text) LIKE '/*%' AND trim(s.calc_text) LIKE '%*/'
  AND (getvariable('object_type') IS NULL OR s.Object_Type = getvariable('object_type'))
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
