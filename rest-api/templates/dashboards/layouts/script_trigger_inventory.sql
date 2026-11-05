-- @template_type: report
-- @title: Script trigger inventory
-- @description: Every script trigger installed on a layout object, with its event, active modes, target script and parameter side by side. Object triggers are invisible in Layout mode, so this inventory is where surprise OnObjectModify chains, mode gaps and triggers pointing at renamed scripts become readable next to each other.
-- @icon: script
-- @display: table
-- @chip_filter: event
-- @chip_param: event
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 500
-- @params: file (optional), page (optional), page_size (optional, default 500), q (optional), sort (optional), dir (optional), event (optional)
-- @click_action: openObject
-- @click_args: uuid={{_object_uuid}}&ref={{_nav_uuid}}&file={{file_name}}
-- @row_action: openObject
-- @row_action_args: uuid={{_nav_uuid}}&type=Layout&file={{file_name}}&ref={{_object_uuid}}
-- @row_action_label: Show in layout
-- @output_format: file_name, layout_name, object_type, object_name, event, modes, script_name, parameter_field, _message, _chip_facets, _row_total, _page, _page_size
-- @object_types: Layout
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "triggers", "meaning": "Script triggers on layout objects in scope (inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: layouts, triggers, scripts, inventory
--
-- Companion of the conditional-formatting inventory: same shape, same scope
-- model, one row per trigger (an object can carry several — Trigger_ID keeps
-- the FileMaker dialog order). Deliberately restricted to Owner_Type =
-- 'LayoutObject', matching the layout view's "Triggers" chip: layout- and
-- file-level triggers live in the layout/file meta panels, not here. Note the
-- chip counts carrying OBJECTS while this inventory lists TRIGGERS — an
-- object with three triggers is one chip hit and three rows.
--
-- `modes` folds the three tri-state mode flags ('True'/NULL) into a compact
-- list; `parameter_field` is the field-based script parameter where one is
-- set (calculation parameters live in CalculationsCatalog, role
-- script_trigger_parameter — out of scope for this flat inventory).
--
-- The event chips switch SERVER-SIDE (`@chip_param: event`) over the whole
-- scope. `_chip_facets` counts over `result` — every filter EXCEPT the search and the event
-- itself — while `_row_total` counts over `filtered` (WITH that filter), so the
-- header names the truncation and only then.
WITH result AS MATERIALIZED (
    SELECT
        st.File_Name AS file_name,
        ly.L_UUID AS _nav_uuid,
        ly.L_Name AS layout_name,
        lo.Object_Type AS object_type,
        COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)') AS object_name,
        st.Trigger_Action AS event,
        concat_ws(', ',
            CASE WHEN st.Trigger_BrowseMode  = 'True' THEN 'browse'  END,
            CASE WHEN st.Trigger_FindMode    = 'True' THEN 'find'    END,
            CASE WHEN st.Trigger_PreviewMode = 'True' THEN 'preview' END) AS modes,
        st.Script_Name AS script_name,
        NULLIF(st.Trigger_ScriptParameter_FieldName, '') AS parameter_field,
        lo.Object_Type || ' ' || COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)')
          || ' — ' || st.Trigger_Action
          || COALESCE(' runs ' || st.Script_Name, '') AS _message,
        st.Owner_UUID AS _object_uuid,
        st.Trigger_ID AS _trigger_order
    FROM ScriptTriggers st
    JOIN LayoutObjects lo ON st.Owner_UUID = lo.Object_UUID AND st.File_Name = lo.File_Name
    JOIN Layouts ly ON lo.Layout_ID = ly.L_ID AND lo.File_Name = ly.File_Name
    WHERE st.Owner_Type = 'LayoutObject'
      AND (getvariable('file') IS NULL OR st.File_Name = getvariable('file'))
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
    WHERE (getvariable('event') IS NULL OR event = getvariable('event'))
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
SELECT f.* EXCLUDE (_trigger_order),
    -- Facets ordered by value, so every request returns the same text.
    (SELECT to_json(map_from_entries(list((event, n) ORDER BY event)))
       FROM (SELECT event, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ file_name, layout_name, object_name, _trigger_order, _object_uuid, event, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
