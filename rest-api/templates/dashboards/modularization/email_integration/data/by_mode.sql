-- @template_type: report
-- @description: Aggregat des E-Mail-Versands nach Versandweg (SMTP / Client / MBS / unknown). Klick auf eine Zeile filtert die Fundstellen-Liste.
-- @params: file (optional), limit (optional, default 20)

WITH native AS (
    SELECT s.File_Name AS file,
        CASE
            WHEN ddr.Step_Text LIKE '%Send via SMTP Server%'  THEN 'SMTP'
            WHEN ddr.Step_Text LIKE '%Send via E-mail Client%' THEN 'Client'
            ELSE 'unknown'
        END AS mode,
        (COALESCE(ddr.Step_Text,'') LIKE '%Password:%') AS hardcoded_auth
    FROM StepsForScripts s
    LEFT JOIN DDR_ScriptSteps ddr ON s.Step_UUID = ddr.Step_UUID AND ddr.File_Name = s.File_Name
    WHERE s.Step_ID = 63
),
mbs AS (
    SELECT p.File_Name AS file, 'MBS' AS mode, FALSE AS hardcoded_auth
    FROM PluginFunctionUsages p
    WHERE regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(SendMail|EmailParser)\.')
),
all_hits AS (SELECT * FROM native UNION ALL SELECT * FROM mbs)
SELECT
    mode,
    COUNT(*)                                     AS callsites,
    COUNT(DISTINCT file)                          AS files,
    COUNT(*) FILTER (WHERE hardcoded_auth)        AS with_hardcoded_auth
FROM all_hits
WHERE (getvariable('file') IS NULL OR file = getvariable('file'))
GROUP BY mode
ORDER BY callsites DESC
LIMIT CAST(COALESCE(getvariable('limit'), '20') AS INTEGER);
