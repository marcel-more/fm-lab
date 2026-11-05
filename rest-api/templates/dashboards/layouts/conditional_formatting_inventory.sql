-- @template_type: report
-- @title: Conditional formatting inventory
-- @description: Every conditional-formatting rule on a layout object, with its enabled state, operator, operands, formula and a generic description of the applied format. Conditional formatting is invisible in Layout mode, so this inventory is the only place the rules become readable side by side — which is where duplicated conditions, disabled leftovers and colour rules nobody remembers become visible. Inspired by the fmCheckMate check "ListConditionalFormatting" — https://github.com/mrwatson-de/fmCheckMate-XSLT
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
-- @output_format: file_name, layout_name, object_type, object_name, condition_no, active, operator, operands, condition_calc, format, _message, _chip_facets, _row_total, _page, _page_size
-- @object_types: Layout
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "conditions", "meaning": "Conditional-formatting conditions in scope (inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 2.1
-- @tags: layouts, formatting, styling, inventory, fmcheckmate
--
-- v2.0 reads LayoutObjectConditions, the rule catalog parsed at import
-- (schema 1.25.0) — the XML-regex extraction with its mandatory leaf filter
-- is gone. The catalog is anchored to the owning object at parse depth, so
-- containers that carry their own rules AND children (e.g. a tab panel) are
-- included; the old leaf filter silently dropped those. Solutions converted
-- before schema 1.25.0 lack the table and report a schema drift until they
-- are re-converted.
--
-- `object_type` (column and chips) is the LayoutObject SUBTYPE (Button,
-- Edit Box, …), not ObjectCatalog.Object_Type — name kept for continuity.
--
-- A rule is active when bit 0 (ENABLE) of Options_Raw is set.
--
-- `operator`/`operands` render only for value-based rules (Condition_Kind
-- 'value'; @type matrix 1-13). Formula rules keep them empty — their
-- condition is the formula itself. A stale Range_Start/End can survive on a
-- formula rule when its type was switched in the editor, so the kind gates
-- the columns, not the presence of a range.
--
-- `format` is a coarse, property-level summary of Local_CSS ("bold, fill
-- color, text color"). v2.1 mirrors the two authority models of the C3 CSS
-- parser (rest-api/src/utils/cf-css.js): colours, font family and font size
-- count only when their Options bit says they were actively chosen (bit 1
-- text colour, 2 fill colour, 3 family, 4 size, 7 icon colour) — the rule
-- dialog serialises those properties as baseline state even when unchecked
-- (font-family/12pt-size travel with every use of the Textformat dialog).
-- The bit-less style toggles count by presence. Unknown properties fall back
-- to their raw CSS name instead of being dropped. `box-shadow: none`
-- accompanies most fill changes as serialisation noise and is excluded —
-- except when it is the rule's only declaration, which renders as 'shadow'.
-- The full CSS parsing (values, swatches) lives in the C3 parser; this SQL
-- derivation stays deliberately label-only because custom-query rows pass
-- through the generic template pipeline untouched (no per-query JS
-- post-processing). Labels are English on purpose — query output is
-- locale-independent.
--
-- The object-type chips switch SERVER-SIDE (`@chip_param: object_type`) over
-- the whole scope. `_chip_facets` counts over `result` — every filter EXCEPT the search and the
-- object type itself, otherwise each chip would only ever show its own
-- selection — while `_row_total` counts over `filtered`, i.e. WITH that filter, so
-- the header names the truncation and only then.
WITH decls AS (
    -- One row per CSS declaration of a rule. The declaration regex stops at
    -- ';', '}' or end of line, so selector lines ("self:normal .self") come
    -- out as property 'self' and are filtered below. Lambda-free on purpose:
    -- list_filter/list_transform arrow syntax is deprecated in newer DuckDB
    -- and absent in older ones.
    SELECT Rule_UUID,
           Options_Raw AS opts,
           unnest(regexp_extract_all(Local_CSS, '[a-zA-Z-]+\s*:\s*[^;}\n]+', 0)) AS decl
    FROM LayoutObjectConditions
),
fmt AS (
    -- Label per declaration, mirroring the C3 parser semantics: bit-gated
    -- choices yield NULL (= filtered) when their bit is unset; value-carrying
    -- toggles (stretch/transform/glyph) label with the value itself.
    SELECT Rule_UUID,
           array_to_string(list_sort(list_distinct(array_agg(label))), ', ') AS format_desc
    FROM (
        SELECT Rule_UUID,
               CASE prop
                   WHEN 'color'               THEN CASE WHEN (opts & 2) = 2 THEN 'text color' END
                   WHEN 'background-color'    THEN CASE WHEN (opts & 4) = 4 THEN 'fill color' END
                   WHEN 'font-family'         THEN CASE WHEN (opts & 8) = 8 THEN 'font' END
                   WHEN 'font-size'           THEN CASE WHEN (opts & 16) = 16 THEN 'font size' END
                   WHEN '-fm-icon-color'      THEN CASE WHEN (opts & 128) = 128 THEN 'icon color' END
                   WHEN '-fm-highlight-color' THEN 'highlight color'
                   WHEN 'font-weight'         THEN 'bold'
                   WHEN 'font-style'          THEN 'italic'
                   WHEN '-fm-underline'       THEN CASE val
                                                     WHEN 'word-underline'   THEN 'word underline'
                                                     WHEN 'double-underline' THEN 'double underline'
                                                     ELSE 'underline'
                                                   END
                   WHEN '-fm-strikethrough'   THEN 'strikethrough'
                   WHEN 'font-variant'        THEN 'small caps'
                   WHEN 'font-stretch'        THEN val          -- condensed / expanded
                   WHEN 'text-transform'      THEN val          -- uppercase / lowercase / capitalize
                   WHEN '-fm-glyph-variant'   THEN val          -- superscript / subscript
                   WHEN 'box-shadow'          THEN 'shadow'
                   ELSE prop
               END AS label
        FROM (
            SELECT Rule_UUID, opts,
                   regexp_extract(decl, '^([a-zA-Z-]+)', 1) AS prop,
                   trim(regexp_extract(decl, ':\s*(.*)$', 1)) AS val
            FROM decls
        )
        WHERE prop <> 'self'
          AND NOT (prop = 'box-shadow' AND val = 'none')
    )
    WHERE label IS NOT NULL
    GROUP BY Rule_UUID
),
result AS MATERIALIZED (
    SELECT
        loc.File_Name AS file_name,
        ly.L_UUID AS _nav_uuid,
        ly.L_Name AS layout_name,
        lo.Object_Type AS object_type,
        COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)') AS object_name,
        loc.Rule_Index AS condition_no,
        CASE WHEN (loc.Options_Raw & 1) = 1 THEN 'yes' ELSE 'no' END AS active,
        CASE WHEN loc.Condition_Kind = 'value' THEN
            CASE loc.Condition_Type
                WHEN 1 THEN 'between'
                WHEN 2 THEN 'not between'
                WHEN 3 THEN 'equal to'
                WHEN 4 THEN 'not equal to'
                WHEN 5 THEN 'greater than'
                WHEN 6 THEN 'less than'
                WHEN 7 THEN 'greater than or equal to'
                WHEN 8 THEN 'less than or equal to'
                WHEN 9 THEN 'contains'
                WHEN 10 THEN 'does not contain'
                WHEN 11 THEN 'begins with'
                WHEN 12 THEN 'ends with'
                WHEN 13 THEN 'empty'
                ELSE 'value (type ' || loc.Condition_Type || ')'
            END
        END AS operator,
        CASE WHEN loc.Condition_Kind = 'value'
             THEN NULLIF(concat_ws(' … ', loc.Range_Start, loc.Range_End), '')
        END AS operands,
        replace(loc.Calc_Text, chr(10), ' ') AS condition_calc,
        -- A rule whose ONLY declaration is `box-shadow: none` would end up
        -- empty after the noise filter — fall back to 'shadow' there, the
        -- rule genuinely touches nothing else.
        COALESCE(NULLIF(f.format_desc, ''),
                 CASE WHEN loc.Local_CSS LIKE '%box-shadow%' THEN 'shadow' ELSE '' END) AS "format",
        lo.Object_Type || ' ' || COALESCE(NULLIF(trim(lo.Object_Name), ''), '(unnamed)')
          || ' — condition ' || loc.Rule_Index || ' when '
          || COALESCE(NULLIF(replace(loc.Calc_Text, chr(10), ' '), ''), '(no formula)')
          || CASE WHEN (loc.Options_Raw & 1) = 1 THEN '' ELSE ' (disabled)' END AS _message,
        loc.Object_UUID AS _object_uuid
    FROM LayoutObjectConditions loc
    JOIN LayoutObjects lo ON loc.Object_UUID = lo.Object_UUID
    JOIN Layouts ly ON loc.Layout_ID = ly.L_ID AND loc.File_Name = ly.File_Name
    LEFT JOIN fmt f ON loc.Rule_UUID = f.Rule_UUID
    WHERE (getvariable('file') IS NULL OR loc.File_Name = getvariable('file'))
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
ORDER BY /*@sort*/ file_name, layout_name, object_name, condition_no, _object_uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
