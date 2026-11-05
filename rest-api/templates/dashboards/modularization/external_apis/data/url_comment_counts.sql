-- @template_type: report
-- @description: Zähler für die Kommentar-FilterChips der URL-Detailliste — count_without (URLs im aktiven Code) und count_total (alle, inkl. Kommentar-Treffer), skopiert auf dieselben Filter wie url_details.sql (api_family/ref_type/context/source_type/file), OHNE den comment-Filter selbst. CTE-Kette identisch zu url_details.sql halten (V-2).
-- @params: file (optional), api_family (optional), ref_type (optional), step_name (optional), context (optional), source_type (optional)

WITH
-- 1) Open URL / Insert from URL — der URL-Slot des Steps als Katalog-Instanz
--    (CalculationsCatalog, Owner_UUID = Step_UUID). Erfasst auch Steps ohne
--    DDR-Zeile, die der frühere DDR-Step-Text-Join verlor.
script_url_steps AS (
    SELECT
        s.Script_UUID                                       AS script_uuid,
        s.Script_Name                                       AS name,
        s.File_Name                                         AS file,
        s.Step_Name                                         AS context,
        s.Step_Index + 1                                    AS step_index,
        s.Step_UUID                                         AS step_uuid,
        s.Script_UUID                                       AS target_uuid,
        'Script'                                            AS target_type,
        NULL                                                AS layout_filter_types,
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                AS url,
        'Script (URL Step)'                                 AS source_type,
        COALESCE(c.Formula_Text, c.Display_Text)            AS calc_text
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Step_ID IN (111, 160)   -- Open URL / Insert from URL (Step_ID: locale-unabhängig)
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),

-- 2) Import Records — alle, unabhängig von URL. Als Schnittstellen-Indikator
--    behandeln, weil die Quelle häufig via Variable aufgebaut wird ($Pfad).
--    Bewusst weiter DDR-basiert: die Import-Quelle ist KEIN Calc-Slot, sondern
--    eine Step-Option — der Source-Pfad steht nur im DDR-Klartext. Wenn keine
--    Source-Phrase im Step_Text steht (z.B. "Import Records [ ]"), bleibt url leer.
import_records_all AS (
    SELECT
        s.Script_UUID                                       AS script_uuid,
        s.Script_Name                                       AS name,
        s.File_Name                                         AS file,
        'Import Records'                                    AS context,
        s.Step_Index + 1                                        AS step_index,
        s.Step_UUID                                         AS step_uuid,
        s.Script_UUID                                       AS target_uuid,
        'Script'                                            AS target_type,
        NULL                                                AS layout_filter_types,
        COALESCE(
            -- typografische Anführungszeichen (U+201C / U+201D) im DDR-Klartext
            regexp_extract(ddr.Step_Text, 'Source:[^"“„]*[“„]([^"”"]+)["”"]', 1),
            ''
        )                                                   AS url,
        'Script (Import)'                                   AS source_type,
        ddr.Step_Text                                       AS calc_text
    FROM StepsForScripts s
    JOIN DDR_ScriptSteps ddr ON s.Step_UUID = ddr.Step_UUID AND ddr.File_Name = s.File_Name
    WHERE s.Step_ID = 35            -- Import Records
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),

-- 3) Script-Step-Calculations (Set Variable, Set Field, If, Show Custom Dialog, …)
--    — alle übrigen Step-Instanzen des Katalogs
script_calc_steps AS (
    SELECT
        s.Script_UUID                                              AS script_uuid,
        s.Script_Name                                              AS name,
        s.File_Name                                                AS file,
        s.Step_Name                                                AS context,
        s.Step_Index + 1                                               AS step_index,
        s.Step_UUID                                                AS step_uuid,
        s.Script_UUID                                              AS target_uuid,
        'Script'                                                   AS target_type,
        NULL                                                       AS layout_filter_types,
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                       AS url,
        'Script (Calc Step)'                                       AS source_type,
        COALESCE(c.Formula_Text, c.Display_Text)                   AS calc_text
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND s.Step_ID NOT IN (111, 160, 35)   -- nicht Open URL / Insert from URL / Import Records
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),

