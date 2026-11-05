-- @template_type: report
-- @title: Error-code inventory
-- @description: Every numeric literal a script compares with Get(LastError), one row per comparison with the documented FileMaker meaning of the code (fm_spec error_codes, fm-spec 2.8.0+; ranges resolve - 5123 shows as 5000-5499) and its scope: core, web (returned only by the web publishing engine or a REST API) or unknown (no row in the reference). Reading aid for the error-handling practice of a solution - which codes are checked, where, how often. The defect slices are the rules "Unknown error-code literal" and "Web-only error-code literal"; this inventory is the neutral overview.
-- @icon: bug
-- @display: table
-- @chip_filter: code
-- @chip_param: code
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 2000
-- @params: file (optional), page (optional), page_size (optional, default 2000), q (optional), sort (optional), dir (optional), code (optional)
-- @click_action: openObject
-- @click_args: uuid={{_nav_uuid}}&type=Script&step={{_step_uuid}}&file={{file_name}}
-- @row_action: openObject
-- @row_action_args: uuid={{_nav_uuid}}&type=Script&step={{_step_uuid}}&file={{file_name}}
-- @row_action_label: Show step
-- @output_format: file_name, script_name, step_no, code, code_text, scope, meaning, status, _message, _chip_facets, _row_total, _page, _page_size
-- @object_types: Script
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "error_code_comparisons", "meaning": "Comparisons of Get(LastError) with a numeric literal in scope (inventory - not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: scripts, errors, error-codes, inventory
--
-- Same literal extraction as the two error-code rules: one regex built from the
-- reference (every spelling of Get(LastError) in 11 locales + comparison
-- operator + numeric literal) over StepCalculations.Calc_Text - plain text,
-- never *_XML; literals have no ObjectLinks edge, so this is the only source.
-- Case/Choose forms and reversed comparisons (0 = Get(LastError)) stay out of
-- scope by design. The chip key is the literal; `_chip_facets` counts over
-- `result` (every filter except the search and the code), `_row_total` over `filtered`.
WITH
-- One regex from the reference: every spelling of Get(LastError) the reference
-- knows (11 locales, Get keyword and parameter name; 'Hole ( LetzteFehlerNr )'
-- included; longest spelling first, so a prefix never shadows a longer one),
-- followed by a comparison operator and a numeric literal. Literals
-- are not resolved in ObjectLinks, so the calc text (StepCalculations.Calc_Text,
-- plain text - never *_XML) is the only source; Case/Choose forms and reversed
-- comparisons (0 = Get(LastError)) are deliberately out of scope.
pattern AS (
    SELECT '(?i)(?:' || (SELECT string_agg(DISTINCT regexp_extract(lookup_name, '^([^\s(]+)', 1), '|' ORDER BY length(regexp_extract(lookup_name, '^([^\s(]+)', 1)) DESC, regexp_extract(lookup_name, '^([^\s(]+)', 1))
                          FROM ref.function_name_lookup WHERE function_id = 139 AND chunk_role = 'getfunction')
        || ')\s*\(\s*(?:' || (SELECT string_agg(DISTINCT lookup_name, '|' ORDER BY length(lookup_name) DESC, lookup_name)
                                 FROM ref.function_name_lookup WHERE function_id = 139 AND chunk_role = 'getparameter')
        || ')\s*\)\s*(?:=|≠|<>|<=|>=|≤|≥|<|>)\s*(-?\d+)' AS re
),
literals AS (
    SELECT s.File_Name, s.Script_UUID, s.Script_Name, s.Step_Index, s.Step_UUID, s.Step_ID,
           CAST(u.lit AS INTEGER) AS literal
    FROM StepCalculations s, pattern p,
         UNNEST(regexp_extract_all(s.Calc_Text, p.re, 1)) AS u(lit)
    WHERE s.Is_Enabled
      AND s.Calc_Text IS NOT NULL
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
result AS MATERIALIZED (
    SELECT l.File_Name AS file_name, l.Script_Name AS script_name, l.Step_Index + 1 AS step_no,
           l.literal AS code, COALESCE(e.code_text, CAST(l.literal AS VARCHAR)) AS code_text,
           COALESCE(e.scope, 'unknown') AS scope,
           COALESCE(e.message_en, '(not a documented FileMaker error code)') AS meaning,
           CASE WHEN e.code_from IS NULL THEN 'unknown' ELSE e.scope END AS status,
           l.Script_Name || ' step ' || (l.Step_Index + 1) || ' - Get(LastError) compared with ' || l.literal AS _message,
           l.Script_UUID AS _nav_uuid, l.Step_UUID AS _step_uuid
    FROM literals l
    LEFT JOIN ref.error_codes e ON l.literal BETWEEN e.code_from AND e.code_to
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
    WHERE (getvariable('code') IS NULL OR CAST(code AS VARCHAR) = getvariable('code'))
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 2000), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    -- Facets ordered by value, so every request returns the same text.
    (SELECT to_json(map_from_entries(list((CAST(code AS VARCHAR), n) ORDER BY code)))
       FROM (SELECT code, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ file_name, script_name, step_no, code, _step_uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
