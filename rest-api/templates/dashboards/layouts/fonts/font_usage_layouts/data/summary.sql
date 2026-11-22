-- One row: the tiles of the layout list and the counts of its chips.
--   layouts       layouts with a matching use (the list without "many fonts")
--   many_layouts  of these, layouts with more named fonts than font_max
--   uses / files  matching font uses and their files
--   chip_src_*    uses per source under all other filters (source chips)
--   chip_*        uses per object type under all other filters (type chips)
WITH
--#include shared/rows.sql
matching AS (
    SELECT * FROM fr_m
    WHERE m_file AND m_theme AND m_font AND m_size AND m_face AND m_source
      AND m_otype AND m_layout AND m_search
),
per_layout AS (
    SELECT r.File_Name, r.layout_uuid,
           count(DISTINCT r.font_key) FILTER (WHERE r.source <> 'default') AS fonts
    FROM fr_m r
    SEMI JOIN matching h ON h.File_Name = r.File_Name AND h.layout_uuid = r.layout_uuid
    GROUP BY r.File_Name, r.layout_uuid
),
src AS (
    SELECT source FROM fr_m
    WHERE m_file AND m_theme AND m_font AND m_size AND m_face AND m_otype AND m_layout AND m_search
),
typ AS (
    SELECT otype FROM fr_m
    WHERE m_file AND m_theme AND m_font AND m_size AND m_face AND m_source AND m_layout AND m_search
)
SELECT
    (SELECT count(*) FROM per_layout)                                    AS layouts,
    (SELECT count(*) FROM per_layout, fr_p WHERE fonts > fr_p.p_font_max) AS many_layouts,
    (SELECT p_font_max FROM fr_p)                                        AS font_max,
    (SELECT count(*) FROM matching)                                      AS uses,
    (SELECT count(DISTINCT File_Name) FROM matching)                     AS files,
    (SELECT count(*) FILTER (WHERE source <> 'default') FROM src)        AS chip_src_named,
    (SELECT count(*) FILTER (WHERE source = 'local') FROM src)           AS chip_src_local,
    (SELECT count(*) FILTER (WHERE source = 'local_redundant') FROM src) AS chip_src_local_redundant,
    (SELECT count(*) FILTER (WHERE source = 'style') FROM src)           AS chip_src_style,
    (SELECT count(*) FILTER (WHERE source = 'theme') FROM src)           AS chip_src_theme,
    (SELECT count(*) FILTER (WHERE source = 'rich_text') FROM src)       AS chip_src_rich_text,
    (SELECT count(*) FILTER (WHERE source = 'chart') FROM src)           AS chip_src_chart,
    (SELECT count(*) FILTER (WHERE source = 'default') FROM src)         AS chip_src_default,
    (SELECT count(*) FROM src)                                           AS chip_src_all,
    (SELECT count(*) FROM typ)                                           AS chip_all,
    (SELECT count(*) FILTER (WHERE otype = 'text') FROM typ)             AS chip_text,
    (SELECT count(*) FILTER (WHERE otype = 'field') FROM typ)            AS chip_field,
    (SELECT count(*) FILTER (WHERE otype = 'dropdown') FROM typ)         AS chip_dropdown,
    (SELECT count(*) FILTER (WHERE otype = 'popup') FROM typ)            AS chip_popup,
    (SELECT count(*) FILTER (WHERE otype = 'checkbox') FROM typ)         AS chip_checkbox,
    (SELECT count(*) FILTER (WHERE otype = 'radio') FROM typ)            AS chip_radio,
    (SELECT count(*) FILTER (WHERE otype = 'calendar') FROM typ)         AS chip_calendar,
    (SELECT count(*) FILTER (WHERE otype = 'button') FROM typ)           AS chip_button,
    (SELECT count(*) FILTER (WHERE otype = 'tab') FROM typ)              AS chip_tab,
    (SELECT count(*) FILTER (WHERE otype = 'chart') FROM typ)            AS chip_chart;