-- 3) Custom Function Bodies — Katalog-Instanz mit vollem Formeltext
--    (statt DDR-Chunks; findet auch chunk-fragmentierte URLs)
custom_function_calcs AS (
    SELECT
        NULL                                                       AS script_uuid,
        c.Owner_Name                                               AS name,
        c.File_Name                                                AS file,
        'Custom Function'                                          AS context,
        NULL                                                       AS step_index,
        NULL                                                       AS step_uuid,
        c.Owner_UUID                                               AS target_uuid,
        'CustomFunction'                                           AS target_type,
        NULL                                                       AS layout_filter_types,
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                       AS url,
        'Custom Function'                                          AS source_type,
        COALESCE(c.Formula_Text, c.Display_Text)                   AS calc_text
    FROM CalculationsCatalog c
    WHERE c.Calc_Role = 'custom_function'
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),

-- 4) Feld-Slots: Haupt-Calculation + AutoEnter — eine Zeile je Katalog-Instanz
field_calcs AS (
    SELECT
        NULL                                                                     AS script_uuid,
        c.Owner_Name                                                             AS name,
        c.File_Name                                                              AS file,
        CASE c.Calc_Role WHEN 'field_calculation' THEN 'Calculated Field'
             ELSE 'AutoEnter Calc' END                                           AS context,
        NULL                                                                     AS step_index,
        NULL                                                                     AS step_uuid,
        c.Owner_UUID                                                             AS target_uuid,
        'Field'                                                                  AS target_type,
        NULL                                                                     AS layout_filter_types,
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                                     AS url,
        'Field'                                                                  AS source_type,
        COALESCE(c.Formula_Text, c.Display_Text)                                 AS calc_text
    FROM CalculationsCatalog c
    WHERE c.Calc_Role IN ('field_calculation', 'auto_enter')
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),

-- 5) LayoutObject-Slots — ALLE Katalog-Rollen des Objekts (hide, tooltip,
--    button_label, script_trigger_parameter, web_viewer_url, conditional_format,
--    portal_filter, …). Leaf-genau: die frühere Object_XML-Suche zählte die
--    URL eines Web Viewers auch auf jedem umschließenden Container mit.
layout_object_calcs AS (
    SELECT
        NULL                                                       AS script_uuid,
        l.L_Name || ' / ' || lo.Object_Type                        AS name,
        lo.File_Name                                               AS file,
        CASE c.Calc_Role
            WHEN 'hide'                     THEN 'Hide Calc'
            WHEN 'tooltip'                  THEN 'Tooltip'
            WHEN 'button_label'             THEN 'Label Calc'
            WHEN 'script_trigger_parameter' THEN 'Trigger Param'
            ELSE lo.Object_Type
        END                                                        AS context,
        NULL                                                       AS step_index,
        NULL                                                       AS step_uuid,
        l.L_UUID                                                   AS target_uuid,
        'Layout'                                                   AS target_type,
        -- Layout-Detail-View nimmt einen `types`-Filter (Komma-Liste). Bei einem
        -- Web Viewer setzen wir zusätzlich den Container-Typ, damit das umgebende
        -- Layout-Element im Filter-Ergebnis sichtbar bleibt. Andere Layout-Typen
        -- führen genau zum eigenen Typ.
        CASE
            WHEN lo.Object_Type = 'Web Viewer' THEN 'Container,Web Viewer'
            ELSE lo.Object_Type
        END                                                        AS layout_filter_types,
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                       AS url,
        'Layout Object'                                            AS source_type,
        COALESCE(c.Formula_Text, c.Display_Text)                   AS calc_text
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    JOIN Layouts l ON l.L_ID = lo.Layout_ID AND l.File_Name = lo.File_Name
    WHERE COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
),

all_urls AS (
    SELECT * FROM script_url_steps      WHERE url <> ''
    UNION ALL
    SELECT * FROM import_records_all    -- alle Imports, auch ohne extrahierte Source
    UNION ALL
    SELECT * FROM script_calc_steps     WHERE url <> ''
    UNION ALL
    SELECT * FROM custom_function_calcs WHERE url <> ''
    UNION ALL
    SELECT * FROM field_calcs           WHERE url <> ''
    UNION ALL
    SELECT * FROM layout_object_calcs   WHERE url <> ''
),

