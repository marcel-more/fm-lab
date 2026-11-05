-- @template_type: report
-- @title: Hide condition inventory
-- @description: Every layout object that carries a "Hide object when" calculation, with the formula side by side. Hide conditions are invisible in Layout mode, so this inventory is the place where contradictory conditions, copy-paste variants and conditions referencing retired fields become readable next to each other.
-- @icon: layers
-- @display: table
-- @chip_filter: object_type
-- @chip_param: object_type
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 500
-- @params: file (optional), page (optional), page_size (optional, default 500), q (optional), sort (optional), dir (optional), object_type (optional)
-- @click_action: openObject
-- @click_args: uuid={{_object_uuid}}&ref={{_nav_uuid}}&file={{file_name}}
-- @row_action: openObject
-- @row_action_args: uuid={{_nav_uuid}}&type=Layout&file={{file_name}}&ref={{_object_uuid}}
-- @row_action_label: Show in layout
-- @output_format: file_name, layout_name, object_type, object_name, hide_calc, _message, _chip_facets, _row_total, _page, _page_size
-- @object_types: Layout
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "hide conditions", "meaning": "Layout objects with a hide condition in scope (inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: layouts, hide, visibility, inventory
--
-- Companion of the conditional-formatting inventory: same shape, same scope
-- model, one row per carrying object. The presence predicate mirrors the
-- layout-canvas payload (NULLIF(Hide_Calculation_Text, '') IS NOT NULL, no
-- trim) so the layout view's "Hide Condition" chip counter and this inventory
-- always agree for a layout scope.
--
-- The object-type chips switch SERVER-SIDE (`@chip_param: object_type`) over
-- the whole scope. `_chip_facets` counts over `result` — every filter EXCEPT the search and the
-- object type itself — while `_row_total` counts over `filtered` (WITH that filter),
-- so the header names the truncation and only then.
WITH result AS MATERIALIZED (
    SELECT
        lo.File_Name AS file_name,
        ly.L_UUID AS _nav_uuid,
        ly.L_Name AS layout_name,
        lo.Object_Type AS object_type,
        COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)') AS object_name,
        replace(lo.Hide_Calculation_Text, chr(10), ' ') AS hide_calc,
        lo.Object_Type || ' ' || COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)')
          || ' — hidden when '
          || replace(lo.Hide_Calculation_Text, chr(10), ' ') AS _message,
        lo.Object_UUID AS _object_uuid
    FROM LayoutObjects lo
    JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
    WHERE NULLIF(lo.Hide_Calculation_Text, '') IS NOT NULL
      AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- >>> shared paging search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) <> 'uuid'))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging search block
filtered AS (
    SELECT * FROM searched
    WHERE (getvariable('object_type') IS NULL OR object_type = getvariable('object_type'))
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
    -- Facets ordered by value, so every request returns the same text.
    (SELECT to_json(map_from_entries(list((object_type, n) ORDER BY object_type)))
       FROM (SELECT object_type, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ file_name, layout_name, object_name, _object_uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
