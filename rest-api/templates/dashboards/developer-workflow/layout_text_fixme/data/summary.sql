-- Hand-maintained wrapper around the rule core (layout_text_fixme).
-- Keep the detector and the filters in sync with data/findings.sql.
WITH slots AS (
    SELECT File_Name, Layout_ID, Object_UUID, 'text' AS slot, Text_Content AS content
    FROM LayoutObjects WHERE Text_Content IS NOT NULL
    UNION ALL
    SELECT lo.File_Name, lo.Layout_ID, lo.Object_UUID,
           CASE c.Calc_Role WHEN 'button_label' THEN 'label'
                            WHEN 'tooltip' THEN 'tooltip'
                            ELSE 'title' END,
           COALESCE(c.Formula_Text, c.Display_Text)
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    WHERE c.Calc_Role IN ('tooltip', 'button_label', 'popover_title', 'panel_title')
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT s.File_Name) AS affected_files
FROM slots s
JOIN Layouts ly ON s.Layout_ID = ly.L_ID AND s.File_Name = ly.File_Name
WHERE regexp_matches(s.content, '(?i)\bfix[\s\-_]?(it|me)\b')
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
