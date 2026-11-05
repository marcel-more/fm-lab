-- Hand-maintained COUNT wrapper for rule (multi_navigation_without_freeze).
-- Keep filters (threshold + file filter + scope block) in sync with
-- data/findings.sql.
WITH nav AS (
    SELECT File_Name, Script_UUID,
           CAST(count(*) FILTER (WHERE Step_ID IN (6, 74)) AS INTEGER) AS nav_steps,
           count(*) FILTER (WHERE Step_ID = 79) AS freeze_steps
    FROM StepsForScripts
    WHERE Is_Enabled
    GROUP BY 1, 2
)
SELECT
    COUNT(*) AS finding_count,
    'info' AS severity,
    CAST(max(nav_steps) AS INTEGER) AS max_nav_steps,
    COUNT(DISTINCT File_Name) AS affected_files
FROM nav
WHERE freeze_steps = 0
  AND nav_steps >= CAST(COALESCE(getvariable('min_nav'), '3') AS INTEGER)
  AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
