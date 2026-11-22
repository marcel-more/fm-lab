-- @template_type: report
-- @description: Layouts that carry one style of a theme (design), with the number of objects per layout — loaded when a style row of the theme detail view is expanded
-- @params: uuid (required, theme UUID), style (required, style class), file (optional, clone-scoping)
-- @output_format: report
-- @author: Marcel
-- @version: 1.0
-- @tags: theme, design, styles, layouts, react, interactive
-- @note: One row per layout of the theme's file whose resolved theme is this theme and
-- @note: that has at least one object with the style (v_layout_object_style, schema 1.45.0).
-- @note: Most objects first, then by layout name. The row count is bounded by the layouts
-- @note: of one file; the client shows the first ones and offers the rest on demand.
-- @note: Loaded per style on demand, so the detail response grows with the number of
-- @note: styles, not with the number of (style, layout) pairs.

WITH theme AS (
  SELECT tc.Theme_UUID, tc.File_Name
  FROM ThemeCatalog tc
  WHERE tc.Theme_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR tc.File_Name = getvariable('file'))
  ORDER BY tc.File_Name
  LIMIT 1
)
SELECT
  s.Layout_UUID                    AS layout_uuid,
  any_value(s.Layout_Name)         AS layout_name,
  count(*)                         AS objects
FROM v_layout_object_style s
JOIN theme t ON s.Theme_UUID = t.Theme_UUID AND s.File_Name = t.File_Name
WHERE s.Style_Name = getvariable('style')
GROUP BY s.Layout_UUID
ORDER BY objects DESC, layout_name, layout_uuid;
