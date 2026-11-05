-- Groups (Object_Type 'Group') containing exactly one child. Restricted to
-- real groups on purpose — FileMaker serializes single-object buttons as
-- 'Grouped Button' with one child, which is its normal form, not a finding.
-- Translated from fmCheckMate ReportGroupOfOne.
WITH single_groups AS (
    SELECT g.File_Name, g.Layout_ID, g.Object_UUID, g.Object_Name, g.Part_Type,
           g.Bounds_Left AS bl, g.Bounds_Top AS bt, g.Bounds_Right AS br, g.Bounds_Bottom AS bb,
           any_value(c.Object_Type) AS child_type,
           any_value(c.Object_Name) AS child_name
    FROM LayoutObjects g
    JOIN LayoutObjects c ON c.Parent_Object_ID = g.Object_ID
     AND c.Layout_ID = g.Layout_ID AND c.File_Name = g.File_Name
    WHERE g.Object_Type = 'Group'
    GROUP BY g.File_Name, g.Layout_ID, g.Object_UUID, g.Object_Name, g.Part_Type,
             g.Bounds_Left, g.Bounds_Top, g.Bounds_Right, g.Bounds_Bottom
    HAVING COUNT(*) = 1
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-group-of-one' AS rule_id, 'info' AS severity,
        g.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        g.Object_UUID AS object_uuid, 'Group' AS object_type, g.Object_Name AS object_name,
        g.Part_Type AS part_type, g.child_type, g.child_name,
        g.bl AS x, g.bt AS y, (g.br - g.bl) AS w, (g.bb - g.bt) AS h,
        'Group contains a single ' || g.child_type || ' object — grouping overhead without grouping anything' AS message,
           g.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           g.Object_UUID AS _ord_3
    FROM single_groups g
    JOIN Layouts ly ON g.Layout_ID = ly.L_ID AND g.File_Name = ly.File_Name
    WHERE (getvariable('file') IS NULL OR g.File_Name = getvariable('file'))
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
