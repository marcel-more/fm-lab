-- Hand-maintained wrapper around the rule core (layout_invalid_symbol).
WITH invalid AS (
    SELECT s.*
    FROM LayoutObjectSymbols s
    WHERE NOT EXISTS (SELECT 1 FROM ref.function_name_lookup f
                      WHERE f.chunk_role = 'getparameter'
                        AND lower(f.lookup_name) = s.Symbol_Norm)
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT i.Symbol_Norm) AS distinct_symbols,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT i.File_Name) AS affected_files
FROM invalid i
JOIN Layouts ly ON ly.L_ID = i.Layout_ID AND ly.File_Name = i.File_Name
WHERE (getvariable('file') IS NULL OR i.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
