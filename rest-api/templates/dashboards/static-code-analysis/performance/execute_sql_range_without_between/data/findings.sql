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
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
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
          || ' bounds a range with >= and <= instead of BETWEEN: ' || sql_excerpt AS message
    FROM resolved
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file_name, u.object_name, u.step_no, u) AS row_key
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
