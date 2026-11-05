-- @template_type: report
-- @description: KPI-Übersicht des E-Mail-Versands — Send-Mail-Steps gesamt, davon SMTP vs. Client, hartkodierte SMTP-Zugangsdaten (sicherheitsrelevant), MBS-Mail-Aufrufe, betroffene Dateien.
-- @params: file (optional)

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
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),
mbs AS (
    SELECT p.File_Name AS file
    FROM PluginFunctionUsages p
    WHERE regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(SendMail|EmailParser)\.')
      AND (getvariable('file') IS NULL OR p.File_Name = getvariable('file'))
)
SELECT
    (SELECT COUNT(*) FROM native)                                        AS send_mail_steps,
    (SELECT COUNT(*) FROM native WHERE mode = 'SMTP')                    AS via_smtp,
    (SELECT COUNT(*) FROM native WHERE mode = 'Client')                  AS via_client,
    (SELECT COUNT(*) FROM native WHERE hardcoded_auth)                   AS hardcoded_credentials,
    (SELECT COUNT(*) FROM mbs)                                           AS mbs_mail_calls,
    (SELECT COUNT(DISTINCT file) FROM (SELECT file FROM native UNION ALL SELECT file FROM mbs)) AS files_affected;
