-- @template_type: report
-- @title: Merge variable inventory
-- @description: Every merge variable (<<$$var>>, German UI: Platzhaltervariable) placed in a layout text object, one row per text object × variable. Merge variables hide inside text blocks and only render once a script sets them, so this inventory is where the display side of that contract becomes readable. Only genuine merge-variable anchors are listed — variables read inside layout calculations travel as reads_variable and belong to the layout-calculation inventory; the {{…}} layout symbols (which the German Claris UI also calls "Variablen") have their own symbol substrate and are not part of this inventory either.
-- @icon: variable
-- @display: table
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 500
-- @params: file (optional), page (optional), page_size (optional, default 500), q (optional), sort (optional), dir (optional)
-- @click_action: openObject
-- @click_args: uuid={{_object_uuid}}&ref={{_nav_uuid}}&file={{file_name}}
-- @row_action: openObject
-- @row_action_args: uuid={{_nav_uuid}}&type=Layout&file={{file_name}}&ref={{_object_uuid}}
-- @row_action_label: Show in layout
-- @output_format: file_name, layout_name, object_name, variable, _message, _row_total, _page, _page_size
-- @object_types: Layout, Variable
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "merge_variables", "meaning": "Merge-variable anchors on layout text objects in scope (inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: layouts, merge, variables, inventory
--
-- Companion of the merge-field and layout-calculation inventories: same
-- shape, same scope model. Source is the displays_variable edge — it arises
-- EXCLUSIVELY from merge-variable anchors in layout text, so no object-type
-- cut is needed here (unlike displays_field, which also carries field
-- placements).
--
-- No scope column and no chips: merge variables are global ($$) by
-- definition. The exotic exceptions — a syntactically possible but inert
-- local <<$x>>, or an MBS $$$superglobal — stay visible through the prefix
-- the `variable` column carries anyway. `_row_total` still names the
-- truncation when LIMIT cuts the list.
WITH result AS MATERIALIZED (
    SELECT
        ol.Source_File AS file_name,
        ly.L_UUID AS _nav_uuid,
        ly.L_Name AS layout_name,
        -- No object_type column: merge variables anchor in Text objects by
        -- definition — a constant column carries no information.
        COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)') AS object_name,
        tgt.Object_Name AS variable,
        lo.Object_Type || ' ' || COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)')
          || ' — merge variable <<' || tgt.Object_Name || '>>' AS _message,
        lo.Object_UUID AS _object_uuid
    FROM ObjectLinks ol
    JOIN LayoutObjects lo ON ol.Source_UUID = lo.Object_UUID AND ol.Source_File = lo.File_Name
    JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
    WHERE ol.Link_Role = 'displays_variable'
      AND ol.Source_Type = 'LayoutObject'
      AND (getvariable('file') IS NULL OR ol.Source_File = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
           OR tgt.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
ORDER BY /*@sort*/ file_name, layout_name, object_name, variable, _object_uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
