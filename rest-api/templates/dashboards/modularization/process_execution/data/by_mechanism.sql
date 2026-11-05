-- @template_type: report
-- @description: Aggregat nach Mechanismus (Send Event / AppleScript / MBS Shell / RunTask / Process). Klick auf eine Zeile filtert die Fundstellen-Liste.
-- @params: file (optional), limit (optional, default 30)

WITH native AS (
    SELECT s.File_Name AS file,
        CASE WHEN s.Step_ID = 57 THEN 'Send Event' ELSE 'AppleScript' END AS mechanism,
        'native' AS kind
    FROM StepsForScripts s WHERE s.Step_ID IN (57, 67)
),
mbs AS (
    SELECT src.File_Name AS file,
        'MBS ' || regexp_extract(tgt.Object_Name, '(?i)MBS:([A-Za-z]+)\.', 1) AS mechanism,
        'mbs' AS kind
    FROM ObjectLinks ol
    JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID AND tgt.File_Name IS NOT DISTINCT FROM ol.Target_File
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID AND src.File_Name = ol.Source_File
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND regexp_matches(tgt.Object_Name, '(?i)MBS:(Shell|RunTask|Process)\.')
),
all_hits AS (SELECT * FROM native UNION ALL SELECT * FROM mbs)
SELECT mechanism, MAX(kind) AS kind, COUNT(*) AS callsites, COUNT(DISTINCT file) AS files
FROM all_hits
WHERE (getvariable('file') IS NULL OR file = getvariable('file'))
GROUP BY mechanism
ORDER BY callsites DESC
LIMIT CAST(COALESCE(getvariable('limit'), '30') AS INTEGER);