-- Text-Ausschnitt VOR dem URL-Treffer (für die Kommentar-Erkennung, einmal
-- berechnet). bef = alles im calc_text links der ersten URL-Fundstelle.
positioned AS (
    SELECT *,
        CASE WHEN strpos(calc_text, url) > 1
             THEN substring(calc_text, 1, strpos(calc_text, url) - 1)
             ELSE '' END                                  AS bef
    FROM all_urls
),

classified AS (
    SELECT
        script_uuid, name, file, context, step_index, step_uuid,
        target_uuid, target_type, layout_filter_types, source_type, url, calc_text,
        regexp_extract(url, '^https?://([A-Za-z0-9._:-]+)', 1) AS host,
        -- Kommentar-Heuristik: liegt der URL-Treffer in einem FileMaker-Calc-Kommentar?
        --   Block: unbalanciertes /* vor der URL (mehr /* als */ links davon).
        --   Zeile: // in derselben Zeile vor der URL (URL-Schemata vorher entfernt,
        --          damit das // aus https:// nicht fälschlich zählt).
        -- URL-/Import-Steps tragen die URL im Step-Parameter (nie Kommentar) → FALSE.
        CASE
            WHEN source_type IN ('Script (URL Step)', 'Script (Import)') THEN FALSE
            ELSE (
                (length(bef) - length(replace(bef, '/*', '')))
                    > (length(bef) - length(replace(bef, '*/', '')))
                OR replace(replace(regexp_extract(bef, '[^\r\n]*$'), 'https://', ''), 'http://', '')
                     LIKE '%//%'
            )
        END                                               AS in_comment,
        -- API-Familien-Klassifikation: der Platzhalter wird vom Dataset-Resolver
        -- durch den generierten CASE-Block des gewählten Filter-Sets ersetzt
        -- (Param `api_set`, Default `generic`). Set-Definitionen: `api-sets/<id>.json`
        -- im Bundle bzw. `.fmlab/dashboards/api-sets/` (installiert). Siehe api-sets/README.md.
        /*__API_SET_CLASSIFICATION__*/ AS api_family,
        CASE
            WHEN calc_text ILIKE '%CURL.%'  OR calc_text ILIKE '%MBS(%'
              OR calc_text ILIKE '%MBS (%' OR calc_text ILIKE '%Files.%'
              OR calc_text ILIKE '%Plugin.%'    THEN 'Plugin'
            WHEN source_type LIKE 'Script%'     THEN 'Script Step'
            WHEN source_type = 'Custom Function' THEN 'Custom Function'
            WHEN source_type = 'Field'          THEN 'Field'
            WHEN source_type = 'Layout Object'  THEN 'Layout Object'
            ELSE 'Other'
        END AS ref_type
    FROM positioned
)
SELECT
    COUNT(*)                               AS count_total,
    COUNT(*) FILTER (WHERE NOT in_comment) AS count_without,
    COUNT(*) FILTER (WHERE in_comment)     AS count_comments
FROM classified
WHERE (getvariable('api_family')  IS NULL OR getvariable('api_family')  IN ('', 'All', 'Alle')
       OR api_family  = getvariable('api_family'))
  AND (getvariable('ref_type')    IS NULL OR getvariable('ref_type')    IN ('', 'All', 'Alle')
       OR ref_type    = getvariable('ref_type'))
  AND (getvariable('step_name')   IS NULL OR getvariable('step_name')   IN ('', 'All', 'Alle')
       OR context     = getvariable('step_name'))
  AND (getvariable('context')     IS NULL OR getvariable('context')     IN ('', 'All', 'Alle')
       OR context     = getvariable('context'))
  AND (getvariable('source_type') IS NULL OR getvariable('source_type') IN ('', 'All', 'Alle')
       OR source_type = getvariable('source_type'))
  AND (getvariable('host') IS NULL OR getvariable('host') IN ('', 'All', 'Alle')
       OR host = getvariable('host'));
