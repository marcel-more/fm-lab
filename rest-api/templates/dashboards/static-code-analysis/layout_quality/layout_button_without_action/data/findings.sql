-- Buttons that carry neither a script call nor a single-step action.
--
-- SaveAsXML serialises a button's action in one of two shapes: a script action
-- becomes a ScriptReference, a single-step action becomes a Step element. A
-- button with neither does nothing when clicked. The Button/Options value is
-- NOT a usable discriminator — the same value appears on buttons with and
-- without an action.
--
-- Buttons never have child objects, so the container-XML caveat does not
-- apply here; the parent context is reported instead, because an inactive
-- button-bar segment or a decorative icon inside a portal reads very
-- differently from a lone top-level button that lost its script.
-- Translated from fmCheckMate ReportButtonsWithoutAction.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-button-without-action' AS rule_id, 'info' AS severity,
        b.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        b.Object_UUID AS object_uuid, b.Object_Type AS object_type, b.Object_Name AS object_name,
        b.Part_Type AS part_type,
        COALESCE(p.Object_Type, 'top-level') AS context,
        b.Bounds_Left AS x, b.Bounds_Top AS y,
        (b.Bounds_Right - b.Bounds_Left) AS w, (b.Bounds_Bottom - b.Bounds_Top) AS h,
        'Button has neither a script call nor a single-step action' AS message,
           b.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           b.Object_UUID AS _ord_3
    FROM LayoutObjects b
    LEFT JOIN LayoutObjects p
           ON b.Parent_Object_ID = p.Object_ID AND b.Layout_ID = p.Layout_ID AND b.File_Name = p.File_Name
    JOIN Layouts ly ON b.Layout_ID = ly.L_ID AND b.File_Name = ly.File_Name
    WHERE b.Object_Type = 'Button'
      AND b.Object_XML NOT LIKE '%<ScriptReference%'
      AND b.Object_XML NOT LIKE '%<Step%'
      AND (getvariable('context') IS NULL OR COALESCE(p.Object_Type, 'top-level') = getvariable('context'))
      AND (getvariable('file') IS NULL OR b.File_Name = getvariable('file'))
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
