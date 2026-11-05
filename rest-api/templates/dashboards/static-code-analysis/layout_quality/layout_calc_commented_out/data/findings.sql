-- Hide, field-entry, tooltip and label calculation slots whose entire text is
-- one /* ... */ comment block. Such a slot never evaluates, so the intended
-- behavior is silently disabled. Translated from fmCheckMate
-- ReportBrokenCalculationCommentedOut.
-- Formula source is the CalculationsCatalog (single source for all calculation
-- slots; roles hide / field_entry / tooltip / button_label — surfaced as the
-- chip values hide / entry / tooltip / label). The field-entry formula
-- (FileMaker's "governed by a formula" entry mode) is a slot of its own since
-- converter 2.30.0; only FileMaker 26 exports carry its text, a FileMaker 22
-- export omits it. LayoutObjects contributes geometry and typing of the
-- owning object.
-- The slot chips (getvariable('calc_slot')) and the object-type select
-- (getvariable('object_type')) narrow the result server-side — unset means
-- no filter.
WITH slots AS (
    SELECT lo.File_Name, lo.Layout_ID, lo.Object_UUID, lo.Object_Type, lo.Object_Name, lo.Part_Type,
           lo.Bounds_Left, lo.Bounds_Top, lo.Bounds_Right, lo.Bounds_Bottom,
           CASE c.Calc_Role WHEN 'button_label' THEN 'label'
                            WHEN 'field_entry'  THEN 'entry'
                            ELSE c.Calc_Role END AS calc_slot,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc_text
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    WHERE c.Calc_Role IN ('hide', 'field_entry', 'tooltip', 'button_label')
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-calc-commented-out' AS rule_id, 'error' AS severity,
        s.File_Name AS file_name, l.L_UUID AS nav_uuid, l.L_Name AS layout_name,
        s.Object_UUID AS object_uuid, s.Object_Type AS object_type, s.Object_Name AS object_name,
        s.Part_Type AS part_type, s.calc_slot,
        s.Bounds_Left AS x, s.Bounds_Top AS y, (s.Bounds_Right - s.Bounds_Left) AS w, (s.Bounds_Bottom - s.Bounds_Top) AS h,
        'The ' || CASE s.calc_slot WHEN 'entry' THEN 'field-entry' ELSE s.calc_slot END
            || ' calculation is completely commented out — ' || substr(trim(s.calc_text), 1, 120) AS message,
           s.File_Name AS _ord_1,
           l.L_Name AS _ord_2,
           s.Object_UUID AS _ord_3,
           s.calc_slot AS _ord_4
    FROM slots s
    JOIN Layouts l ON s.Layout_ID = l.L_ID AND s.File_Name = l.File_Name
    WHERE trim(s.calc_text) LIKE '/*%' AND trim(s.calc_text) LIKE '%*/'
      AND (getvariable('calc_slot') IS NULL OR s.calc_slot = getvariable('calc_slot'))
      AND (getvariable('object_type') IS NULL OR s.Object_Type = getvariable('object_type'))
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
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
