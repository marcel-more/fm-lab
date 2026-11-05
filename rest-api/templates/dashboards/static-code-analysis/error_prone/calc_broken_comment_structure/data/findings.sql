-- Formulas whose comment markers cannot nest. FileMaker comments do not nest,
-- so a second /* inside an open comment, a stray */ after the block was already
-- closed, or a // line comment glued to an opening /* leaves the parser in a
-- state the author did not intend — parts of the formula are silently inside or
-- outside the comment. Translated from fmCheckMate CommentedOut.
--
-- Same calculation slots as the commented-out-formula rule, so both cover the
-- catalog identically. Formula source is the CalculationsCatalog (single
-- source for all calculation slots); script-step instances anchor at the step
-- (Owner_UUID = Step_UUID) — StepsForScripts contributes the script context.
WITH slots AS (
    SELECT c.File_Name, c.Owner_UUID AS nav_uuid,
           CASE c.Owner_Type WHEN 'CustomFunction' THEN 'CustomFunction' ELSE 'Field' END AS object_type,
           c.Owner_Name AS object_name,
           CASE c.Calc_Role
                WHEN 'custom_function' THEN 'custom-function'
                WHEN 'field_calculation' THEN 'field-calculation'
                WHEN 'auto_enter' THEN 'auto-enter'
                ELSE 'validation' END AS calc_slot,
           CAST(NULL AS VARCHAR) AS step_uuid, CAST(NULL AS INTEGER) AS step_no,
           CAST(NULL AS VARCHAR) AS step_slot,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc_text
    FROM CalculationsCatalog c
    WHERE c.Calc_Role IN ('custom_function', 'field_calculation', 'auto_enter', 'validation')
    UNION ALL
    SELECT c.File_Name, s.Script_UUID, 'Script', s.Script_Name,
           'script-step', c.Owner_UUID, s.Step_Index + 1,
           substr(c.Source_Path, 6),
           COALESCE(c.Formula_Text, c.Display_Text)
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE c.Calc_Role IN ('step_parameter', 'step_xslt')
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'calc-broken-comment-structure' AS rule_id, 'warning' AS severity,
        s.File_Name AS file_name, s.nav_uuid, s.object_type, s.object_name,
        s.calc_slot,
        CASE WHEN s.step_no IS NULL THEN '' ELSE 'Step ' || s.step_no || ' · ' || s.step_slot END AS location,
        s.step_uuid,
        CASE WHEN s.calc_text LIKE '%/*/*%' THEN 'nested-open'
             WHEN s.calc_text LIKE '%*/*/%' THEN 'double-close'
             ELSE 'line-in-block' END AS defect,
        'Comment markers cannot nest — ' || replace(substr(trim(s.calc_text), 1, 120), chr(10), ' ') AS message,
           s.File_Name AS _ord_1,
           s.object_type AS _ord_2,
           s.object_name AS _ord_3,
           s.calc_slot AS _ord_4,
           s.step_no AS _ord_5
    FROM slots s
    WHERE (s.calc_text LIKE '%/*/*%' OR s.calc_text LIKE '%*/*/%' OR s.calc_text LIKE '%/*//%')
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4, _ord_5),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u._ord_5, u) AS row_key
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
