-- Hand-maintained wrapper around the rule core (layout_degenerate_object).
-- The object-type select (getvariable('object_type')) narrows all counts;
-- the defect filter is deliberately NOT applied here — the per-defect counts
-- feed the chip badges, which must always show the true per-defect totals.
WITH sized AS (
    SELECT File_Name, Layout_ID, Object_Type, Text_Content,
           (Bounds_Right - Bounds_Left) AS w, (Bounds_Bottom - Bounds_Top) AS h
    FROM LayoutObjects
    WHERE Object_Type <> 'Line'
),
classified AS (
    SELECT *,
        CASE WHEN w <= 0 OR h <= 0 THEN 'zero-size'
             WHEN Object_Type = 'Text' AND trim(COALESCE(Text_Content, '')) = '' THEN 'empty-text'
             WHEN w < CAST(COALESCE(getvariable('min_w'), '4') AS INTEGER)
              AND h < CAST(COALESCE(getvariable('min_h'), '4') AS INTEGER) THEN 'undersized'
        END AS defect
    FROM sized
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE defect = 'empty-text') AS empty_text_count,
       COUNT(*) FILTER (WHERE defect = 'undersized') AS undersized_count,
       COUNT(*) FILTER (WHERE defect = 'zero-size') AS zero_size_count
FROM classified c
JOIN Layouts ly ON c.Layout_ID = ly.L_ID AND c.File_Name = ly.File_Name
WHERE c.defect IS NOT NULL
  AND (getvariable('object_type') IS NULL OR c.Object_Type = getvariable('object_type'))
  AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
