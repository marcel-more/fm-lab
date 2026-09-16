-- Hand-maintained COUNT wrapper embedding the findings core of rule (error_code_unknown_literal).
-- The core is a textual copy - keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*) AS finding_count,
    COUNT(DISTINCT literal) AS distinct_codes,
    COUNT(DISTINCT nav_uuid) AS script_count,
    COUNT(DISTINCT file_name) AS affected_files
FROM (
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
SELECT 'error-code-unknown-literal' AS rule_id, 'warning' AS severity,
    l.File_Name AS file_name, l.Script_UUID AS nav_uuid, l.Script_Name AS script_name,
    l.Step_Index + 1 AS step_no, l.Step_UUID AS step_uuid,
    l.literal AS literal, e.code_text AS code_text, e.scope AS scope, e.message_en AS code_message,
    'Get(LastError) is compared with ' || l.literal || ', a code the FileMaker error-code table does not list - a typo, a plug-in code, or a custom code outside 5000-5499' AS message,
    row_number() OVER (ORDER BY l.File_Name, l.Script_Name, l.Step_Index, l.literal) AS row_key
FROM literals l
LEFT JOIN ref.error_codes e ON l.literal BETWEEN e.code_from AND e.code_to
WHERE e.code_from IS NULL
) _summary;
