-- Hide, field-entry, tooltip and label calculation slots whose entire text is
-- one /* ... */ comment block. Such a slot never evaluates, so the intended
-- behavior is silently disabled. Translated from fmCheckMate
-- ReportBrokenCalculationCommentedOut.
-- Formula source is the CalculationsCatalog (single source for all calculation
-- slots; roles hide / field_entry / tooltip / button_label — surfaced as the
-- chip values hide / entry / tooltip / label). The field-entry formula
-- (FileMaker's "governed by a formula" entry mode) is a slot of its own since
-- converter 2.30.0; only FileMaker 26 exports carry its text, a FileMaker 22
-- export omits it. LayoutObjects contributes geometry and typing of the
-- owning object.
-- The slot chips (getvariable('calc_slot')) and the object-type select
-- (getvariable('object_type')) narrow the result server-side — unset means
-- no filter.
WITH slots AS (
    SELECT lo.File_Name, lo.Layout_ID, lo.Object_UUID, lo.Object_Type, lo.Object_Name, lo.Part_Type,
           lo.Bounds_Left, lo.Bounds_Top, lo.Bounds_Right, lo.Bounds_Bottom,
           CASE c.Calc_Role WHEN 'button_label' THEN 'label'
                            WHEN 'field_entry'  THEN 'entry'
                            ELSE c.Calc_Role END AS calc_slot,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc_text
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    WHERE c.Calc_Role IN ('hide', 'field_entry', 'tooltip', 'button_label')
)
SELECT 'layout-calc-commented-out' AS rule_id, 'error' AS severity,
    s.File_Name AS file_name, l.L_UUID AS nav_uuid, l.L_Name AS layout_name,
    s.Object_UUID AS object_uuid, s.Object_Type AS object_type, s.Object_Name AS object_name,
    s.Part_Type AS part_type, s.calc_slot,
    s.Bounds_Left AS x, s.Bounds_Top AS y, (s.Bounds_Right - s.Bounds_Left) AS w, (s.Bounds_Bottom - s.Bounds_Top) AS h,
    'The ' || CASE s.calc_slot WHEN 'entry' THEN 'field-entry' ELSE s.calc_slot END
        || ' calculation is completely commented out — ' || substr(trim(s.calc_text), 1, 120) AS message,
    row_number() OVER (ORDER BY s.File_Name, l.L_Name, s.Object_UUID, s.calc_slot) AS row_key
FROM slots s
JOIN Layouts l ON s.Layout_ID = l.L_ID AND s.File_Name = l.File_Name
WHERE trim(s.calc_text) LIKE '/*%' AND trim(s.calc_text) LIKE '%*/'
  AND (getvariable('calc_slot') IS NULL OR s.calc_slot = getvariable('calc_slot'))
  AND (getvariable('object_type') IS NULL OR s.Object_Type = getvariable('object_type'))
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY row_key
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
