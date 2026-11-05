-- @template_type: report
-- @title: Conditional formatting by object
-- @description: Every layout object that carries conditional formatting, one row per object with the number of rules and how many of them are enabled. The per-rule companion "Conditional formatting inventory" shows each condition with its formula and CSS; this grouped variant surfaces the rule-heavy objects and the ones whose rules are switched off — disabled rules are invisible in the layout yet still cost evaluation review time.
-- @icon: palette
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
-- @output_format: file_name, layout_name, object_type, object_name, conditions_count, conditions_active, _message, _chip_facets, _row_total, _page, _page_size
-- @object_types: Layout
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "objects", "meaning": "Layout objects carrying conditional formatting in scope (inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 1.1
-- @tags: layouts, formatting, styling, inventory
--
-- Two click targets: the row click opens the layout-object detail view
-- (object UUID primary, layout as ref); the arrow button at the end of the
-- row (`@row_action`) jumps to the object in the rendered layout.
--
-- Reads LayoutObjectConditions, the parsed rule catalog (one row per
-- conditional-formatting rule, anchored to the owning object at import) —
-- never the raw Object_XML. Unlike an XML extraction with a leaf filter,
-- the catalog also attributes rules on containers that have children
-- (e.g. a tab panel with its own conditions), so the object set here can
-- be slightly larger than the per-rule inventory's.
--
-- A rule is active when bit 0 (ENABLE) of Options_Raw is set; the style
-- toggles of the rule live elsewhere and do not affect this flag.
--
-- The object-type chips switch SERVER-SIDE (`@chip_param: object_type`) over
-- the whole scope. `_chip_facets` counts over `result` — every filter EXCEPT the search and the
-- object type itself, otherwise each chip would only ever show its own
-- selection — while `_row_total` counts over `filtered`, i.e. WITH that filter, so
-- the header names the truncation and only then.
WITH result AS MATERIALIZED (
    SELECT
        loc.File_Name AS file_name,
        ly.L_UUID AS _nav_uuid,
        ly.L_Name AS layout_name,
        lo.Object_Type AS object_type,
        COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)') AS object_name,
        count(*) AS conditions_count,
        sum(CASE WHEN (loc.Options_Raw & 1) = 1 THEN 1 ELSE 0 END) AS conditions_active,
        lo.Object_Type || ' ' || COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)')
          || ' — ' || count(*) || ' condition' || CASE WHEN count(*) = 1 THEN '' ELSE 's' END
          || ' (' || sum(CASE WHEN (loc.Options_Raw & 1) = 1 THEN 1 ELSE 0 END) || ' active)' AS _message,
        loc.Object_UUID AS _object_uuid
    FROM LayoutObjectConditions loc
    JOIN LayoutObjects lo ON loc.Object_UUID = lo.Object_UUID
    JOIN Layouts ly ON loc.Layout_ID = ly.L_ID AND loc.File_Name = ly.File_Name
    WHERE (getvariable('file') IS NULL OR loc.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY loc.File_Name, ly.L_UUID, ly.L_Name, lo.Object_Type,
             lo.Object_Name, loc.Object_UUID
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
ORDER BY /*@sort*/ conditions_count DESC, file_name, layout_name, object_name, _object_uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
