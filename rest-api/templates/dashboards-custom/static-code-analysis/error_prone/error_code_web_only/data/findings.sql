-- Web-only error-code literal: numeric literals compared with Get(LastError)
-- whose code carries scope 'web' (marked (*) by Claris: web publishing engine / REST API).
-- Source: reference/fm_spec.duckdb -> error_codes (fm_spec >= 2.8.0), ATTACHed as
-- 'ref' by the API connection; the fm-test direct path attaches it itself.
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
)
SELECT 'error-code-web-only' AS rule_id, 'info' AS severity,
    l.File_Name AS file_name, l.Script_UUID AS nav_uuid, l.Script_Name AS script_name,
    l.Step_Index + 1 AS step_no, l.Step_UUID AS step_uuid,
    l.literal AS literal, e.code_text AS code_text, e.scope AS scope, e.message_en AS code_message,
    'Get(LastError) is compared with ' || l.literal || ' (' || e.message_en || ') - a code returned only by the web publishing engine or a FileMaker REST API' AS message,
    row_number() OVER (ORDER BY l.File_Name, l.Script_Name, l.Step_Index, l.literal) AS row_key
FROM literals l
LEFT JOIN ref.error_codes e ON l.literal BETWEEN e.code_from AND e.code_to
WHERE e.scope = 'web'
ORDER BY file_name, script_name, step_no
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
