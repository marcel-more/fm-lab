-- Hand-maintained wrapper around the rule core (layout_button_label_symbol).
WITH btn AS (
    SELECT s.*
    FROM LayoutObjectSymbols s
    WHERE EXISTS (SELECT 1 FROM LayoutObjects k
                  WHERE k.Object_UUID = s.Object_UUID AND k.File_Name = s.File_Name
                    AND k.Object_Kind IN (10, 14))
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT b.Symbol_Norm) AS distinct_symbols,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT b.File_Name) AS affected_files
FROM btn b
JOIN Layouts ly ON ly.L_ID = b.Layout_ID AND ly.File_Name = b.File_Name
WHERE (getvariable('file') IS NULL OR b.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
