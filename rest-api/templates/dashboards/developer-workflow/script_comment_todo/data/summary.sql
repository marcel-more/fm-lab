-- Hand-maintained wrapper around the rule core (script_comment_todo).
-- Keep the detector and the filters in sync with data/findings.sql.
SELECT
    COUNT(*) AS finding_count,
    COUNT(DISTINCT s.Script_UUID) AS affected_scripts,
    COUNT(DISTINCT s.File_Name) AS affected_files
FROM StepsForScripts s
WHERE s.Step_ID = 89
  AND s.Comment_Text IS NOT NULL
  AND regexp_matches(s.Comment_Text, '(?i)(\bto[\s\-_]?do|\btbd\b|\bto[\s\-_]be[\s\-_](done|defined)\b)')
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))));
