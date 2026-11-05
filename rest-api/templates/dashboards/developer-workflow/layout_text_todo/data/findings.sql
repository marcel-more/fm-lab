-- Layout objects carrying a TODO marker in their text content, tooltip
-- calculation or label calculation. Part of the "Unfinished Work" rule family;
-- the detector is the canon of tools/tests/rules/unfinished_work_detector.sql:
--
--   TODO: (?i)(\bto[\s\-_]?do|\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)
--
-- The TODO family deliberately has NO trailing word boundary — otherwise real
-- markers such as "TO DOs" fall out. The leading \b keeps prose out ("today").
--
-- Deviation from the fmCheckMate source rule, deliberate and measured: the
-- source matches `LIKE '%TODO%'` case-sensitively and without separator
-- tolerance and therefore misses a text object whose entire content reads
-- "TO DO" — a real finding in the reference corpus. The family uses one
-- detector across scripts, layouts and calculations.
--
-- Slot sources: the text slot is LayoutObjects.Text_Content (static layout
-- text, not a calculation slot — since schema 1.33.0 also the label of a button
-- or popover button); the tooltip, label and title slots are the
-- CalculationsCatalog instances of the object (roles tooltip / button_label /
-- popover_title and panel_title). The title of a popover panel used to arrive
-- through Text_Content; it is a calculation and now has its own slot.
--
-- Severity is info (traffic light: neutral): a TODO is an inventory figure,
-- not a defect. The defect half of the family is layout_text_fixme.
--
-- One finding per object and slot; an object that carries the marker in two
-- slots is reported twice.
WITH slots AS (
    SELECT File_Name, Layout_ID, Object_UUID, Object_Type, Object_Name, Part_Type,
           Bounds_Left, Bounds_Top, Bounds_Right, Bounds_Bottom,
           'text' AS slot, Text_Content AS content
    FROM LayoutObjects WHERE Text_Content IS NOT NULL
    UNION ALL
    SELECT lo.File_Name, lo.Layout_ID, lo.Object_UUID, lo.Object_Type, lo.Object_Name, lo.Part_Type,
           lo.Bounds_Left, lo.Bounds_Top, lo.Bounds_Right, lo.Bounds_Bottom,
           CASE c.Calc_Role WHEN 'button_label' THEN 'label'
                            WHEN 'tooltip' THEN 'tooltip'
                            ELSE 'title' END AS slot,
           COALESCE(c.Formula_Text, c.Display_Text) AS content
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    WHERE c.Calc_Role IN ('tooltip', 'button_label', 'popover_title', 'panel_title')
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-text-todo' AS rule_id, 'info' AS severity,
        s.File_Name AS file_name, ly.L_UUID AS nav_uuid, ly.L_Name AS layout_name,
        s.Object_UUID AS object_uuid, s.Object_Type AS object_type, s.Object_Name AS object_name,
        s.Part_Type AS part_type, s.slot,
        regexp_extract(s.content, '(?i)(\bto[\s\-_]?do|\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)', 0) AS marker,
        s.Bounds_Left AS x, s.Bounds_Top AS y,
        (s.Bounds_Right - s.Bounds_Left) AS w, (s.Bounds_Bottom - s.Bounds_Top) AS h,
        CASE s.slot
            WHEN 'text' THEN 'TODO marker in the text content'
            WHEN 'tooltip' THEN 'TODO marker in the tooltip calculation'
            WHEN 'title' THEN 'TODO marker in the title calculation'
            ELSE 'TODO marker in the label calculation'
        END AS message,
           s.File_Name AS _ord_1,
           ly.L_Name AS _ord_2,
           s.Object_UUID AS _ord_3,
           s.slot AS _ord_4
    FROM slots s
    JOIN Layouts ly ON s.Layout_ID = ly.L_ID AND s.File_Name = ly.File_Name
    WHERE regexp_matches(s.content, '(?i)(\bto[\s\-_]?do|\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)')
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
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
