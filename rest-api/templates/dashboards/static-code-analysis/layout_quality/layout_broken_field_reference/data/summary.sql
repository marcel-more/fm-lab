-- Hand-maintained wrapper around the rule core (layout_broken_field_reference).
WITH leaf AS (
    SELECT lo.*
    FROM LayoutObjects lo
    WHERE lo.Object_XML LIKE '%<FieldReference%'
      AND NOT EXISTS (SELECT 1 FROM LayoutObjects k
                      WHERE k.Parent_Object_ID = lo.Object_ID
                        AND k.Layout_ID = lo.Layout_ID
                        AND k.File_Name = lo.File_Name)
),
ref AS (
    SELECT l.File_Name, l.Layout_ID, l.Object_UUID,
           regexp_extract(l.Object_XML, '<FieldReference[^>]*id="(\d+)"', 1) AS f_id,
           regexp_extract(l.Object_XML, '<TableOccurrenceReference[^>]*id="(\d+)"', 1) AS to_id
    FROM leaf l
),
resolved AS (
    SELECT r.*, t.TO_UUID, t.BT_Name,
           COALESCE(NULLIF(regexp_replace(COALESCE(t.DS_Name, ''), '\.fmp12$', ''), ''), r.File_Name) AS target_file
    FROM ref r
    LEFT JOIN TableOccurrenceCatalog t
           ON t.File_Name = r.File_Name AND t.TO_ID = TRY_CAST(r.to_id AS BIGINT)
    WHERE r.to_id IS NOT NULL AND r.to_id <> ''
),
classified AS (
    SELECT rv.*,
        CASE
            WHEN rv.TO_UUID IS NULL THEN 'missing-to'
            WHEN rv.target_file NOT IN (SELECT File_Name FROM FilesCatalog) THEN NULL
            WHEN NOT EXISTS (SELECT 1 FROM FieldsForTables f
                             WHERE f.File_Name = rv.target_file
                               AND f.Table_Name = rv.BT_Name
                               AND f.Field_ID = TRY_CAST(rv.f_id AS BIGINT)) THEN 'missing-field'
        END AS defect
    FROM resolved rv
)
SELECT COUNT(*) AS finding_count,
       COUNT(DISTINCT ly.L_UUID) AS affected_layouts,
       COUNT(DISTINCT c.File_Name) AS affected_files
FROM classified c
JOIN Layouts ly ON c.Layout_ID = ly.L_ID AND c.File_Name = ly.File_Name
WHERE c.defect IS NOT NULL
  AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
