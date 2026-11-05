-- Hand-maintained wrapper around the rule core (layout_button_without_action).
-- buttons_total puts the finding count in perspective: a high absolute number
-- is unremarkable in a solution with thousands of buttons.
SELECT COUNT(*) FILTER (WHERE no_action) AS finding_count,
       COUNT(DISTINCT ly.L_UUID) FILTER (WHERE no_action) AS affected_layouts,
       COUNT(*) AS buttons_total
FROM (
    SELECT b.File_Name, b.Layout_ID, b.Object_UUID,
           (b.Object_XML NOT LIKE '%<ScriptReference%' AND b.Object_XML NOT LIKE '%<Step%') AS no_action,
           COALESCE(p.Object_Type, 'top-level') AS context
    FROM LayoutObjects b
    LEFT JOIN LayoutObjects p
           ON b.Parent_Object_ID = p.Object_ID AND b.Layout_ID = p.Layout_ID AND b.File_Name = p.File_Name
    WHERE b.Object_Type = 'Button'
) b
JOIN Layouts ly ON b.Layout_ID = ly.L_ID AND b.File_Name = ly.File_Name
WHERE (getvariable('context') IS NULL OR b.context = getvariable('context'))
  AND (getvariable('file') IS NULL OR b.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
