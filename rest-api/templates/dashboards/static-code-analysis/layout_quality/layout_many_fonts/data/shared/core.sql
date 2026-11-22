-- Layout with many fonts (layout_many_fonts) — shared rule core of findings.sql and summary.sql.
-- Needs catalog schema 1.44.0 (font and style tables).
-- Fonts per layout: the base font of every text-bearing object, formatted text
-- runs with a font of their own and chart text areas (series titles left out —
-- they keep the theme font). The file default is no font: it is not counted
-- (default_objects names the objects left to it).
fu_uses AS (
    SELECT f.File_Name, f.Layout_ID, f.Object_UUID,
           coalesce(f.Font_Key, '#default') AS font_key, f.Font_Family AS font
    FROM v_layout_object_font f
    UNION ALL
    SELECT r.File_Name, r.Layout_ID, r.Object_UUID, lower(r.Font_Family), r.Font_Family
    FROM LayoutObjectFontRuns r
    WHERE r.Font_Family IS NOT NULL
      AND (r.Source = 'rich_text' OR r.Slot NOT LIKE 'series%')
),
-- one display spelling per font: a capitalised spelling wins over 'arial'
fu_names AS (
    SELECT font_key,
           arg_max(font, (CASE WHEN font <> lower(font) THEN 1000000000 ELSE 0 END) + n) AS font_display
    FROM (SELECT font_key, font, count(*) AS n FROM fu_uses WHERE font IS NOT NULL GROUP BY ALL)
    GROUP BY font_key
),
fu_max AS (
    SELECT COALESCE(TRY_CAST(NULLIF(CAST(getvariable('font_max') AS VARCHAR), '') AS INTEGER), 3) AS m
),
fu_layouts AS (
    SELECT ly.File_Name, ly.L_UUID, ly.L_Name,
           count(DISTINCT u.font_key) FILTER (WHERE u.font_key <> '#default') AS fonts,
           string_agg(DISTINCT n.font_display, ', ' ORDER BY n.font_display) AS font_list,
           count(DISTINCT u.Object_UUID) FILTER (WHERE u.font_key = '#default') AS default_objects
    FROM fu_uses u
    JOIN Layouts ly ON ly.L_ID = u.Layout_ID AND ly.File_Name = u.File_Name
    LEFT JOIN fu_names n ON n.font_key = u.font_key
    WHERE (getvariable('file') IS NULL OR u.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR ly.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY ly.File_Name, ly.L_UUID, ly.L_Name
),
fu_hits AS (
    SELECT l.* FROM fu_layouts l, fu_max WHERE l.fonts > fu_max.m
),
