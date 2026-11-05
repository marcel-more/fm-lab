-- Hand-maintained wrapper around the rule core (layout_quoted_object_name).
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT l.L_UUID) AS affected_layouts,
       COUNT(DISTINCT lo.File_Name) AS affected_files
FROM LayoutObjects lo
JOIN Layouts l ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
WHERE lo.Object_Name LIKE '"%"'
  AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
