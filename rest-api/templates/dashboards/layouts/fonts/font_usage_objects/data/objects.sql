-- One row per font use: the base font of an object, a formatted text run with its
-- own font, a chart text area — filtered by every filter (file, theme, font, size,
-- face, source, object type, layout, search per use). By default the uses whose
-- font is left to the file default stay out (source '' = named fonts only).
-- font is '#default' for those uses (caption: valueLabels in the layout).
-- Default order: file, layout, object, base font before its runs.
-- Row click: the layout object (ref = layout). Arrow: the layout with the object
-- marked (ref = object).
-- The search is the per-use `search` param of the shared rows; the shared
-- table-search block below reads `q`, which this dashboard never sets.
WITH
--#include shared/rows.sql
unkeyed AS MATERIALIZED (
    SELECT
        r.File_Name                                                      AS file_name,
        r.Layout_Name                                                    AS layout_name,
        r.Object_Type                                                    AS object_type,
        r.object_label                                                   AS object,
        CASE WHEN r.source = 'default' THEN '#default' ELSE r.font_display END AS font,
        r.size,
        r.size_num                                                       AS _sort_size,
        r.face_k                                                         AS face,
        r.source,
        r.Style_Display                                                  AS style,
        r.detail,
        r.low_confidence,
        r.Object_UUID                                                    AS nav_uuid,
        r.layout_uuid                                                    AS _layout_uuid,
        CASE r.kind WHEN 'base' THEN 0 WHEN 'rich_text' THEN 1 ELSE 2 END AS _ord
    FROM fr_m r
    WHERE m_file AND m_theme AND m_font AND m_size AND m_face AND m_source
      AND m_otype AND m_layout AND m_search
),
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord),
           row_number() OVER (ORDER BY u.file_name, u.layout_name, u.object, u.nav_uuid, u._ord, u) AS row_key
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
