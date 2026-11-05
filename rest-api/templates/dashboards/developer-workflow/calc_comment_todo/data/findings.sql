-- TODO markers inside comments of FileMaker calculations. Part of the
-- "Unfinished Work" rule family; the detector is the canon of
-- tools/tests/rules/unfinished_work_detector.sql:
--
--   TODO: (?i)(\bto[\s\-_]?do|\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)
--
-- The TODO family deliberately has NO trailing word boundary — otherwise real
-- markers such as "TO DOs" fall out. The leading \b keeps prose out ("today").
--
-- Severity is info (traffic light: neutral): a TODO is an inventory figure,
-- not a defect. The defect half of the family is calc_comment_fixme.
--
-- The marker only counts INSIDE a comment segment — `//` to end of line or
-- `/* … */`. Without that restriction every string literal "TODO" in a
-- Substitute() would score. Code_Chunks does not help here: its chunk types
-- are NoRef | VariableReference | FunctionRef | CustomFunctionRef | FieldRef —
-- there is no comment type, comments sit inside the NoRef text. So the comment
-- segments are extracted by regex.
-- Known limit: a `//` inside a string literal (a URL) is read as a comment
-- start; a marker behind it would count. Measured on the reference corpus: no
-- such case.
--
-- Formula source is the CalculationsCatalog (single source for all calculation
-- slots); the roles map onto the established five slot values: custom-function
-- bodies, field calculations, auto-enter calculations, validation calculations
-- and script step calculations. Script-step instances anchor at the step
-- (Owner_UUID = Step_UUID) — StepsForScripts contributes the script context.
-- The step slot is by far the largest scan surface (~143k slots on the
-- reference corpus) and still runs in well under a second — it stays in the
-- rule rather than becoming a separate bundle.
--
-- Marker class: TODO only. The defect half of the family is calc_comment_fixme.
WITH slots AS (
    SELECT c.File_Name,
           CASE c.Calc_Role
                WHEN 'custom_function' THEN 'custom_function'
                WHEN 'field_calculation' THEN 'field_calc'
                WHEN 'auto_enter' THEN 'field_autoenter'
                ELSE 'field_validation' END AS slot,
           c.Owner_UUID AS nav_uuid,
           CASE c.Owner_Type WHEN 'CustomFunction' THEN 'CustomFunction' ELSE 'Field' END AS nav_type,
           c.Owner_Name AS context,
           CAST(NULL AS VARCHAR) AS step_uuid, CAST(NULL AS INTEGER) AS step_no,
           COALESCE(c.Formula_Text, c.Display_Text) AS calc
    FROM CalculationsCatalog c
    WHERE c.Calc_Role IN ('custom_function', 'field_calculation', 'auto_enter', 'validation')
    UNION ALL
    SELECT c.File_Name, 'script_step', s.Script_UUID, 'Script',
           s.Script_Name, c.Owner_UUID, s.Step_Index + 1,
           COALESCE(c.Formula_Text, c.Display_Text)
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE c.Calc_Role IN ('step_parameter', 'step_xslt')
),
marked AS (
    SELECT *, list_filter(regexp_extract_all(calc, '(?s)/\*.*?\*/|//[^\n\r]*'),
                          lambda seg: regexp_matches(seg, '(?i)(\bto[\s\-_]?do|\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)')) AS segments
    FROM slots
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'calc-comment-todo' AS rule_id, 'info' AS severity,
        m.File_Name AS file_name,
        m.nav_uuid,
        m.nav_type,
        m.slot,
        m.context,
        m.step_no,
        m.step_uuid,
        m.step_uuid AS marks,
        regexp_extract(m.segments[1], '(?i)(\bto[\s\-_]?do|\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)', 0) AS marker,
        trim(m.segments[1]) AS comment,
        len(m.segments) AS marked_comments,
        CASE m.slot
            WHEN 'custom_function'  THEN 'TODO marker in a custom-function comment'
            WHEN 'field_calc'       THEN 'TODO marker in a field calculation comment'
            WHEN 'field_autoenter'  THEN 'TODO marker in an auto-enter calculation comment'
            WHEN 'field_validation' THEN 'TODO marker in a validation calculation comment'
            ELSE 'TODO marker in a script step calculation comment'
        END AS message,
           m.File_Name AS _ord_1,
           m.slot AS _ord_2,
           m.context AS _ord_3,
           m.step_no AS _ord_4
    FROM marked m
    WHERE len(m.segments) > 0
      AND (getvariable('file') IS NULL OR m.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR m.nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u) AS row_key
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
