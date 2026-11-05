-- @template_type: report
-- @description: KPI-Übersicht der Prozess-/Shell-Ausführung — Grenzübertritte gesamt, Send Event, AppleScript, MBS-Prozessaufrufe, betroffene Dateien.
-- @params: file (optional)

WITH native AS (
    SELECT s.File_Name AS file,
        CASE WHEN s.Step_ID = 57 THEN 'Send Event' ELSE 'AppleScript' END AS mechanism
    FROM StepsForScripts s WHERE s.Step_ID IN (57, 67)
),
mbs AS (
    SELECT src.File_Name AS file, 'MBS' AS mechanism
    FROM ObjectLinks ol
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID AND tgt.File_Name IS NOT DISTINCT FROM ol.Target_File
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID AND src.File_Name = ol.Source_File
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND regexp_matches(tgt.Object_Name, '(?i)MBS:(Shell|RunTask|Process)\.')
),
all_hits AS (SELECT * FROM native UNION ALL SELECT * FROM mbs),
filtered AS (SELECT * FROM all_hits WHERE (getvariable('file') IS NULL OR file = getvariable('file')))
SELECT
    COUNT(*)                                            AS touchpoints,
    COUNT(*) FILTER (WHERE mechanism = 'Send Event')    AS send_event,
    COUNT(*) FILTER (WHERE mechanism = 'AppleScript')   AS applescript,
    COUNT(*) FILTER (WHERE mechanism = 'MBS')           AS mbs_calls,
    COUNT(DISTINCT file)                                AS files_affected
FROM filtered;
