-- Hand-maintained COUNT wrapper embedding the findings core of rule
-- (plugin_function_missing_export). Keep filters (file filter + scope block)
-- in sync with data/findings.sql. SUM() yields HUGEINT — cast to BIGINT.
WITH calc AS (
    SELECT c.Owner_UUID, c.File_Name,
           (length(c.Formula_Text) - length(replace(c.Formula_Text, '<Function Missing>', '')))
             // length('<Function Missing>') AS missing_count
    FROM CalculationsCatalog c
    WHERE c.Formula_Text LIKE '%<Function Missing>%'
),
owner AS (
    SELECT k.*, COALESCE(s.Script_UUID, k.Owner_UUID) AS nav_uuid
    FROM calc k
    LEFT JOIN StepsForScripts s ON s.Step_UUID = k.Owner_UUID AND s.File_Name = k.File_Name
)
SELECT
    COUNT(*) AS finding_count,
    'warning' AS severity,
    CAST(COALESCE(SUM(o.missing_count), 0) AS BIGINT) AS placeholders,
    COUNT(DISTINCT o.nav_uuid) AS affected_objects,
    COUNT(DISTINCT o.File_Name) AS affected_files
FROM owner o
WHERE (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR o.nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
