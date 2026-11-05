-- Distinct object types among the rule's findings — options dataset for the
-- object-type Select. Deliberately independent of the extent and object_type
-- filters so the option list stays stable while filtering; respects the
-- file/scope filters. Rule-core predicates (portal scrollbar tolerance,
-- PopoverPanel exclusion, zero-line edge cases) mirror findings.sql.
WITH child AS (
    SELECT c.File_Name, c.Layout_ID, c.Object_Type,
           c.Bounds_Left AS bl, c.Bounds_Top AS bt, c.Bounds_Right AS br, c.Bounds_Bottom AS bb,
           (par.Bounds_Bottom - par.Bounds_Top) AS parent_h,
           (par.Bounds_Right - par.Bounds_Left)
               + CASE WHEN par.Object_Type = 'Portal' THEN 19 ELSE 0 END AS eff_w,
           (c.Object_Type = 'Line'
            AND (c.Bounds_Right - c.Bounds_Left = 0 OR c.Bounds_Bottom - c.Bounds_Top = 0)) AS zero_line
    FROM LayoutObjects c
    JOIN LayoutObjects par ON c.Parent_Object_ID = par.Object_ID
     AND c.Layout_ID = par.Layout_ID AND c.File_Name = par.File_Name
    WHERE c.Object_Type <> 'PopoverPanel'
),
flagged AS (
    SELECT *,
        CASE WHEN zero_line THEN (br < 0 OR bb < 0 OR bl > eff_w OR bt > parent_h)
             ELSE (br <= 0 OR bb <= 0 OR bl >= eff_w OR bt >= parent_h) END AS fully_out,
        (bl < 0 OR bt < 0 OR br > eff_w OR bb > parent_h) AS out_any
    FROM child
)
SELECT DISTINCT f.Object_Type AS value, f.Object_Type AS label
FROM flagged f
JOIN Layouts ly ON f.Layout_ID = ly.L_ID AND f.File_Name = ly.File_Name
WHERE (f.fully_out OR f.out_any)
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY value;
