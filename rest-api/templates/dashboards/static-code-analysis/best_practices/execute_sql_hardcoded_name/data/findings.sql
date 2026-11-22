-- ExecuteSQL with hard-coded name — rule execute_sql_hardcoded_name.
-- Source: CalculationSqlRefs (schema 1.42.0), one row per reference of an
-- ExecuteSQL / ExecuteSQLe statement. ScriptStep owners navigate to their script.
WITH refs AS (
    SELECT r.*, c.Owner_Type, c.Owner_UUID, c.Owner_Name
    FROM CalculationSqlRefs r
    JOIN CalculationsCatalog c
      ON c.Calculation_UUID = r.Calculation_UUID AND c.File_Name = r.File_Name
),
resolved AS (
    SELECT r.*,
           CASE WHEN r.Owner_Type = 'ScriptStep' THEN COALESCE(s.Script_UUID, r.Owner_UUID) ELSE r.Owner_UUID END AS nav_uuid,
           CASE WHEN r.Owner_Type = 'ScriptStep' THEN 'Script' ELSE r.Owner_Type END AS nav_type,
           COALESCE(s.Script_Name, r.Owner_Name) AS object_name,
           CASE WHEN r.Owner_Type = 'ScriptStep' THEN s.Step_Index + 1 END AS step_no,
           CASE WHEN r.Owner_Type = 'ScriptStep' THEN s.Step_UUID END AS step_uuid
    FROM refs r
    LEFT JOIN StepsForScripts s
      ON r.Owner_Type = 'ScriptStep' AND s.Step_UUID = r.Owner_UUID AND s.File_Name = r.File_Name
),
scoped AS (
    SELECT *
    FROM resolved
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
named AS (
    SELECT s.*,
           CASE WHEN s.Target_Type = 'Field' THEN COALESCE(toc.TO_Name || '::', '') || f.Field_Name
                WHEN s.Target_Type = 'TableOccurrence' THEN tt.TO_Name END AS target_name
    FROM scoped s
    LEFT JOIN TableOccurrenceCatalog toc ON toc.TO_UUID = s.TO_UUID AND toc.File_Name = s.File_Name
    LEFT JOIN FieldsForTables f ON f.Field_UUID = s.Target_UUID AND f.File_Name = s.Target_File
    LEFT JOIN TableOccurrenceCatalog tt ON s.Target_Type = 'TableOccurrence'
          AND tt.TO_UUID = s.Target_UUID AND tt.File_Name = s.Target_File
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'execute-sql-hardcoded-name' AS rule_id,
        'info' AS severity,
        File_Name AS file_name,
        nav_uuid,
        nav_type,
        object_name,
        CAST(step_no AS INTEGER) AS step_no,
        step_uuid,
        Sql_Function AS sql_function,
        Clause AS clause,
        Raw_Name AS raw_name,
        target_name,
        Sql_Function || ' in ' || object_name
          || CASE WHEN step_no IS NOT NULL THEN ' at step ' || step_no ELSE '' END
          || ' names ' || CASE WHEN Target_Type = 'Field' THEN 'field ' ELSE 'table occurrence ' END
          || COALESCE(target_name, Raw_Name) || ' as plain text — a rename breaks the query silently' AS message
    FROM named
    WHERE Resolution = 'name' AND Target_Type IN ('Field', 'TableOccurrence')
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
