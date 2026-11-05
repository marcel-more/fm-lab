-- Hand-maintained wrapper around the rule core (layout_broken_valuelist).
WITH leaf AS (
    SELECT lo.*
    FROM LayoutObjects lo
    WHERE lo.Object_XML LIKE '%<ValueListReference%'
      AND NOT EXISTS (SELECT 1 FROM LayoutObjects k
                      WHERE k.Parent_Object_ID = lo.Object_ID
                        AND k.Layout_ID = lo.Layout_ID
                        AND k.File_Name = lo.File_Name)
),
ref AS (
    SELECT l.File_Name, l.Layout_ID, l.Object_UUID,
           regexp_extract(l.Object_XML, '<ValueListReference[^>]*id="(\d+)"', 1) AS vl_id
    FROM leaf l
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT r.File_Name) AS affected_files
FROM ref r
JOIN Layouts ly ON r.Layout_ID = ly.L_ID AND r.File_Name = ly.File_Name
WHERE r.vl_id IS NOT NULL AND r.vl_id <> ''
  AND NOT EXISTS (SELECT 1 FROM ValueListCatalog v
                  WHERE v.File_Name = r.File_Name
                    AND v.VL_ID = TRY_CAST(r.vl_id AS BIGINT))
  AND (getvariable('file') IS NULL OR r.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
