-- @template_type: report
-- @description: Classifies every URL invocation by API family with a breakdown per reference type (Script Step, Plugin, Custom Function, Field, Layout Object). The leading "All" row gives the grand totals and acts as a filter-reset link.
-- @params: file (optional)

WITH
-- URL-Slot der Open-URL-/Insert-from-URL-Steps als Katalog-Instanz
script_url_steps AS (
    SELECT
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')             AS url,
        s.File_Name                                       AS file,
        COALESCE(c.Formula_Text, c.Display_Text)          AS calc_text,
        'Script (URL Step)'                               AS source_type
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Step_ID IN (111, 160)   -- Open URL / Insert from URL (Step_ID: locale-unabhängig)
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),
import_records_all AS (
    -- Alle Import-Records-Steps (auch ohne http) als Schnittstellen-Indikator.
    -- Bewusst DDR-basiert: die Import-Quelle ist kein Calc-Slot.
    SELECT
        COALESCE(
            regexp_extract(ddr.Step_Text, 'Source:[^"“„]*[“„]([^"”"]+)["”"]', 1),
            ''
        )                                                 AS url,
        s.File_Name                                       AS file,
        ddr.Step_Text                                     AS calc_text,
        'Script (Import)'                                 AS source_type
    FROM StepsForScripts s
    JOIN DDR_ScriptSteps ddr ON s.Step_UUID = ddr.Step_UUID AND ddr.File_Name = s.File_Name
    WHERE s.Step_ID = 35            -- Import Records
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),
script_calc_steps AS (
    SELECT
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                     AS url,
        s.File_Name                                              AS file,
        COALESCE(c.Formula_Text, c.Display_Text)                 AS calc_text,
        'Script (Calc Step)'                                     AS source_type
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND s.Step_ID NOT IN (111, 160, 35)   -- nicht Open URL / Insert from URL / Import Records
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),
custom_function_calcs AS (
    SELECT
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                  AS url,
        c.File_Name                                           AS file,
        COALESCE(c.Formula_Text, c.Display_Text)              AS calc_text,
        'Custom Function'                                     AS source_type
    FROM CalculationsCatalog c
    WHERE c.Calc_Role = 'custom_function'
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
field_calcs AS (
    SELECT
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                       AS url,
        c.File_Name                                                AS file,
        COALESCE(c.Formula_Text, c.Display_Text)                   AS calc_text,
        'Field'                                                    AS source_type
    FROM CalculationsCatalog c
    WHERE c.Calc_Role IN ('field_calculation', 'auto_enter')
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
layout_object_calcs AS (
    -- Alle LayoutObject-Rollen des Katalogs; leaf-genau (keine Container-
    -- Doppelzählung wie beim früheren Object_XML-Scan).
    SELECT
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                       AS url,
        c.File_Name                                                AS file,
        COALESCE(c.Formula_Text, c.Display_Text)                   AS calc_text,
        'Layout Object'                                            AS source_type
    FROM CalculationsCatalog c
    WHERE c.Owner_Type = 'LayoutObject'
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
all_urls AS (
    SELECT * FROM script_url_steps      WHERE url <> ''
    UNION ALL
    SELECT * FROM import_records_all    -- alle Imports, auch ohne Source-Extraction
    UNION ALL
    SELECT * FROM script_calc_steps     WHERE url <> ''
    UNION ALL
    SELECT * FROM custom_function_calcs WHERE url <> ''
    UNION ALL
    SELECT * FROM field_calcs           WHERE url <> ''
    UNION ALL
    SELECT * FROM layout_object_calcs   WHERE url <> ''
),
positioned AS (
    SELECT *,
        CASE WHEN strpos(calc_text, url) > 1
             THEN substring(calc_text, 1, strpos(calc_text, url) - 1)
             ELSE '' END                                  AS bef
    FROM all_urls
),
classified AS (
    SELECT
        url, file, source_type,
        regexp_extract(url, '^https?://([A-Za-z0-9._:-]+)', 1) AS host,
        -- Kommentar-Heuristik (identisch zu url_details): liegt der URL-Treffer in
        -- einem FileMaker-Calc-Kommentar? Damit die Familien-Counts denselben
        -- comment-Filter respektieren wie die Detailliste (sonst zählt die Tabelle
        -- reine Kommentar-Familien, die die Default-Ansicht dann ausblendet).
        CASE
            WHEN source_type IN ('Script (URL Step)', 'Script (Import)') THEN FALSE
            ELSE (
                (length(bef) - length(replace(bef, '/*', '')))
                    > (length(bef) - length(replace(bef, '*/', '')))
                OR replace(replace(regexp_extract(bef, '[^\r\n]*$'), 'https://', ''), 'http://', '')
                     LIKE '%//%'
            )
        END                                               AS in_comment,
        -- API-Familien-Klassifikation: Platzhalter → generierter CASE des gewählten
        -- Filter-Sets (Param `api_set`, Default `generic`). Siehe api-sets/README.md.
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
),
-- Comment-gefiltertes classified (Default: nur aktiver Code) — Basis beider Aggregate.
classified_f AS (
    SELECT * FROM classified
    WHERE (CASE COALESCE(getvariable('comment'), 'exclude')
               WHEN 'all'  THEN TRUE
               WHEN 'only' THEN in_comment
               ELSE NOT in_comment
           END)
),
-- Eine Zeile pro Familie mit Pivot-Counts pro ref_type
per_family AS (
    SELECT
        api_family,
        COUNT(*)                                                                    AS hits,
        COUNT(DISTINCT host) FILTER (WHERE host <> '')                              AS hosts,
        COUNT(DISTINCT url)  FILTER (WHERE url  <> '')                              AS urls,
        COUNT(DISTINCT file)                                                        AS files,
        COUNT(*) FILTER (WHERE ref_type = 'Script Step')                            AS script_step,
        COUNT(*) FILTER (WHERE ref_type = 'Plugin')                                 AS plugin,
        COUNT(*) FILTER (WHERE ref_type = 'Layout Object')                          AS layout_object,
        COUNT(*) FILTER (WHERE ref_type = 'Field')                                  AS field,
        COUNT(*) FILTER (WHERE ref_type = 'Custom Function')                        AS custom_function
    FROM classified_f
    GROUP BY api_family
),
all_row AS (
    -- Direkt aus classified aggregieren (nicht aus per_family),
    -- damit COUNT(DISTINCT …) korrekt ist statt SUM über Familien-Buckets.
    SELECT
        'All' AS api_family,
        COUNT(*)                                                     AS hits,
        COUNT(DISTINCT host) FILTER (WHERE host <> '')               AS hosts,
        COUNT(DISTINCT url)  FILTER (WHERE url  <> '')               AS urls,
        COUNT(DISTINCT file)                                         AS files,
        COUNT(*) FILTER (WHERE ref_type = 'Script Step')             AS script_step,
        COUNT(*) FILTER (WHERE ref_type = 'Plugin')                  AS plugin,
        COUNT(*) FILTER (WHERE ref_type = 'Layout Object')           AS layout_object,
        COUNT(*) FILTER (WHERE ref_type = 'Field')                   AS field,
        COUNT(*) FILTER (WHERE ref_type = 'Custom Function')         AS custom_function
    FROM classified_f
)
-- "All" first (sort_order=0), then by hits descending
SELECT api_family, hits, hosts, urls, files, script_step, plugin, layout_object, field, custom_function
FROM (
    SELECT 0 AS sort_order, * FROM all_row
    UNION ALL
    SELECT 1 AS sort_order, * FROM per_family
) t
ORDER BY sort_order, hits DESC;
