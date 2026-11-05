-- Degenerate layout objects in three classes — zero width or height,
-- text objects without text, and objects below the minimum size in both
-- dimensions (width/height sliders min_w/min_h, default 4 px each). Lines are excluded entirely,
-- zero extent is their normal shape. Priority when classes overlap is
-- zero-size, then empty-text, then undersized (one finding per object).
-- The defect chips (getvariable('defect')) and the object-type select
-- (getvariable('object_type')) narrow the result server-side — unset means
-- no filter.
WITH sized AS (
    SELECT File_Name, Layout_ID, Object_UUID, Object_Type, Object_Name, Part_Type, Text_Content,
           Bounds_Left AS bl, Bounds_Top AS bt, Bounds_Right AS br, Bounds_Bottom AS bb,
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
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-degenerate-object' AS rule_id, 'info' AS severity,
        c.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        c.Object_UUID AS object_uuid, c.Object_Type AS object_type, c.Object_Name AS object_name,
        c.Part_Type AS part_type, c.defect,
        CAST(COALESCE(getvariable('min_w'), '4') AS INTEGER) AS min_w,
        CAST(COALESCE(getvariable('min_h'), '4') AS INTEGER) AS min_h,
        c.bl AS x, c.bt AS y, c.w AS w, c.h AS h,
        CASE c.defect
            WHEN 'zero-size' THEN 'Object has zero width or height'
            WHEN 'empty-text' THEN 'Text object contains no text'
            ELSE 'Object is smaller than ' || CAST(COALESCE(getvariable('min_w'), '4') AS INTEGER) || '×' || CAST(COALESCE(getvariable('min_h'), '4') AS INTEGER) || ' px (width×height)'
        END AS message,
           c.defect AS _ord_1,
           c.File_Name AS _ord_2,
           ly.L_Name AS _ord_3,
           c.Object_UUID AS _ord_4
    FROM classified c
    JOIN Layouts ly ON c.Layout_ID = ly.L_ID AND c.File_Name = ly.File_Name
    WHERE c.defect IS NOT NULL
      AND (getvariable('defect') IS NULL OR c.defect = getvariable('defect'))
      AND (getvariable('object_type') IS NULL OR c.Object_Type = getvariable('object_type'))
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
