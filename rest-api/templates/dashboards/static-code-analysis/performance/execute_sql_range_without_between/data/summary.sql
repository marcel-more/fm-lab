-- Hand-maintained COUNT wrapper embedding the findings core of rule
-- (execute_sql_range_without_between). The core is a textual copy — keep the
-- detection (candidate regex, literal extraction, operator test) and the
-- filters (file filter + S-Block) in sync with data/findings.sql.
--
-- Beyond the standard KPIs this summary counts the scope's Execute(File)SQL
-- population (`execsql_total`) and how many of those already use BETWEEN
-- (`between_count`) — context for the finding counter.
WITH sql_calcs AS (
    SELECT
        c.Owner_UUID,
        c.Owner_Type,
        c.File_Name,
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
resolved AS (
    SELECT
        h.File_Name,
        COALESCE(s.Script_UUID, h.Owner_UUID) AS nav_uuid,
        (h.str_literals LIKE '%>=%' AND h.str_literals LIKE '%<=%') AS is_hit,
        regexp_matches(h.str_literals, '(?i)[^a-z]between[^a-z]') AS has_between
    FROM sql_calcs h
    LEFT JOIN StepsForScripts s
      ON h.Owner_Type = 'ScriptStep' AND h.Owner_UUID = s.Step_UUID
),
scoped AS (
    SELECT *
    FROM resolved
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
)
SELECT
    CAST(count(*) FILTER (WHERE is_hit) AS INTEGER) AS finding_count,
    'info' AS severity,
    CAST(count(DISTINCT File_Name) FILTER (WHERE is_hit) AS INTEGER) AS affected_files,
    CAST(count(*) AS INTEGER) AS execsql_total,
    CAST(count(*) FILTER (WHERE has_between) AS INTEGER) AS between_count
FROM scoped;
