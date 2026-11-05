-- @template_type: report
-- @description: KPI-Übersicht der Dateisystem-Zugriffe — Touchpoints gesamt, kritische (write+delete), betroffene Dateien, MBS-Anteil und native Steps. Gleiche Klassifikations-Basis wie findings/fs_groups.
-- @params: file (optional)

WITH native AS (
    SELECT
        s.File_Name AS file,
        'native' AS source_kind,
        CASE
            WHEN s.Step_ID IN (190,192)                 THEN 'write'
            WHEN s.Step_ID = 193                        THEN 'read'
            WHEN s.Step_ID IN (191,194,195,196,199)     THEN 'manage'
            WHEN s.Step_ID = 197                        THEN 'delete'
            WHEN s.Step_ID IN (188,189)                 THEN 'probe'
            WHEN s.Step_ID IN (35,131,56,158,159,161)   THEN 'import'
            ELSE                                             'export'
        END AS operation
    FROM StepsForScripts s
    WHERE s.Step_ID IN (190,191,192,193,194,195,196,197,199,188,189,
                        35,131,56,158,159,161,
                        36,132,143,144,152,225,37,3,96)
),
mbs_raw AS (
    -- Per-usage aus PluginFunctionUsages (konsistent mit findings/fs_groups).
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
    SELECT file, 'mbs' AS source_kind,
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
        END AS operation
    FROM mbs_raw
),
all_hits AS (
    SELECT file, source_kind, operation FROM native
    UNION ALL
    SELECT file, source_kind, operation FROM mbs
),
filtered AS (
    SELECT * FROM all_hits
    WHERE (getvariable('file') IS NULL OR file = getvariable('file'))
)
SELECT
    COUNT(*)                                                     AS touchpoints,
    COUNT(*) FILTER (WHERE operation IN ('write','delete'))      AS critical,
    COUNT(DISTINCT file)                                         AS files_affected,
    COUNT(*) FILTER (WHERE source_kind = 'mbs')                  AS mbs_hits,
    COUNT(*) FILTER (WHERE source_kind = 'native')               AS native_hits,
    COUNT(*) FILTER (WHERE operation = 'delete')                 AS delete_hits
FROM filtered;
