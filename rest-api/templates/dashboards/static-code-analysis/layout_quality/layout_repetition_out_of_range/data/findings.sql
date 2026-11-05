-- Layout objects that display a field repetition beyond the repetition count
-- of the field they are bound to. The displayed repetition is only available
-- in the raw object XML (the catalog resolves the field, not the repetition
-- index), the field itself comes from the resolved displays_field link.
-- Container objects are excluded: their XML embeds the markup of their
-- children, so the first FieldReference found there may belong to a child.
-- Translated from fmCheckMate ReportRepetitionOutOfRange.
WITH leaf AS (
    SELECT lo.*
    FROM LayoutObjects lo
    WHERE lo.Object_XML LIKE '%<FieldReference%'
      AND NOT EXISTS (SELECT 1 FROM LayoutObjects k
                      WHERE k.Parent_Object_ID = lo.Object_ID
                        AND k.Layout_ID = lo.Layout_ID
                        AND k.File_Name = lo.File_Name)
),
shown AS (
    SELECT l.File_Name, l.Layout_ID, l.Object_UUID, l.Object_Type, l.Object_Name, l.Part_Type,
           l.Bounds_Left, l.Bounds_Top, l.Bounds_Right, l.Bounds_Bottom,
           TRY_CAST(regexp_extract(l.Object_XML, '<FieldReference[^>]*repetition="(\d+)"', 1) AS INTEGER) AS repetition,
           ol.Target_UUID AS field_uuid
    FROM leaf l
    JOIN ObjectLinks ol ON ol.Source_UUID = l.Object_UUID AND ol.Link_Role = 'displays_field'
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-repetition-out-of-range' AS rule_id, 'error' AS severity,
        s.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        s.Object_UUID AS object_uuid, s.Object_Type AS object_type, s.Object_Name AS object_name,
        s.Part_Type AS part_type,
        f.Field_Name AS field, s.repetition, f.Max_Repetitions AS max_repetitions,
        s.Bounds_Left AS x, s.Bounds_Top AS y,
        (s.Bounds_Right - s.Bounds_Left) AS w, (s.Bounds_Bottom - s.Bounds_Top) AS h,
        'Object shows repetition ' || s.repetition || ', the field has only ' || f.Max_Repetitions AS message,
           s.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           s.Object_UUID AS _ord_3
    FROM shown s
    JOIN FieldsForTables f ON s.field_uuid = f.Field_UUID
    JOIN Layouts ly ON s.Layout_ID = ly.L_ID AND s.File_Name = ly.File_Name
    WHERE s.repetition IS NOT NULL
      AND f.Max_Repetitions IS NOT NULL
      AND s.repetition > f.Max_Repetitions
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u) AS row_key
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
