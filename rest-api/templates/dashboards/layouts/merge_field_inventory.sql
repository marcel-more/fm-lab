-- @template_type: report
-- @title: Merge field inventory
-- @description: Every merge field (<<Field>>, German UI: Platzhalter) placed in a layout text object, one row per text object × field with the TO-qualified field, its base table occurrence and the target file. Merge fields hide inside text blocks, so this inventory is where field usage in static text becomes readable side by side. Resolved anchors only — anchors that render literally because their field cannot be resolved are a finding of the merge-anchor validation test, not of this inventory. Merge variables (<<$$var>>) and layout calculations (<<ƒ:…>>) have their own inventories.
-- @icon: field
-- @display: table
-- @chip_filter: table
-- @chip_param: table
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 500
-- @params: file (optional), page (optional), page_size (optional, default 500), q (optional), sort (optional), dir (optional), table (optional)
-- @click_action: openObject
-- @click_args: uuid={{_object_uuid}}&ref={{_nav_uuid}}&file={{file_name}}
-- @row_action: openObject
-- @row_action_args: uuid={{_nav_uuid}}&type=Layout&file={{file_name}}&ref={{_object_uuid}}
-- @row_action_label: Show in layout
-- @output_format: file_name, layout_name, object_name, field, table, target_file, _message, _chip_facets, _row_total, _page, _page_size
-- @object_types: Layout
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "merge_fields", "meaning": "Merge-field anchors on layout text objects in scope (inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: layouts, merge, fields, inventory
--
-- Companion of the merge-variable and layout-calculation inventories: same
-- shape, same scope model. Source is the displays_field edge restricted to
-- TEXT objects — the decisive cut: displays_field also carries regular field
-- placements (Edit Box, Checkbox Set, …), but only text objects carry merge
-- syntax. The aggregated layout-level mirror of the same role
-- (Source_Type='Layout') is excluded for the same reason.
--
-- Granularity is one row per (text object × field): several anchors of the
-- SAME field inside ONE text block collapse onto a single edge by design —
-- an occurrence count would need the structural field list, a deliberate
-- later stage.
--
-- The table chips switch SERVER-SIDE (`@chip_param: table`) over the whole
-- scope. `_chip_facets` counts over `result` — every filter EXCEPT the search and the table
-- itself — while `_row_total` counts over `filtered` (WITH that filter), so the
-- header names the truncation and only then.
WITH result AS MATERIALIZED (
    SELECT
        ol.Source_File AS file_name,
        ly.L_UUID AS _nav_uuid,
        ly.L_Name AS layout_name,
        -- No object_type column: the Text filter below makes it a constant.
        COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)') AS object_name,
        tgt.Object_Name AS field,
        split_part(tgt.Object_Name, '::', 1) AS "table",
        tgt.File_Name AS target_file,
        lo.Object_Type || ' ' || COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)')
          || ' — merge field <<' || tgt.Object_Name || '>>' AS _message,
        lo.Object_UUID AS _object_uuid
    FROM ObjectLinks ol
    JOIN LayoutObjects lo ON ol.Source_UUID = lo.Object_UUID AND ol.Source_File = lo.File_Name
    JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
    WHERE ol.Link_Role = 'displays_field'
      AND ol.Source_Type = 'LayoutObject'
      AND lo.Object_Type = 'Text'
      AND (getvariable('file') IS NULL OR ol.Source_File = getvariable('file'))
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
    WHERE (getvariable('table') IS NULL OR "table" = getvariable('table'))
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
    (SELECT to_json(map_from_entries(list(("table", n) ORDER BY "table")))
       FROM (SELECT "table", count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ file_name, layout_name, object_name, field, _object_uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
