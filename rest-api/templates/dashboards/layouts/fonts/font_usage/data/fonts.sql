-- One row per font (normalised font key) with its uses, objects, layouts, files,
-- size range and where the uses come from; the uses whose font is left to the
-- file default form one row of their own (font = '#default', always last).
-- Filtered by file, theme, size and the search (per use). Not paged: one row per
-- font. A row click opens font_usage_layouts on this font (the file-default row
-- on the source 'default') and hands the filters on (_carry_*).
WITH
--#include shared/rows.sql
lens AS (
    SELECT * FROM fr_m
    WHERE m_file AND m_theme AND m_size AND m_face AND m_otype AND m_layout AND m_search
),
per_font AS (
    SELECT
        CASE WHEN font_k = '#default' THEN '#default' ELSE any_value(font_display) END AS font,
        count(*)                                                         AS uses,
        count(DISTINCT (File_Name, Object_UUID))                         AS objects,
        count(DISTINCT (File_Name, layout_uuid))                         AS layouts,
        count(DISTINCT File_Name)                                        AS files,
        min(size_num)                                                    AS _size_min,
        max(size_num)                                                    AS _size_max,
        count(*) FILTER (WHERE source IN ('local', 'local_redundant'))   AS local_uses,
        count(*) FILTER (WHERE source = 'style')                         AS style_uses,
        count(*) FILTER (WHERE source = 'theme')                         AS theme_uses,
        count(*) FILTER (WHERE source IN ('rich_text', 'chart'))         AS run_uses,
        font_k                                                           AS _font_key
    FROM lens
    GROUP BY font_k
)
SELECT
    f.font,
    f.uses,
    f.objects,
    f.layouts,
    f.files,
    CASE
        WHEN f._size_min IS NULL THEN NULL
        WHEN f._size_min = f._size_max
            THEN regexp_replace(CAST(f._size_min AS VARCHAR), '\.0$', '') || ' pt'
        ELSE regexp_replace(CAST(f._size_min AS VARCHAR), '\.0$', '') || '–'
             || regexp_replace(CAST(f._size_max AS VARCHAR), '\.0$', '') || ' pt'
    END                                                                  AS sizes,
    f.local_uses,
    f.style_uses,
    f.theme_uses,
    f.run_uses,
    CASE WHEN f._font_key = '#default' THEN '' ELSE f._font_key END     AS _font,
    CASE WHEN f._font_key = '#default' THEN 'default' ELSE '' END       AS _source,
    coalesce(p.c_search, '')                                             AS _carry_search,
    coalesce(p.c_file, '')                                               AS _carry_file,
    coalesce(p.c_theme, '')                                              AS _carry_theme,
    coalesce(p.c_size, '')                                               AS _carry_size,
    (f._font_key = '#default')                                           AS _is_default
FROM per_font f, fr_p p
ORDER BY _is_default, f.uses DESC, lower(f.font);
