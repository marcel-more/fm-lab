-- Hide-object and field-entry conditions that consist of a single quoted string
-- literal with no inner quotes — a constant, not a calculation; usually pasted
-- together with its quotes. Translated from fmCheckMate
-- ReportBrokenCalculationQuoted.
-- Formula source is the CalculationsCatalog hide / field_entry instance of the
-- object (single source for all calculation slots). The field-entry formula
-- (FileMaker's "governed by a formula" entry mode; only FileMaker 26 exports
-- carry its text) is a slot of its own since converter 2.30.0 and shares the
-- defect class — FileMaker offers the same condition editor for both slots.
-- LayoutObjects contributes the geometry and typing of the owning object.
-- msg_id picks the localized message per slot (manifest messages.quoted /
-- messages.quoted_entry) for the layout deep link.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-quoted-hide-calc' AS rule_id, 'error' AS severity,
        lo.File_Name AS file_name, l.L_UUID AS nav_uuid, l.L_Name AS layout_name,
        lo.Object_UUID AS object_uuid, lo.Object_Type AS object_type, lo.Object_Name AS object_name,
        lo.Part_Type AS part_type,
        CASE c.Calc_Role WHEN 'field_entry' THEN 'entry' ELSE 'hide' END AS calc_slot,
        CASE c.Calc_Role WHEN 'field_entry' THEN 'quoted_entry' ELSE 'quoted' END AS msg_id,
        lo.Bounds_Left AS x, lo.Bounds_Top AS y, (lo.Bounds_Right - lo.Bounds_Left) AS w, (lo.Bounds_Bottom - lo.Bounds_Top) AS h,
        CASE c.Calc_Role WHEN 'field_entry' THEN 'Field-entry condition' ELSE 'Hide condition' END
            || ' is a quoted string constant, not a calculation — ' || trim(COALESCE(c.Formula_Text, c.Display_Text)) AS message,
           lo.File_Name AS _ord_1,
           l.L_Name AS _ord_2,
           lo.Object_UUID AS _ord_3,
           c.Calc_Role AS _ord_4
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    JOIN Layouts l ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
    WHERE c.Calc_Role IN ('hide', 'field_entry')
      AND trim(COALESCE(c.Formula_Text, c.Display_Text)) LIKE '"%"'
      AND NOT trim(COALESCE(c.Formula_Text, c.Display_Text)) LIKE '"%"%"'
      AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
