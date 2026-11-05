-- Layout objects whose field reference no longer resolves.
--
-- Resolution runs over the NUMERIC IDs, never over UUIDs. Cross-file
-- references routinely carry a stale UUID while the field itself is intact —
-- FileMaker resolves them by id at runtime, and a UUID-based detector reports
-- the overwhelming majority of them as broken. The chain is:
--   object XML → TableOccurrenceReference@id → TableOccurrenceCatalog (file-local)
--              → data source file + base table → FieldsForTables.Field_ID
-- The TO join also runs over the id, because names in the raw XML are
-- entity-encoded (&#xE4; …) while the catalog holds them decoded.
--
-- Two guards keep the result honest:
--   1. Container objects are excluded — their XML embeds the markup of their
--      children, so a child's field reference would be attributed to the parent.
--   2. Objects whose target file is not part of the catalog are skipped: their
--      fields cannot be checked, and reporting them would be a guess.
-- Translated from fmCheckMate ReportBrokenFieldReferences.
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
    SELECT l.File_Name, l.Layout_ID, l.Object_UUID, l.Object_Type, l.Object_Name, l.Part_Type,
           l.Bounds_Left, l.Bounds_Top, l.Bounds_Right, l.Bounds_Bottom,
           regexp_extract(l.Object_XML, '<FieldReference[^>]*id="(\d+)"', 1) AS f_id,
           regexp_extract(l.Object_XML, '<FieldReference[^>]*name="([^"]*)"', 1) AS f_name,
           regexp_extract(l.Object_XML, '<TableOccurrenceReference[^>]*id="(\d+)"', 1) AS to_id,
           regexp_extract(l.Object_XML, '<TableOccurrenceReference[^>]*name="([^"]*)"', 1) AS to_name
    FROM leaf l
),
resolved AS (
    SELECT r.*, t.TO_UUID, t.TO_Name AS to_catalog_name, t.BT_Name,
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
            WHEN rv.target_file NOT IN (SELECT File_Name FROM FilesCatalog) THEN NULL  -- unverifiable
            WHEN NOT EXISTS (SELECT 1 FROM FieldsForTables f
                             WHERE f.File_Name = rv.target_file
                               AND f.Table_Name = rv.BT_Name
                               AND f.Field_ID = TRY_CAST(rv.f_id AS BIGINT)) THEN 'missing-field'
        END AS defect
    FROM resolved rv
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-broken-field-reference' AS rule_id, 'error' AS severity,
        c.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        c.Object_UUID AS object_uuid, c.Object_Type AS object_type, c.Object_Name AS object_name,
        c.Part_Type AS part_type, c.defect,
        COALESCE(NULLIF(c.f_name, ''), '#' || c.f_id) AS field,
        COALESCE(c.to_catalog_name, NULLIF(c.to_name, ''), '#' || c.to_id) AS table_occurrence,
        c.Bounds_Left AS x, c.Bounds_Top AS y,
        (c.Bounds_Right - c.Bounds_Left) AS w, (c.Bounds_Bottom - c.Bounds_Top) AS h,
        CASE c.defect
            WHEN 'missing-to' THEN 'Table occurrence no longer exists in this file'
            ELSE 'Field no longer exists in the target table'
        END AS message,
           c.defect AS _ord_1,
           c.File_Name AS _ord_2,
           ly.L_Name AS _ord_3,
           c.Object_UUID AS _ord_4
    FROM classified c
    JOIN Layouts ly ON c.Layout_ID = ly.L_ID AND c.File_Name = ly.File_Name
    WHERE c.defect IS NOT NULL
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u) AS row_key
    FROM unkeyed u
),
-- >>> shared paging table-search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) NOT IN ('uuid', 'nav_uuid', 'row_key')))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging table-search block
filtered AS (
    SELECT * FROM searched
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
