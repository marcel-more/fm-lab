-- Unknown error-code literal: numeric literals compared with Get(LastError)
-- that no row of the FileMaker error-code table covers (ranges included: 5123 is covered by 5000-5499).
-- Source: reference/fm_spec.duckdb -> error_codes (fm_spec >= 2.8.0), ATTACHed as
-- 'ref' by the API connection; the fm-test direct path attaches it itself.
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
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'error-code-unknown-literal' AS rule_id, 'warning' AS severity,
        l.File_Name AS file_name, l.Script_UUID AS nav_uuid, l.Script_Name AS script_name,
        l.Step_Index + 1 AS step_no, l.Step_UUID AS step_uuid,
        l.literal AS literal, e.code_text AS code_text, e.scope AS scope, e.message_en AS code_message,
        'Get(LastError) is compared with ' || l.literal || ', a code the FileMaker error-code table does not list - a typo, a plug-in code, or a custom code outside 5000-5499' AS message
    FROM literals l
    LEFT JOIN ref.error_codes e ON l.literal BETWEEN e.code_from AND e.code_to
    WHERE e.code_from IS NULL
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file_name, u.script_name, u.step_no, u) AS row_key
    FROM unkeyed u
),
-- >>> shared paging table-search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) NOT IN ('uuid', 'nav_uuid', 'row_key')))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging table-search block
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
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
