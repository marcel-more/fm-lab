-- @template_type: report
-- @description: KPI-Übersicht — Counts entsprechen exakt den Filter-Ergebnissen in der URL-Detailliste, damit ein KPI-Klick eine konsistente Resultatmenge öffnet.
-- @params: file (optional)

WITH
script_url_steps AS (
    SELECT
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')             AS url,
        -- context locale-unabhängig aus Step_ID herleiten: die KPIs unten filtern
        -- FILTER (WHERE context = 'Open URL'/'Insert from URL') gegen englische Literale.
        CASE s.Step_ID WHEN 111 THEN 'Open URL' WHEN 160 THEN 'Insert from URL' END AS context,
        COALESCE(c.Formula_Text, c.Display_Text)          AS calc_text,
        'Script (URL Step)'                               AS source_type
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Step_ID IN (111, 160)   -- Open URL / Insert from URL (Step_ID: locale-unabhängig)
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
),
import_records_all AS (
    -- Alle Import-Records-Steps (auch ohne http) — Schnittstellen-Indikator,
    -- weil Quelle häufig per Variable gesetzt wird. Bewusst DDR-basiert:
    -- die Import-Quelle ist kein Calc-Slot.
    SELECT
        COALESCE(
            regexp_extract(ddr.Step_Text, 'Source:[^"“„]*[“„]([^"”"]+)["”"]', 1),
            ''
        )                                                 AS url,
        'Import Records'                                  AS context,
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
        s.Step_Name                                              AS context,
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
        'Custom Function'                                     AS context,
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
                       'https?://[^ "<'']+')                      AS url,
        'Field'                                                   AS context,
        COALESCE(c.Formula_Text, c.Display_Text)                  AS calc_text,
        'Field'                                                   AS source_type
    FROM CalculationsCatalog c
    WHERE c.Calc_Role IN ('field_calculation', 'auto_enter')
      AND COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
layout_object_calcs AS (
    -- Alle LayoutObject-Rollen des Katalogs; für den Web-Viewer-KPI liefert die
    -- web_viewer_url-Rolle den Objekttyp 'Web Viewer' als context.
    SELECT
        regexp_extract(COALESCE(c.Formula_Text, c.Display_Text),
                       'https?://[^ "<'']+')                      AS url,
        lo.Object_Type                                            AS context,
        COALESCE(c.Formula_Text, c.Display_Text)                  AS calc_text,
        'Layout Object'                                           AS source_type
    FROM CalculationsCatalog c
    JOIN LayoutObjects lo ON lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    WHERE COALESCE(c.Formula_Text, c.Display_Text) LIKE '%http%'
      AND (getvariable('file') IS NULL OR lo.File_Name = getvariable('file'))
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
classified AS (
    SELECT
        url, context, source_type,
        CASE
            WHEN calc_text ILIKE '%CURL.%'  OR calc_text ILIKE '%MBS(%'
              OR calc_text ILIKE '%MBS (%' OR calc_text ILIKE '%Files.%'
              OR calc_text ILIKE '%Plugin.%' THEN 'Plugin'
            WHEN source_type LIKE 'Script%' THEN 'Script Step'
            WHEN source_type = 'Custom Function' THEN 'Custom Function'
            WHEN source_type = 'Field' THEN 'Field'
            WHEN source_type = 'Layout Object' THEN 'Layout Object'
            ELSE 'Other'
        END AS ref_type
    FROM all_urls
)
SELECT
    COUNT(*) FILTER (WHERE context = 'Open URL')                          AS open_url_steps,
    COUNT(*) FILTER (WHERE context = 'Insert from URL')                   AS insert_url_steps,
    COUNT(*) FILTER (WHERE context = 'Import Records')                    AS import_records_steps,
    COUNT(*) FILTER (WHERE ref_type = 'Plugin')                           AS mbs_plugin_hits,
    COUNT(*) FILTER (WHERE context = 'Web Viewer')                        AS web_viewer_hits,
    COUNT(*) FILTER (WHERE source_type = 'Script (Calc Step)')            AS calc_step_hits,
    COUNT(DISTINCT url) FILTER (WHERE url <> '')                          AS distinct_urls
FROM classified;
