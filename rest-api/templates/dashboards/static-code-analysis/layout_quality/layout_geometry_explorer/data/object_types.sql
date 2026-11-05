-- Distinct layout-object types — options dataset for the object-type Select.
-- Independent of the explorer's own filters so the option list stays stable
-- while filtering; respects the app-level file/scope narrowing.
SELECT DISTINCT lo.Object_Type AS value, lo.Object_Type AS label
FROM LayoutObjects lo
JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
WHERE (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY value;
