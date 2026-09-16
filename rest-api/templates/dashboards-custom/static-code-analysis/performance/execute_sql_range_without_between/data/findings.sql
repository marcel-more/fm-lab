-- ExecuteSQL calculations whose SQL builds a range with >=/<= instead of
-- BETWEEN. Covers native ExecuteSQL/ExecuteSQLe and the MBS variants
-- (FM.ExecuteSQL, FM.ExecuteFileSQL, ...OnIdle) via the shared name stem.
--
-- The operators are searched ONLY inside the formula's double-quoted string
-- literals (where the SQL text lives, FM escape \" skipped) — comparison
-- operators in the surrounding FileMaker calculation must not count.
-- Same-column matching is deliberately NOT a filter: RE2 has no backreferences,
-- and in dynamically composed SQL the column name is a function result, not a
-- literal. Co-occurrence of >= and <= in the literals is the validated signal.
--
-- ScriptStep owners resolve to their parent script for navigation; all other
-- owners (Field, CustomFunction, LayoutObject, ...) navigate directly.
WITH sql_calcs AS (
    SELECT
        c.Owner_UUID,
        c.Owner_Type,
        c.Owner_Name,
        c.File_Name,
        c.Formula_Text,
        regexp_replace(
            list_aggregate(
                regexp_extract_all(c.Formula_Text, '"((?:\\.|[^"\\])*)"', 1),
                'string_agg', ' '
            ),
            '\s+', ' ', 'g'
        ) AS str_literals
    FROM CalculationsCatalog c
    WHERE regexp_matches(c.Formula_Text, '(?i)execute(file)?sql')
),
hits AS (
    SELECT *
    FROM sql_calcs
    WHERE str_literals LIKE '%>=%' AND str_literals LIKE '%<=%'
),
resolved AS (
    SELECT
        h.File_Name,
        COALESCE(s.Script_UUID, h.Owner_UUID) AS nav_uuid,
        CASE WHEN h.Owner_Type = 'ScriptStep' THEN 'Script' ELSE h.Owner_Type END AS nav_type,
        COALESCE(s.Script_Name, h.Owner_Name) AS object_name,
        CASE WHEN h.Owner_Type = 'ScriptStep' THEN s.Step_Index + 1 END AS step_no,
        CASE WHEN h.Owner_Type = 'ScriptStep' THEN s.Step_UUID END AS step_uuid,
        regexp_extract(h.Formula_Text, '(?i)((fm\.)?execute(file)?sql[a-z]*)', 1) AS sql_function,
        replace(
            substr(
                h.str_literals,
                greatest(1, strpos(h.str_literals, '>=') - 60),
                160
            ),
            '\"', '"'
        ) AS sql_excerpt
    FROM hits h
    LEFT JOIN StepsForScripts s
      ON h.Owner_Type = 'ScriptStep' AND h.Owner_UUID = s.Step_UUID
)
SELECT
    'execute-sql-range-without-between' AS rule_id,
    'info' AS severity,
    File_Name AS file_name,
    nav_uuid,
    nav_type,
    object_name,
    CAST(step_no AS INTEGER) AS step_no,
    step_uuid,
    sql_function,
    sql_excerpt,
    COALESCE(sql_function, 'ExecuteSQL') || ' in ' || object_name
      || CASE WHEN step_no IS NOT NULL THEN ' at step ' || step_no ELSE '' END
      || ' bounds a range with >= and <= instead of BETWEEN: ' || sql_excerpt AS message,
    row_number() OVER (ORDER BY File_Name, object_name, step_no) AS row_key
FROM resolved
WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY file_name, object_name, step_no
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
