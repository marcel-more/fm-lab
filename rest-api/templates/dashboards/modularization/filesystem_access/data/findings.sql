-- @template_type: report
-- @description: Detailliste aller Dateisystem-Berührungspunkte — je Zeile eine Fundstelle (nativer Script-Step ODER MBS-Plugin-Aufruf) mit Operation, API-Gruppe, Träger-Objekt und Navigations-Anker. Native Steps sind Step_ID-gated (locale-unabhängig), MBS über PluginFunctionUsages (step-granular: Source_Subkey = Step_Index bei Source_Type='Script') — inkl. Step-Anchor und Script-Zeile.
-- @params: file (optional), operation (optional), api_group (optional), ref_type (optional), limit (optional, default 400)
--
-- KLASSIFIKATION — dieselbe CASE-Logik wie in fs_groups.sql. Beide Dateien
-- synchron halten (native Step_ID-Gruppen + MBS-Funktions-Muster).

WITH native AS (
    SELECT
        s.File_Name                                     AS file,
        'Native Step'                                   AS ref_type,
        s.Script_Name                                   AS carrier,
        s.Step_Name                                     AS detail,
        s.Step_Index + 1                                    AS step_index,
        s.Script_UUID                                   AS nav_uuid,
        'Script'                                        AS nav_type,
        s.Step_UUID                                     AS step_uuid,
        CASE
            WHEN s.Step_ID IN (190,192)                 THEN 'write'
            WHEN s.Step_ID = 193                        THEN 'read'
            WHEN s.Step_ID IN (191,194,195,196,199)     THEN 'manage'
            WHEN s.Step_ID = 197                        THEN 'delete'
            WHEN s.Step_ID IN (188,189)                 THEN 'probe'
            WHEN s.Step_ID IN (35,131,56,158,159,161)   THEN 'import'
            ELSE                                             'export'
        END                                             AS operation,
        CASE
            WHEN s.Step_ID BETWEEN 188 AND 199          THEN 'Data File API'
            WHEN s.Step_ID IN (35,131,56,158,159,161)   THEN 'Import/Insert'
            ELSE                                             'Export/Save'
        END                                             AS api_group
    FROM StepsForScripts s
    WHERE s.Step_ID IN (190,191,192,193,194,195,196,197,199,188,189,
                        35,131,56,158,159,161,
                        36,132,143,144,152,225,37,3,96)
),
mbs_raw AS (
    SELECT
        p.File_Name                                     AS file,
        p.Source_Type,
        p.Source_UUID,
        p.Source_Subkey,
        regexp_extract(p.Plugin_Function_Name, '(?i)MBS:([A-Za-z]+)\.', 1)             AS component,
        regexp_extract(p.Plugin_Function_Name, '(?i)MBS:[A-Za-z]+\.([A-Za-z0-9]+)', 1) AS fn
    FROM PluginFunctionUsages p
    WHERE (regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(Files|Path|Folders|FileDialog)\.')
        OR regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(Text)\.(Read|Write|Append)TextFile')
        OR regexp_matches(p.Plugin_Function_Name, '(?i)MBS:(Container)\.(Export|ReadFile|WriteFile)'))
),
mbs AS (
    SELECT
        r.file                                          AS file,
        'MBS ' || r.Source_Type                         AS ref_type,
        COALESCE(s.Script_Name, oc.Object_Name)         AS carrier,
        r.component || '.' || r.fn                      AS detail,
        s.Step_Index + 1                                    AS step_index,
        r.Source_UUID                                   AS nav_uuid,
        r.Source_Type                                   AS nav_type,
        s.Step_UUID                                     AS step_uuid,
        CASE
            WHEN r.component ILIKE 'Files' AND (r.fn ILIKE 'Read%' OR r.fn ILIKE 'List%')            THEN 'read'
            WHEN r.component ILIKE 'Files' AND r.fn IN ('CopyFile','CreateDirectory','RenameFile','MoveFile') THEN 'write'
            WHEN r.component ILIKE 'Files' AND (r.fn ILIKE 'Delete%' OR r.fn ILIKE 'MoveToTrash%')   THEN 'delete'
            WHEN r.component ILIKE 'Files' AND (r.fn LIKE '%Exists' OR r.fn LIKE '%Size' OR r.fn LIKE '%Date') THEN 'probe'
            WHEN r.component ILIKE 'Files' AND (r.fn ILIKE 'Launch%' OR r.fn ILIKE 'Reveal%')        THEN 'launch'
            WHEN r.component ILIKE 'Files' AND (r.fn ILIKE 'Mount%' OR r.fn ILIKE 'Unmount%')        THEN 'mount'
            WHEN r.component ILIKE 'Text'  AND r.fn ILIKE 'Read%'                                    THEN 'read'
            WHEN r.component ILIKE 'Text'  AND (r.fn ILIKE 'Write%' OR r.fn ILIKE 'Append%')         THEN 'write'
            WHEN r.component ILIKE 'Container' AND r.fn ILIKE 'Read%'                                THEN 'read'
            WHEN r.component ILIKE 'Container'                                                       THEN 'write'
            WHEN r.component ILIKE 'Path'                                                            THEN 'path'
            WHEN r.component ILIKE 'Folders'                                                         THEN 'path'
            WHEN r.component ILIKE 'FileDialog'                                                      THEN 'dialog'
            ELSE 'other'
        END                                             AS operation,
        'MBS ' || r.component                           AS api_group
    FROM mbs_raw r
    LEFT JOIN StepsForScripts s
      ON r.Source_Type = 'Script'
     AND s.Script_UUID = r.Source_UUID
     AND s.File_Name = r.file
     AND s.Step_Index = TRY_CAST(r.Source_Subkey AS INTEGER)
    LEFT JOIN ObjectCatalog oc ON oc.Object_UUID = r.Source_UUID AND oc.File_Name = r.file
),
all_hits AS (
    SELECT file, api_group, operation, ref_type, carrier, detail, step_index, nav_uuid, nav_type, step_uuid FROM native
    UNION ALL
    SELECT file, api_group, operation, ref_type, carrier, detail, step_index, nav_uuid, nav_type, step_uuid FROM mbs
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        *,
           api_group AS _ord_1,
           operation AS _ord_2,
           file AS _ord_3,
           carrier AS _ord_4,
           step_index AS _ord_5
    FROM all_hits
    WHERE (getvariable('file') IS NULL OR file = getvariable('file'))
      AND (getvariable('operation') IS NULL OR getvariable('operation') IN ('', 'All', 'Alle')
           OR operation = getvariable('operation'))
      AND (getvariable('api_group') IS NULL OR getvariable('api_group') IN ('', 'All', 'Alle')
           OR api_group = getvariable('api_group'))
      AND (getvariable('ref_type') IS NULL OR getvariable('ref_type') IN ('', 'All', 'Alle')
           OR ref_type = getvariable('ref_type'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4, _ord_5),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u._ord_5, u) AS row_key
    FROM unkeyed u
),
-- >>> shared paging table-search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) NOT IN ('uuid', 'nav_uuid', 'row_key')))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging table-search block
filtered AS (
    SELECT * FROM searched
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 400), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
