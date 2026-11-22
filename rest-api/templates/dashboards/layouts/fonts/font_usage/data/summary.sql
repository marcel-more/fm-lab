-- One row: the tiles of the font overview — fonts, uses with a named font, the
-- layouts and files that show one, and the objects whose font is left to the file
-- default (the theme names none: Classic, Minimalist). Filtered like the font
-- list (file, theme, size, search); the tiles hand the filters on (_carry_*).
WITH
--#include shared/rows.sql
lens AS (
    SELECT * FROM fr_m
    WHERE m_file AND m_theme AND m_size AND m_face AND m_otype AND m_layout AND m_search
)
SELECT
    count(DISTINCT font_key) FILTER (WHERE source <> 'default')                     AS fonts,
    count(*) FILTER (WHERE source <> 'default')                                     AS named_uses,
    count(DISTINCT (File_Name, layout_uuid)) FILTER (WHERE source <> 'default')     AS named_layouts,
    count(DISTINCT File_Name) FILTER (WHERE source <> 'default')                    AS named_files,
    count(DISTINCT (File_Name, Object_UUID)) FILTER (WHERE source = 'default')      AS default_objects,
    any_value(coalesce(p.c_search, ''))                                            AS _carry_search,
    any_value(coalesce(p.c_file, ''))                                              AS _carry_file,
    any_value(coalesce(p.c_theme, ''))                                             AS _carry_theme,
    any_value(coalesce(p.c_size, ''))                                              AS _carry_size
FROM fr_p p
LEFT JOIN lens ON TRUE;
