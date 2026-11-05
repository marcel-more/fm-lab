-- Layout-object geometry inventory — one row per layout object with its own
-- x/y/w/h (parent-relative for nested objects, layout-absolute at top level)
-- plus part, nesting level and z-order. The coordinate window
-- (x_min/x_max/y_min/y_max, layout-absolute, "object intersects window")
-- matches top-level objects exactly; nested objects count via their top-level
-- container, resolved through the recursive root walk below. Size filters
-- (w_min/w_max/h_min/h_max) apply to the object itself. Unset parameters mean
-- no filter.
WITH RECURSIVE rooted AS (
    SELECT File_Name, Layout_ID, Object_ID, Object_ID AS root_id
    FROM LayoutObjects
    WHERE Parent_Object_ID IS NULL
    UNION ALL
    SELECT c.File_Name, c.Layout_ID, c.Object_ID, r.root_id
    FROM LayoutObjects c
    JOIN rooted r ON c.Parent_Object_ID = r.Object_ID
     AND c.Layout_ID = r.Layout_ID AND c.File_Name = r.File_Name
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        lo.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        lo.Part_Type AS part_type, lo.Object_Type AS object_type, lo.Object_Name AS object_name,
        lo.Nesting_Level AS nesting,
        lo.Bounds_Left AS x, lo.Bounds_Top AS y,
        (lo.Bounds_Right - lo.Bounds_Left) AS w, (lo.Bounds_Bottom - lo.Bounds_Top) AS h,
        lo.Z_Order AS z,
        lo.Object_UUID AS object_uuid,
           lo.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           lo.Z_Order AS _ord_3,
           lo.Object_UUID AS _ord_4
    FROM LayoutObjects lo
    JOIN rooted rt ON rt.Object_ID = lo.Object_ID
     AND rt.Layout_ID = lo.Layout_ID AND rt.File_Name = lo.File_Name
    JOIN LayoutObjects root ON root.Object_ID = rt.root_id
     AND root.Layout_ID = lo.Layout_ID AND root.File_Name = lo.File_Name
    JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
    WHERE (getvariable('part') IS NULL OR lo.Part_Type = getvariable('part'))
      AND (getvariable('object_type') IS NULL OR lo.Object_Type = getvariable('object_type'))
      AND (getvariable('w_min') IS NULL OR (lo.Bounds_Right - lo.Bounds_Left) >= CAST(getvariable('w_min') AS INTEGER))
      AND (getvariable('w_max') IS NULL OR (lo.Bounds_Right - lo.Bounds_Left) <= CAST(getvariable('w_max') AS INTEGER))
      AND (getvariable('h_min') IS NULL OR (lo.Bounds_Bottom - lo.Bounds_Top) >= CAST(getvariable('h_min') AS INTEGER))
      AND (getvariable('h_max') IS NULL OR (lo.Bounds_Bottom - lo.Bounds_Top) <= CAST(getvariable('h_max') AS INTEGER))
      AND (getvariable('x_min') IS NULL OR root.Bounds_Right > CAST(getvariable('x_min') AS INTEGER))
      AND (getvariable('x_max') IS NULL OR root.Bounds_Left < CAST(getvariable('x_max') AS INTEGER))
      AND (getvariable('y_min') IS NULL OR root.Bounds_Bottom > CAST(getvariable('y_min') AS INTEGER))
      AND (getvariable('y_max') IS NULL OR root.Bounds_Top < CAST(getvariable('y_max') AS INTEGER))
      AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
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
