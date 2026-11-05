-- Layout symbols ({{…}}) in the label of a button or popover button.
--
-- FileMaker evaluates a symbol only in a text object. In the label of a button
-- (kind 10) or popover button (kind 14) every symbol stays literal in browse and
-- preview mode — valid Get parameters such as {{CurrentDate}} included — while
-- merge fields, merge variables and layout calculations typed into the same
-- label ARE evaluated. That makes the symbol the one anchor kind that silently
-- does nothing there. Info, not a warning: the literal text may be intended.
--
-- Source is the symbol inventory LayoutObjectSymbols (P3 A.13); it lists the
-- symbols of button labels since Text_Content carries the label (schema
-- 1.33.0). The kind filter runs on LayoutObjects.Object_Kind — the inventory's
-- Is_Evaluated column says the same, but catalogs of older converters lack it.
-- On such a catalog the rule finds nothing (button labels were not extracted),
-- never a false positive. One finding per (object, symbol) with its occurrence
-- count, like layout_invalid_symbol.
WITH lo AS (
    -- LayoutObjects can carry duplicate rows per (Object_UUID, File_Name).
    SELECT Object_UUID, Object_ID, File_Name, Object_Name, Object_Type,
           Bounds_Left, Bounds_Top, Bounds_Right, Bounds_Bottom,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    WHERE Object_Kind IN (10, 14)
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-button-label-symbol' AS rule_id, 'info' AS severity,
        s.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        o.Object_UUID AS object_uuid, o.Object_Type AS object_type,
        COALESCE(NULLIF(trim(o.Object_Name), ''), '(unnamed)') AS object_name,
        '{{' || s.Symbol_Text || '}}' AS symbol,
        s.Occurrence_Count AS occurrences,
        'not-evaluated' AS defect,
        o.Bounds_Left AS x, o.Bounds_Top AS y,
        (o.Bounds_Right - o.Bounds_Left) AS w, (o.Bounds_Bottom - o.Bounds_Top) AS h,
        '{{' || s.Symbol_Text || '}} in a button label is not evaluated — the text renders literally' AS message,
           s.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           o.Object_Name AS _ord_3,
           s.Symbol_Norm AS _ord_4
    FROM LayoutObjectSymbols s
    JOIN lo o       ON o.Object_UUID = s.Object_UUID AND o.File_Name = s.File_Name AND o.rn = 1
    JOIN Layouts ly ON ly.L_ID = s.Layout_ID AND ly.File_Name = s.File_Name
    WHERE (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
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
