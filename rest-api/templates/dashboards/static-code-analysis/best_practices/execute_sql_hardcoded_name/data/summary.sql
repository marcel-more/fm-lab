-- Hand-maintained COUNT wrapper of rule execute_sql_hardcoded_name — keep the finding
-- condition in sync with data/findings.sql.
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
flagged AS (
    SELECT *, (Resolution = 'name' AND Target_Type IN ('Field', 'TableOccurrence')) AS is_hit
    FROM scoped
)
SELECT
    CAST(count(*) FILTER (WHERE is_hit) AS INTEGER) AS finding_count,
    'info' AS severity,
    CAST(count(DISTINCT File_Name) FILTER (WHERE is_hit) AS INTEGER) AS affected_files,
    CAST(count(DISTINCT Target_UUID || '@' || Target_File) FILTER (WHERE is_hit AND Target_Type = 'Field') AS INTEGER) AS field_count,
    CAST(count(DISTINCT Target_UUID || '@' || Target_File) FILTER (WHERE is_hit AND Target_Type = 'TableOccurrence') AS INTEGER) AS to_count
FROM flagged;
