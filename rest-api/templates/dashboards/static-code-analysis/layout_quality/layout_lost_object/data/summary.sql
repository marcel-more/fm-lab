-- Hand-maintained wrapper around the rule core (layout_lost_object).
-- The object-type select (getvariable('object_type')) narrows all counts;
-- the extent filter is deliberately NOT applied here — the per-extent counts
-- feed the chip badges, which must always show the true per-extent totals.
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
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE fully_out) AS fully_out_count,
       COUNT(*) FILTER (WHERE NOT fully_out) AS partially_out_count,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts
FROM flagged f
JOIN Layouts ly ON f.Layout_ID = ly.L_ID AND f.File_Name = ly.File_Name
WHERE (f.fully_out OR f.out_any)
  AND (getvariable('object_type') IS NULL OR f.Object_Type = getvariable('object_type'))
  AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
