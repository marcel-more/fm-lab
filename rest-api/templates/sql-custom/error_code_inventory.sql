-- @template_type: report
-- @title: Error-code inventory
-- @description: Every numeric literal a script compares with Get(LastError), one row per comparison with the documented FileMaker meaning of the code (fm_spec error_codes, fm-spec 2.8.0+; ranges resolve - 5123 shows as 5000-5499) and its scope: core, web (returned only by the web publishing engine or a REST API) or unknown (no row in the reference). Reading aid for the error-handling practice of a solution - which codes are checked, where, how often. The defect slices are the rules "Unknown error-code literal" and "Web-only error-code literal"; this inventory is the neutral overview.
-- @icon: bug
-- @category: Scripts
-- @display: table
-- @chip_filter: code
-- @chip_param: code
-- @params: file (optional), limit (optional, default 2000), code (optional)
-- @click_action: openObject
-- @click_args: uuid={{_nav_uuid}}&type=Script&step={{_step_uuid}}&file={{file_name}}
-- @row_action: openObject
-- @row_action_args: uuid={{_nav_uuid}}&type=Script&step={{_step_uuid}}&file={{file_name}}
-- @row_action_label: Show step
-- @output_format: file_name, script_name, step_no, code, code_text, scope, meaning, status, _message, _chip_facets, _row_total
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
-- `base` (every filter except the code), `_row_total` over `sel`.
WITH
-- One regex from the reference: every spelling of Get(LastError) the reference
-- knows (11 locales, Get keyword and parameter name; 'Hole ( LetzteFehlerNr )'
-- included), followed by a comparison operator and a numeric literal. Literals
-- are not resolved in ObjectLinks, so the calc text (StepCalculations.Calc_Text,
-- plain text - never *_XML) is the only source; Case/Choose forms and reversed
-- comparisons (0 = Get(LastError)) are deliberately out of scope.
pattern AS (
    SELECT '(?i)(?:' || (SELECT string_agg(DISTINCT regexp_extract(lookup_name, '^([^\s(]+)', 1), '|')
                          FROM ref.function_name_lookup WHERE function_id = 139 AND chunk_role = 'getfunction')
        || ')\s*\(\s*(?:' || (SELECT string_agg(DISTINCT lookup_name, '|')
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
base AS (
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
sel AS (
    SELECT * FROM base
    WHERE (getvariable('code') IS NULL OR CAST(code AS VARCHAR) = getvariable('code'))
)
SELECT s.*,
    (SELECT json_group_object(CAST(code AS VARCHAR), n)
       FROM (SELECT code, count(*) AS n FROM base GROUP BY 1)) AS _chip_facets,
    (SELECT count(*) FROM sel) AS _row_total
FROM sel s
ORDER BY file_name, script_name, step_no, code
LIMIT CAST(COALESCE(getvariable('limit'), '2000') AS INTEGER);
