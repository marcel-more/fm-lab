-- Shared font rows of the font dashboards (font_usage, font_usage_layouts,
-- font_usage_objects). Every bundle carries a byte-identical copy of this file
-- (`--#include` stays inside its bundle); unit test dashboard-font-blocks keeps
-- the copies equal — change all three together.
--
-- One row per font use: the base font of every text-bearing layout object
-- (v_layout_object_font), plus every formatted text run with its own font and
-- every chart text area (LayoutObjectFontRuns). Chart series titles are left out:
-- they keep the theme font whatever the chart dialog sets.
--
-- The scope (Analysis-Test object or layout UUIDs) is applied here. Every other
-- filter becomes a match flag m_* on the row (fr_m), so a dataset applies exactly
-- the flags it needs: a list applies all of them, the options of a filter all
-- but its own (the counts of a lens must ignore that lens itself).
--
-- Filter params (empty = no filter):
--   file        file names, comma-separated (the app-level file filter is one of them)
--   theme, font, size   values separated by '|' (theme names may contain commas)
--   face        normal | bold | italic | bold italic
--   source      '' = uses with a named font (all but 'default'), 'all', or one source;
--               source_default replaces '' for datasets that list every use
--   otype       object-type chip;  layout_uuid / layout_file   one layout
--   search      term over font, layout, object, field, theme, style, file, type,
--               size, face, source and run/area — matched per use, so a layout
--               list shows the layouts with at least one matching use
fr_layouts AS (
    SELECT l.File_Name, l.L_ID, l.L_UUID, l.L_Name,
           coalesce(tc.Theme_Display, l.L_Theme_Resolved_Name) AS theme
    FROM Layouts l
    LEFT JOIN ThemeCatalog tc
           ON tc.File_Name = l.File_Name AND tc.Theme_UUID = l.L_Theme_Resolved_UUID
),
fr_label AS (
    -- what the object shows: its name, else the displayed field, else its text
    SELECT f.Object_UUID, f.File_Name,
           any_value(t.Object_Name) AS field_name
    FROM v_layout_object_font f
    JOIN ObjectLinks ol   ON ol.Source_UUID = f.Object_UUID AND ol.Source_File = f.File_Name
                         AND ol.Link_Role = 'displays_field'
    JOIN ObjectCatalog t  ON t.Object_UUID = ol.Target_UUID AND t.File_Name = ol.Target_File
    GROUP BY ALL
),
fr_obj AS (
    SELECT f.*, ly.L_UUID AS layout_uuid, ly.theme, fl.field_name,
           coalesce(NULLIF(f.Object_Name, ''), fl.field_name,
                    NULLIF(trim(regexp_replace(left(lo.Text_Content, 80), '\s+', ' ', 'g')), ''),
                    f.Object_Type)                                        AS object_label,
           CASE
               WHEN f.Object_Type = 'Text'                                 THEN 'text'
               WHEN f.Object_Type IN ('Edit Box', 'Concealed Edit Box')    THEN 'field'
               WHEN f.Object_Type = 'Drop-down List'                       THEN 'dropdown'
               WHEN f.Object_Type = 'Pop-up Menu'                          THEN 'popup'
               WHEN f.Object_Type = 'Checkbox Set'                         THEN 'checkbox'
               WHEN f.Object_Type = 'Radio Button Set'                     THEN 'radio'
               WHEN f.Object_Type = 'Drop-down Calendar'                   THEN 'calendar'
               WHEN f.Object_Type IN ('Button', 'Popover Button')          THEN 'button'
               WHEN f.Object_Type = 'Tab Control'                          THEN 'tab'
               ELSE 'other'
           END                                                            AS otype
    FROM v_layout_object_font f
    JOIN fr_layouts ly    ON ly.File_Name = f.File_Name AND ly.L_ID = f.Layout_ID
    JOIN LayoutObjects lo ON lo.Object_UUID = f.Object_UUID AND lo.File_Name = f.File_Name
    LEFT JOIN fr_label fl ON fl.Object_UUID = f.Object_UUID AND fl.File_Name = f.File_Name
),
fr_rows_raw AS (
    SELECT o.Object_UUID, o.File_Name, o.layout_uuid, o.Layout_Name, o.theme, o.otype,
           o.Object_Type, o.object_label, o.field_name, o.Style_Display,
           'base'                                   AS kind,
           o.Font_Family                            AS font,
           o.Font_Key                               AS font_key,
           o.Font_Size                              AS size,
           concat_ws(' ', NULLIF(o.Font_Weight, 'normal'), NULLIF(o.Font_Style, 'normal')) AS face,
           CASE WHEN o.Family_Source IN ('part_theme', 'theme', 'group') THEN 'theme'
                ELSE o.Family_Source END            AS source,
           CAST(NULL AS VARCHAR)                    AS detail,
           o.Low_Confidence                         AS low_confidence
    FROM fr_obj o
    UNION ALL
    SELECT o.Object_UUID, o.File_Name, o.layout_uuid, o.Layout_Name, o.theme, o.otype,
           o.Object_Type, o.object_label, o.field_name, o.Style_Display,
           'rich_text', r.Font_Family, lower(r.Font_Family),
           CASE WHEN r.Font_Size IS NOT NULL THEN regexp_replace(CAST(r.Font_Size AS VARCHAR), '\.0$', '') || 'pt' END,
           CAST(NULL AS VARCHAR),
           'rich_text',
           r.Run_Text,
           FALSE
    FROM fr_obj o
    JOIN LayoutObjectFontRuns r ON r.Object_UUID = o.Object_UUID AND r.File_Name = o.File_Name
    WHERE r.Source = 'rich_text' AND r.Font_Family IS NOT NULL
    UNION ALL
    -- charts are not text-bearing objects of the view; they come straight from the runs
    SELECT r.Object_UUID, r.File_Name, ly.L_UUID, ly.L_Name, ly.theme, 'chart',
           r.Object_Type,
           coalesce(NULLIF(lo.Object_Name, ''), r.Object_Type),
           CAST(NULL AS VARCHAR),
           s.Style_Display,
           'chart', r.Font_Family, lower(r.Font_Family),
           CASE WHEN r.Font_Size IS NOT NULL THEN regexp_replace(CAST(r.Font_Size AS VARCHAR), '\.0$', '') || 'pt' END,
           CAST(NULL AS VARCHAR),
           'chart',
           r.Slot,
           FALSE
    FROM LayoutObjectFontRuns r
    JOIN fr_layouts ly    ON ly.File_Name = r.File_Name AND ly.L_ID = r.Layout_ID
    JOIN LayoutObjects lo ON lo.Object_UUID = r.Object_UUID AND lo.File_Name = r.File_Name
    LEFT JOIN LayoutObjectStyles s ON s.Object_UUID = r.Object_UUID AND s.File_Name = r.File_Name
    WHERE r.Source = 'chart' AND r.Font_Family IS NOT NULL
      AND r.Slot NOT LIKE 'series%'
),
-- scope: object or layout UUIDs (Analysis-Test scope); no param → no row → no filter
fr_scope AS (
    SELECT unnest(string_split(getvariable('scope_uuids'), ',')) AS u
),
fr_scoped AS (
    SELECT r.* FROM fr_rows_raw r
    WHERE NOT EXISTS (SELECT 1 FROM fr_scope)
       OR r.Object_UUID IN (SELECT u FROM fr_scope)
       OR r.layout_uuid IN (SELECT u FROM fr_scope)
),
fr_names AS (
    -- one display spelling per font key: a capitalised spelling wins over 'arial'
    SELECT font_key,
           arg_max(font, (CASE WHEN font <> lower(font) THEN 1000000000 ELSE 0 END) + n) AS font_display
    FROM (SELECT font_key, font, count(*) AS n FROM fr_scoped WHERE font_key IS NOT NULL GROUP BY ALL)
    GROUP BY font_key
),
fr_rows AS (
    SELECT r.*, n.font_display,
           coalesce(r.font_key, '#default')                               AS font_k,
           coalesce(r.theme, '—')                                         AS theme_k,
           TRY_CAST(regexp_extract(r.size, '^([0-9]+(\.[0-9]+)?)', 1) AS DOUBLE) AS size_num,
           coalesce(NULLIF(r.face, ''), 'normal')                         AS face_k,
           lower(concat_ws(chr(31), n.font_display, r.Layout_Name, r.object_label, r.field_name,
                           r.theme, r.Style_Display, r.File_Name, r.Object_Type, r.size, r.face,
                           CASE r.source
                               WHEN 'local'           THEN 'local'
                               WHEN 'local_redundant' THEN 'local, same as inherited'
                               WHEN 'style'           THEN 'style'
                               WHEN 'theme'           THEN 'theme'
                               WHEN 'default'         THEN 'file default'
                               WHEN 'rich_text'       THEN 'rich text'
                               WHEN 'chart'           THEN 'chart'
                           END,
                           r.detail))                                     AS hay
    FROM fr_scoped r
    LEFT JOIN fr_names n ON n.font_key = r.font_key
),
-- filter values, normalised ('' and NULL = no filter); c_* = raw values, which the
-- lists hand on as _carry_* columns so a click into the next dashboard keeps them
fr_p AS (
    SELECT p.*,
           CASE WHEN c_file  IS NOT NULL THEN string_split(c_file, ',')  END AS p_files,
           CASE WHEN c_theme IS NOT NULL THEN string_split(c_theme, '|') END AS p_themes,
           CASE WHEN c_font  IS NOT NULL THEN string_split(c_font, '|')  END AS p_fonts,
           CASE WHEN c_size  IS NOT NULL THEN string_split(c_size, '|')  END AS p_sizes,
           c_face                                                         AS p_face,
           coalesce(c_source, NULLIF(CAST(getvariable('source_default') AS VARCHAR), ''), 'named') AS p_source,
           c_otype                                                        AS p_otype,
           NULLIF(CAST(getvariable('layout_uuid') AS VARCHAR), '')        AS p_layout,
           NULLIF(CAST(getvariable('layout_file') AS VARCHAR), '')        AS p_layout_file,
           lower(c_search)                                                AS p_search,
           COALESCE(TRY_CAST(NULLIF(CAST(getvariable('font_max') AS VARCHAR), '') AS INTEGER), 3) AS p_font_max,
           NULLIF(CAST(getvariable('many') AS VARCHAR), '')               AS p_many
    FROM (
        SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '')           AS c_file,
               NULLIF(CAST(getvariable('theme') AS VARCHAR), '')          AS c_theme,
               NULLIF(CAST(getvariable('font') AS VARCHAR), '')           AS c_font,
               NULLIF(CAST(getvariable('size') AS VARCHAR), '')           AS c_size,
               NULLIF(CAST(getvariable('face') AS VARCHAR), '')           AS c_face,
               NULLIF(CAST(getvariable('source') AS VARCHAR), '')         AS c_source,
               NULLIF(CAST(getvariable('otype') AS VARCHAR), '')          AS c_otype,
               NULLIF(trim(CAST(getvariable('search') AS VARCHAR)), '')   AS c_search
    ) p
),
-- rows with one match flag per filter
fr_m AS MATERIALIZED (
    SELECT r.*,
           coalesce(p.p_files  IS NULL OR list_contains(p.p_files, r.File_Name), FALSE) AS m_file,
           coalesce(p.p_themes IS NULL OR list_contains(p.p_themes, r.theme_k), FALSE)  AS m_theme,
           coalesce(p.p_fonts  IS NULL OR list_contains(p.p_fonts, r.font_k), FALSE)    AS m_font,
           coalesce(p.p_sizes  IS NULL OR list_contains(p.p_sizes, r.size), FALSE)      AS m_size,
           coalesce(p.p_face   IS NULL OR r.face_k = p.p_face, FALSE)                   AS m_face,
           coalesce(p.p_source = 'all'
                    OR (p.p_source = 'named' AND r.source <> 'default')
                    OR r.source = p.p_source, FALSE)                                    AS m_source,
           coalesce(p.p_otype  IS NULL OR r.otype = p.p_otype, FALSE)                   AS m_otype,
           coalesce(p.p_layout IS NULL
                    OR (r.layout_uuid = p.p_layout
                        AND (p.p_layout_file IS NULL OR r.File_Name = p.p_layout_file)), FALSE) AS m_layout,
           coalesce(p.p_search IS NULL OR contains(r.hay, p.p_search), FALSE)           AS m_search
    FROM fr_rows r, fr_p p
),
