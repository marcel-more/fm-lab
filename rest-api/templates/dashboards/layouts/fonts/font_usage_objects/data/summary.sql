-- One row: the tiles of the object list and the counts of its chips.
--   uses / objects / layouts / uncertain   matching font uses
--   chip_src_*    uses per source under all other filters (source chips)
--   chip_face_*   uses per face under all other filters (face chips)
--   chip_*        uses per object type under all other filters (type chips)
WITH
--#include shared/rows.sql
matching AS (
    SELECT * FROM fr_m
    WHERE m_file AND m_theme AND m_font AND m_size AND m_face AND m_source
      AND m_otype AND m_layout AND m_search
),
src AS (
    SELECT source FROM fr_m
    WHERE m_file AND m_theme AND m_font AND m_size AND m_face AND m_otype AND m_layout AND m_search
),
fac AS (
    SELECT face_k FROM fr_m
    WHERE m_file AND m_theme AND m_font AND m_size AND m_source AND m_otype AND m_layout AND m_search
),
typ AS (
    SELECT otype FROM fr_m
    WHERE m_file AND m_theme AND m_font AND m_size AND m_face AND m_source AND m_layout AND m_search
)
SELECT
    (SELECT count(*) FROM matching)                                      AS uses,
    (SELECT count(DISTINCT (File_Name, Object_UUID)) FROM matching)      AS objects,
    (SELECT count(DISTINCT (File_Name, layout_uuid)) FROM matching)      AS layouts,
    (SELECT count(*) FILTER (WHERE low_confidence) FROM matching)        AS uncertain,
    (SELECT count(*) FILTER (WHERE source <> 'default') FROM src)        AS chip_src_named,
    (SELECT count(*) FILTER (WHERE source = 'local') FROM src)           AS chip_src_local,
    (SELECT count(*) FILTER (WHERE source = 'local_redundant') FROM src) AS chip_src_local_redundant,
    (SELECT count(*) FILTER (WHERE source = 'style') FROM src)           AS chip_src_style,
    (SELECT count(*) FILTER (WHERE source = 'theme') FROM src)           AS chip_src_theme,
    (SELECT count(*) FILTER (WHERE source = 'rich_text') FROM src)       AS chip_src_rich_text,
    (SELECT count(*) FILTER (WHERE source = 'chart') FROM src)           AS chip_src_chart,
    (SELECT count(*) FILTER (WHERE source = 'default') FROM src)         AS chip_src_default,
    (SELECT count(*) FROM src)                                           AS chip_src_all,
    (SELECT count(*) FROM fac)                                           AS chip_face_all,
    (SELECT count(*) FILTER (WHERE face_k = 'normal') FROM fac)          AS chip_face_normal,
    (SELECT count(*) FILTER (WHERE face_k = 'bold') FROM fac)            AS chip_face_bold,
    (SELECT count(*) FILTER (WHERE face_k = 'italic') FROM fac)          AS chip_face_italic,
    (SELECT count(*) FILTER (WHERE face_k = 'bold italic') FROM fac)     AS chip_face_bold_italic,
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
