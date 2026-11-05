-- @template_type: report
-- @description: Aggregat api_group × operation — Grundlage der Gruppen-Matrix. Nutzt exakt dieselbe Klassifikations-CTE wie findings.sql (Step_ID-Gruppen + MBS-Funktions-Muster synchron halten). Klick auf eine Zeile filtert die Detailliste.
-- @params: file (optional), limit (optional, default 60)
--
-- KLASSIFIKATION — dieselbe CASE-Logik wie in findings.sql. Beide Dateien synchron halten.

WITH native AS (
    SELECT
        s.File_Name AS file,
        CASE
            WHEN s.Step_ID IN (190,192)                 THEN 'write'
            WHEN s.Step_ID = 193                        THEN 'read'
            WHEN s.Step_ID IN (191,194,195,196,199)     THEN 'manage'
            WHEN s.Step_ID = 197                        THEN 'delete'
            WHEN s.Step_ID IN (188,189)                 THEN 'probe'
            WHEN s.Step_ID IN (35,131,56,158,159,161)   THEN 'import'
            ELSE                                             'export'
        END AS operation,
        CASE
            WHEN s.Step_ID BETWEEN 188 AND 199          THEN 'Data File API'
            WHEN s.Step_ID IN (35,131,56,158,159,161)   THEN 'Import/Insert'
            ELSE                                             'Export/Save'
        END AS api_group
    FROM StepsForScripts s
    WHERE s.Step_ID IN (190,191,192,193,194,195,196,197,199,188,189,
                        35,131,56,158,159,161,
                        36,132,143,144,152,225,37,3,96)
),
mbs_raw AS (
    -- Per-usage aus PluginFunctionUsages (nicht die deduplizierten
    -- Script→PluginFunction-Links): jede einzelne Call-Site zählt, konsistent
    -- mit der Fundstellen-Liste in findings.sql.
    SELECT
        p.File_Name AS file,
        regexp_extract(p.Plugin_Function_Name, '(?i)MBS:([A-Za-z]+)\.', 1)             AS component,
        regexp_extract(p.Plugin_Function_Name, '(?i)MBS:[A-Za-z]+\.([A-Za-z0-9]+)', 1) AS fn
    FROM PluginFunctionUsages p
    WHERE (regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(Files|Path|Folders|FileDialog)\.')
        OR regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(Text)\.(Read|Write|Append)TextFile')
        OR regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(Container)\.(Export|ReadFile|WriteFile)'))
),
mbs AS (
    SELECT
        file,
        CASE
            WHEN component ILIKE 'Files' AND (fn ILIKE 'Read%' OR fn ILIKE 'List%')            THEN 'read'
            WHEN component ILIKE 'Files' AND fn IN ('CopyFile','CreateDirectory','RenameFile','MoveFile') THEN 'write'
            WHEN component ILIKE 'Files' AND (fn ILIKE 'Delete%' OR fn ILIKE 'MoveToTrash%')   THEN 'delete'
            WHEN component ILIKE 'Files' AND (fn LIKE '%Exists' OR fn LIKE '%Size' OR fn LIKE '%Date') THEN 'probe'
            WHEN component ILIKE 'Files' AND (fn ILIKE 'Launch%' OR fn ILIKE 'Reveal%')        THEN 'launch'
            WHEN component ILIKE 'Files' AND (fn ILIKE 'Mount%' OR fn ILIKE 'Unmount%')        THEN 'mount'
            WHEN component ILIKE 'Text'  AND fn ILIKE 'Read%'                                  THEN 'read'
            WHEN component ILIKE 'Text'  AND (fn ILIKE 'Write%' OR fn ILIKE 'Append%')         THEN 'write'
            WHEN component ILIKE 'Container' AND fn ILIKE 'Read%'                              THEN 'read'
            WHEN component ILIKE 'Container'                                                   THEN 'write'
            WHEN component ILIKE 'Path'                                                        THEN 'path'
            WHEN component ILIKE 'Folders'                                                     THEN 'path'
            WHEN component ILIKE 'FileDialog'                                                  THEN 'dialog'
            ELSE 'other'
        END AS operation,
        'MBS ' || component AS api_group
    FROM mbs_raw
),
all_hits AS (
    SELECT file, api_group, operation FROM native
    UNION ALL
    SELECT file, api_group, operation FROM mbs
)
SELECT
    api_group,
    operation,
    COUNT(*)               AS hits,
    COUNT(DISTINCT file)   AS files
FROM all_hits
WHERE (getvariable('file') IS NULL OR file = getvariable('file'))
GROUP BY api_group, operation
ORDER BY api_group, hits DESC
LIMIT CAST(COALESCE(getvariable('limit'), '60') AS INTEGER);
