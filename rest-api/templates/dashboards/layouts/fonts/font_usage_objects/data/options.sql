-- Options of one filter select (dataset param `dim`: file, theme, font, size,
-- layout), shared by the font dashboards — byte-identical in every bundle
-- (unit test dashboard-font-blocks).
-- An option lists a value that still occurs under all OTHER filters, search
-- included, with its number of font uses. A selected value stays listed with
-- (0), so it can be deselected. Order: sizes by number, the rest by caption.
-- The font select offers named fonts only — the file default is a source
-- (chip), not a font.
WITH
--#include shared/rows.sql
fr_dim AS (
    SELECT CAST(getvariable('dim') AS VARCHAR) AS d
),
cand AS (
    SELECT
        CASE d.d WHEN 'file'   THEN m.File_Name
                 WHEN 'theme'  THEN m.theme_k
                 WHEN 'font'   THEN m.font_key
                 WHEN 'size'   THEN m.size
                 WHEN 'layout' THEN m.layout_uuid
        END                                                              AS value,
        CASE d.d WHEN 'font'   THEN m.font_display
                 WHEN 'layout' THEN m.File_Name || ' › ' || m.Layout_Name
                 WHEN 'theme'  THEN m.theme_k
                 WHEN 'size'   THEN m.size
                 ELSE m.File_Name
        END                                                              AS caption,
        m.size_num
    FROM fr_m m, fr_dim d
    WHERE (d.d = 'file'   OR m.m_file)
      AND (d.d = 'theme'  OR m.m_theme)
      AND (d.d = 'font'   OR m.m_font)
      AND (d.d = 'size'   OR m.m_size)
      AND (d.d = 'layout' OR m.m_layout)
      AND m.m_face AND m.m_source AND m.m_otype AND m.m_search
),
counted AS (
    SELECT value, any_value(caption) AS caption, min(size_num) AS size_num, count(*) AS n
    FROM cand
    WHERE value IS NOT NULL
    GROUP BY value
),
selected AS (
    SELECT unnest(CASE d.d WHEN 'file'   THEN p.p_files
                           WHEN 'theme'  THEN p.p_themes
                           WHEN 'font'   THEN p.p_fonts
                           WHEN 'size'   THEN p.p_sizes
                           WHEN 'layout' THEN CASE WHEN p.p_layout IS NOT NULL THEN [p.p_layout] END
                  END) AS value
    FROM fr_p p, fr_dim d
),
missing AS (
    -- a selected value without a use under the other filters: caption from any row
    SELECT s.value,
           coalesce(any_value(CASE d.d WHEN 'font'   THEN r.font_display
                                       WHEN 'layout' THEN r.File_Name || ' › ' || r.Layout_Name
                              END), s.value)                              AS caption,
           TRY_CAST(regexp_extract(s.value, '^([0-9]+(\.[0-9]+)?)', 1) AS DOUBLE) AS size_num,
           0                                                              AS n
    FROM selected s
    CROSS JOIN fr_dim d
    LEFT JOIN fr_rows r
           ON (d.d = 'font' AND r.font_key = s.value) OR (d.d = 'layout' AND r.layout_uuid = s.value)
    WHERE s.value IS NOT NULL AND s.value NOT IN (SELECT value FROM counted)
    GROUP BY s.value
)
SELECT o.value,
       o.caption || ' (' || o.n || ')'                                   AS label,
       o.n
FROM (SELECT * FROM counted UNION ALL SELECT * FROM missing) o, fr_dim d
ORDER BY CASE WHEN d.d = 'size' THEN o.size_num END NULLS LAST, lower(o.caption), o.value;
