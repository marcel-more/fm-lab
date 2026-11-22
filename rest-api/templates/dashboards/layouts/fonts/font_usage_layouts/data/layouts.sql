-- One row per layout with at least one font use that matches every filter (file,
-- theme, font, size, source, object type, search — per use). The filters decide
-- WHICH layouts appear; the font columns show the layout's whole font profile:
-- fonts = named fonts of the layout (the file default does not count as a font),
-- font_list = their names, default_objects = objects whose font is left to the
-- file default. hits = font uses that match the filters.
-- "Many fonts" (many = '1') keeps the layouts with more named fonts than font_max.
-- Default order: most fonts first.
-- Row click: font_usage_objects on this layout, filters handed on (_carry_*).
-- Arrow: the layout with the matching objects marked (_marks, at most 200 UUIDs
-- so the deep link stays short).
-- The search is the per-use `search` param of the shared rows; the shared
-- table-search block below reads `q`, which this dashboard never sets.
WITH
--#include shared/rows.sql
matching AS (
    SELECT * FROM fr_m
    WHERE m_file AND m_theme AND m_font AND m_size AND m_face AND m_source
      AND m_otype AND m_layout AND m_search
),
hits AS (
    SELECT File_Name, layout_uuid,
           any_value(Layout_Name)                                        AS layout_name,
           any_value(theme)                                              AS theme,
           count(*)                                                      AS hits,
           list_sort(list(DISTINCT Object_UUID))                         AS objs
    FROM matching
    GROUP BY File_Name, layout_uuid
),
profile AS (
    SELECT r.File_Name, r.layout_uuid,
           count(DISTINCT r.font_key) FILTER (WHERE r.source <> 'default') AS fonts,
           string_agg(DISTINCT r.font_display, ', ' ORDER BY r.font_display)
               FILTER (WHERE r.source <> 'default')                     AS font_list,
           count(DISTINCT r.Object_UUID) FILTER (WHERE r.source = 'default') AS default_objects
    FROM fr_m r
    SEMI JOIN hits h ON h.File_Name = r.File_Name AND h.layout_uuid = r.layout_uuid
    GROUP BY r.File_Name, r.layout_uuid
),
unkeyed AS MATERIALIZED (
    SELECT
        h.File_Name                                                      AS file_name,
        h.layout_name,
        h.theme,
        pr.fonts,
        pr.font_list,
        h.hits,
        pr.default_objects,
        h.layout_uuid                                                    AS nav_uuid,
        array_to_string(list_slice(h.objs, 1, 200), ',')                 AS _marks,
        coalesce(p.c_search, '')                                         AS _carry_search,
        coalesce(p.c_file, '')                                           AS _carry_file,
        coalesce(p.c_theme, '')                                          AS _carry_theme,
        coalesce(p.c_font, '')                                           AS _carry_font,
        coalesce(p.c_size, '')                                           AS _carry_size,
        coalesce(p.c_source, '')                                         AS _carry_source,
        coalesce(p.c_otype, '')                                          AS _carry_otype
    FROM hits h
    JOIN profile pr ON pr.File_Name = h.File_Name AND pr.layout_uuid = h.layout_uuid
    CROSS JOIN fr_p p
    WHERE p.p_many IS NULL OR pr.fonts > p.p_font_max
),
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.fonts DESC, u.hits DESC, u.file_name, u.layout_name, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 100), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*, pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
