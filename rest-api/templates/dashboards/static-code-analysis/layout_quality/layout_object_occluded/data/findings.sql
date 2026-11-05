-- Objects completely covered by a sibling portal, tab control or slide
-- control that is drawn later in the stacking order (higher Z_Order = in
-- front). Siblings share one coordinate system, so bounds compare directly.
-- Popover buttons and panels are excluded (their panels float). Objects in
-- front of containers (e.g. buttons over portals) are normal design and not
-- flagged. Translated from fmCheckMate ReportObjectsHiddenBehindContainers.
WITH sib AS (
    SELECT File_Name, Layout_ID, COALESCE(Parent_Object_ID, -1) AS parent_scope, Part_Type,
           Object_ID, Object_UUID, Object_Type, Object_Name, Z_Order,
           Bounds_Left AS bl, Bounds_Top AS bt, Bounds_Right AS br, Bounds_Bottom AS bb
    FROM LayoutObjects
),
covered AS (
    SELECT o.File_Name, o.Layout_ID, o.Object_UUID, o.Object_Type, o.Object_Name, o.Part_Type,
           o.bl, o.bt, o.br, o.bb,
           c.Object_Type AS container_type, c.Object_Name AS container_name,
           row_number() OVER (PARTITION BY o.File_Name, o.Layout_ID, o.Object_ID
                              ORDER BY c.Z_Order DESC) AS rn
    FROM sib o
    JOIN sib c ON o.File_Name = c.File_Name AND o.Layout_ID = c.Layout_ID
     AND o.parent_scope = c.parent_scope
     AND o.Part_Type IS NOT DISTINCT FROM c.Part_Type
     AND o.Object_ID <> c.Object_ID
    WHERE c.Object_Type IN ('Portal', 'Tab Control', 'Slide Control')
      AND o.Object_Type NOT IN ('Popover Button', 'PopoverPanel')
      AND c.Z_Order > o.Z_Order
      AND o.bl >= c.bl AND o.bt >= c.bt AND o.br <= c.br AND o.bb <= c.bb
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-object-occluded' AS rule_id, 'warning' AS severity,
        o.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        o.Object_UUID AS object_uuid, o.Object_Type AS object_type, o.Object_Name AS object_name,
        o.Part_Type AS part_type, o.container_type,
        o.bl AS x, o.bt AS y, (o.br - o.bl) AS w, (o.bb - o.bt) AS h,
        'Object lies completely behind a ' || o.container_type || ' drawn in front of it — covered and unreachable in Browse mode' AS message,
           o.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           o.Object_UUID AS _ord_3
    FROM covered o
    JOIN Layouts ly ON o.Layout_ID = ly.L_ID AND o.File_Name = ly.File_Name
    WHERE o.rn = 1
      AND (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
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
