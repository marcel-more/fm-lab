-- @template_type: report
-- @description: Structured detail of a theme (design) — display and internal name plus the number of layouts using it; reads only columns every catalog has
-- @params: uuid (required), file (optional, clone-scoping)
-- @output_format: json
-- @author: Marcel
-- @version: 2.0
-- @tags: theme, design, details
-- @note: One row with `section` = 'meta'. Header attributes and the style list come from the
--        companion object_details_theme_styles (schema >= 1.46.0), which the service appends
--        only when ThemeNamedStyles exists — so this template stays valid on older catalogs
--        (`theme_styles.available` drives the client notice). v1.0 was a text block with the
--        uses_theme references; the references tab lists them.
-- @note: Object_Name in the catalog is the localized display name (e.g. "Apex Blau"); the
--        internal name (com.filemaker.theme.*) comes from ThemeCatalog.
-- @note: layout_count = distinct layouts with a uses_theme edge to this theme in its file.

WITH theme AS (
  SELECT tc.Theme_UUID, tc.Theme_ID, tc.Theme_Name, tc.Theme_Display, tc.File_Name
  FROM ThemeCatalog tc
  WHERE tc.Theme_UUID = getvariable('uuid')
    -- Clone scoping: Theme_UUID is unique per file only
    AND (getvariable('file') IS NULL OR tc.File_Name = getvariable('file'))
  ORDER BY tc.File_Name
  LIMIT 1
),
layouts AS (
  SELECT count(DISTINCT ol.Source_UUID) AS n
  FROM ObjectLinks ol
  JOIN theme t ON ol.Target_UUID = t.Theme_UUID AND ol.Target_File = t.File_Name
  WHERE ol.Link_Role = 'uses_theme'
)
SELECT
  'meta'                                                   AS section,
  t.Theme_UUID                                             AS theme_uuid,
  t.Theme_ID                                               AS theme_id,
  t.Theme_Name                                             AS internal_name,
  coalesce(t.Theme_Display, t.Theme_Name)                  AS display_name,
  t.File_Name                                              AS file_name,
  (t.Theme_Name = 'com.filemaker.theme.classic')           AS is_classic,
  (SELECT n FROM layouts)                                  AS layout_count
FROM theme t;
