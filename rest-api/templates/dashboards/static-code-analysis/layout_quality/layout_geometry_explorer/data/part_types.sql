-- Distinct layout parts — options dataset for the part Select. Independent of
-- the explorer's own filters so the option list stays stable while filtering;
-- respects the app-level file/scope narrowing. Part_Type values are
-- P1-canonical English tokens (locale-independent).
SELECT DISTINCT lo.Part_Type AS value, lo.Part_Type AS label
FROM LayoutObjects lo
JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
WHERE lo.Part_Type IS NOT NULL AND lo.Part_Type <> ''
  AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY value;
