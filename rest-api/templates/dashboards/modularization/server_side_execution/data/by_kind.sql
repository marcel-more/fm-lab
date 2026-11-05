-- @template_type: report
-- @description: Aggregat der serverseitigen Ausführungs-Mechanismen. Klick auf eine Zeile filtert die Fundstellen-Liste.
-- @params: file (optional), limit (optional, default 20)

SELECT
    CASE s.Step_ID
        WHEN 164 THEN 'Perform Script on Server'
        WHEN 203 THEN 'Execute FileMaker Data API'
        WHEN 148 THEN 'Install OnTimer Script'
    END                                                 AS mechanism,
    COUNT(*)                                             AS callsites,
    COUNT(DISTINCT s.File_Name)                          AS files,
    COUNT(DISTINCT s.Script_UUID)                        AS scripts
FROM StepsForScripts s
WHERE s.Step_ID IN (164, 203, 148)
  AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
GROUP BY mechanism
ORDER BY callsites DESC
LIMIT CAST(COALESCE(getvariable('limit'), '20') AS INTEGER);
