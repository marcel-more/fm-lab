-- @template_type: report
-- @description: Header attributes and named styles of a theme (design) for its detail view — custom and built-in styles with object type tokens and usage (objects, layouts) in the theme's file
-- @params: uuid (required), file (optional, clone-scoping)
-- @output_format: json
-- @author: Marcel
-- @version: 1.0
-- @tags: theme, design, styles, details, unused-code
-- @note: Companion of object_details_theme — the service appends these rows only when
--        ThemeNamedStyles exists (schema >= 1.46.0). Flat rows with a `section` discriminator:
--          'header'       → one row: ThemeCatalog header attributes, base theme (display name and
--                           UUID only when the base theme is imported in the same file), style counts.
--          'style'        → one row per named style (ThemeNamedStyles): class, Inspector name,
--                           custom flag, type tokens of its rules (ThemeStyleRules, the client
--                           translates them), objects and layouts using it.
--        The layouts of one style come from modules/theme-view/display_theme_style_layouts,
--        loaded when its row is expanded — the response grows with the number of styles, never
--        with the number of (style, layout) pairs (a heavily styled file reaches thousands).
-- @note: Usage counts only the theme's own file and only layouts whose resolved theme is this theme
--        (v_layout_object_style.Theme_UUID) — a theme cloned into another file has its own usage there.
-- @note: Themes without namedstyles (Classic, Minimalist) return only the header row
--        (has_named_styles = false).

WITH theme AS (
  SELECT tc.*
  FROM ThemeCatalog tc
  WHERE tc.Theme_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR tc.File_Name = getvariable('file'))
  ORDER BY tc.File_Name
  LIMIT 1
),
named AS (
  SELECT n.Style_Seq, n.Style_Class, n.Style_Display, n.Is_Custom
  FROM ThemeNamedStyles n
  JOIN theme t ON n.Theme_UUID = t.Theme_UUID AND n.File_Name = t.File_Name
),
tokens AS (
  SELECT r.Style_Class, list(DISTINCT r.Type_Token ORDER BY r.Type_Token) AS type_tokens
  FROM ThemeStyleRules r
  JOIN theme t ON r.Theme_UUID = t.Theme_UUID AND r.File_Name = t.File_Name
  WHERE r.Style_Class IS NOT NULL AND r.Type_Token IS NOT NULL
  GROUP BY r.Style_Class
),
usage AS (
  SELECT s.Style_Name AS Style_Class, count(*) AS objects, count(DISTINCT s.Layout_UUID) AS layouts
  FROM v_layout_object_style s
  JOIN theme t ON s.Theme_UUID = t.Theme_UUID AND s.File_Name = t.File_Name
  WHERE s.Style_Name IN (SELECT Style_Class FROM named)
  GROUP BY s.Style_Name
),
styles AS (
  SELECT n.*, coalesce(tk.type_tokens, []) AS type_tokens,
         coalesce(u.objects, 0) AS objects, coalesce(u.layouts, 0) AS layouts
  FROM named n
  LEFT JOIN tokens tk ON tk.Style_Class = n.Style_Class
  LEFT JOIN usage u   ON u.Style_Class = n.Style_Class
),
base AS (
  SELECT b.Theme_UUID, coalesce(b.Theme_Display, b.Theme_Name) AS display
  FROM ThemeCatalog b
  JOIN theme t ON b.File_Name = t.File_Name AND b.Theme_Name = t.Base_Name
  ORDER BY b.Theme_ID
  LIMIT 1
)
SELECT
  'header'                                                        AS section,
  t.Theme_Group                                                   AS theme_group,
  (t.Theme_Group = 'Custom')                                      AS is_custom_theme,
  t.Base_Name                                                     AS base_name,
  t.Base_Version                                                  AS base_version,
  (SELECT Theme_UUID FROM base)                                   AS base_uuid,
  (SELECT display FROM base)                                      AS base_display,
  t.Theme_Version                                                 AS theme_version,
  t.Theme_Locale                                                  AS theme_locale,
  t.Theme_Platform                                                AS theme_platform,
  t.Is_Default                                                    AS is_default,
  (SELECT count(*) > 0 FROM named)                                AS has_named_styles,
  (SELECT count(*) FROM styles WHERE Is_Custom)                   AS custom_count,
  (SELECT count(*) FROM styles WHERE Is_Custom AND objects > 0)   AS custom_used,
  (SELECT count(*) FROM styles WHERE NOT Is_Custom)               AS builtin_count,
  (SELECT count(*) FROM styles WHERE NOT Is_Custom AND objects > 0) AS builtin_used
FROM theme t

UNION ALL BY NAME

SELECT
  'style'           AS section,
  Style_Seq         AS style_seq,
  Style_Class       AS style_class,
  Style_Display     AS style_display,
  Is_Custom         AS is_custom,
  type_tokens,
  objects,
  layouts
FROM styles;
