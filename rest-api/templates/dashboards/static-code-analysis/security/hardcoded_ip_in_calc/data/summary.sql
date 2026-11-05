-- Hand-maintained COUNT wrapper embedding the findings core of rule (hardcoded_ip_in_calc).
-- The core is a textual copy — keep filters (file filter + comment stripping)
-- in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'warning'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
WITH hit AS (
    SELECT c.File_Name, c.Owner_UUID, c.Owner_Type,
        regexp_replace(
            regexp_replace(COALESCE(c.Formula_Text, c.Display_Text), '(?s)/\*.*?\*/', ' ', 'g'),
            '(?m)(^|[^:])//[^\n\r]*', '\1', 'g') AS active_text
    FROM CalculationsCatalog c
    WHERE (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
)
SELECT h.File_Name AS file_name
FROM hit h
WHERE regexp_matches(h.active_text, '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
) _summary;
