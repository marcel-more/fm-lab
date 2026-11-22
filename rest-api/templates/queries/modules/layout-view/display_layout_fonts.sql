-- @template_type: report
-- @description: Font uses and applied styles of one layout's objects, for the font and style filter of the layout canvas
-- @params: uuid (optional), name (optional), id (optional), file (optional)
-- @output_format: report
-- @author: Marcel
-- @version: 1.0
-- @tags: layouts, fonts, styles, react, interactive
-- @note: Needs catalog schema 1.45.0 (v_layout_object_font, LayoutObjectFontRuns,
-- @note: v_layout_object_style). On an older catalog the missing view answers
-- @note: SCHEMA_DRIFT (409) and the canvas shows the re-import notice instead of the
-- @note: filter row; the canvas itself does not read this template.
-- @note: Rows by kind
-- @note:   base       base font of every text-bearing object (v_layout_object_font)
-- @note:   rich_text  formatted text run with its own font
-- @note:   chart      chart text area (series titles left out, they keep the theme font)
-- @note:   style      object with an applied style (any object type)
-- @note: Objects without font and without style have no row: the canvas knows every
-- @note: object from display_layout_objects_data and counts "no style" itself.
-- @note: font_key, font_size and face are written like the shared rows block of the
-- @note: font dashboards (layouts/fonts/*/data/shared/rows.sql), so the URL values
-- @note: font, size and face mean the same in both: font_key '#default' = the font
-- @note: is left to the file default (not in the export, never named), font_size
-- @note: '12pt', face normal | bold | italic | bold italic.

WITH layout_match AS (
  SELECT L_ID, File_Name
  FROM Layouts
  WHERE (
    (getvariable('uuid') IS NOT NULL AND L_UUID = getvariable('uuid')
     AND (getvariable('file') IS NULL OR File_Name = getvariable('file')))
    OR
    (getvariable('name') IS NOT NULL AND L_Name = getvariable('name')
     AND (getvariable('file') IS NULL OR File_Name = getvariable('file')))
    OR
    (getvariable('id') IS NOT NULL AND L_ID = CAST(getvariable('id') AS INTEGER)
     AND (getvariable('file') IS NULL OR File_Name = getvariable('file')))
  )
  LIMIT 1
),
base AS (
  SELECT f.Object_UUID, f.File_Name, f.Font_Family, f.Font_Key, f.Font_Size,
         f.Font_Weight, f.Font_Style, f.Family_Source, f.Low_Confidence
  FROM v_layout_object_font f
  JOIN layout_match m ON m.L_ID = f.Layout_ID AND m.File_Name = f.File_Name
),
uses AS (
  SELECT b.Object_UUID                      AS object_uuid,
         'base'                             AS kind,
         b.Font_Family                      AS font,
         b.Font_Key                         AS font_key,
         b.Font_Size                        AS font_size,
         concat_ws(' ', NULLIF(b.Font_Weight, 'normal'), NULLIF(b.Font_Style, 'normal')) AS face,
         b.Family_Source                    AS family_source,
         b.Low_Confidence                   AS low_confidence,
         CAST(NULL AS VARCHAR)              AS detail
  FROM base b
  UNION ALL
  SELECT r.Object_UUID, 'rich_text', r.Font_Family, lower(r.Font_Family),
         CASE WHEN r.Font_Size IS NOT NULL
              THEN regexp_replace(CAST(r.Font_Size AS VARCHAR), '\.0$', '') || 'pt' END,
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), FALSE, r.Run_Text
  FROM base b
  JOIN LayoutObjectFontRuns r ON r.Object_UUID = b.Object_UUID AND r.File_Name = b.File_Name
  WHERE r.Source = 'rich_text' AND r.Font_Family IS NOT NULL
  UNION ALL
  -- charts are not text-bearing objects of the view; they come straight from the runs
  SELECT r.Object_UUID, 'chart', r.Font_Family, lower(r.Font_Family),
         CASE WHEN r.Font_Size IS NOT NULL
              THEN regexp_replace(CAST(r.Font_Size AS VARCHAR), '\.0$', '') || 'pt' END,
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), FALSE, r.Slot
  FROM LayoutObjectFontRuns r
  JOIN layout_match m ON m.L_ID = r.Layout_ID AND m.File_Name = r.File_Name
  WHERE r.Source = 'chart' AND r.Font_Family IS NOT NULL
    AND r.Slot NOT LIKE 'series%'
),
names AS (
  -- one display spelling per font key on this layout: a capitalised spelling wins over 'arial'
  SELECT font_key,
         arg_max(font, (CASE WHEN font <> lower(font) THEN 1000000000 ELSE 0 END) + n) AS font_display
  FROM (SELECT font_key, font, count(*) AS n FROM uses WHERE font_key IS NOT NULL GROUP BY ALL)
  GROUP BY font_key
)
SELECT u.object_uuid,
       u.kind,
       coalesce(u.font_key, '#default')                                       AS font_key,
       n.font_display,
       u.font_size,
       TRY_CAST(regexp_extract(u.font_size, '^([0-9]+(\.[0-9]+)?)', 1) AS DOUBLE) AS size_num,
       coalesce(NULLIF(u.face, ''), 'normal')                                 AS face,
       u.family_source,
       u.low_confidence,
       u.detail,
       CAST(NULL AS VARCHAR)                                                  AS style_name,
       CAST(NULL AS VARCHAR)                                                  AS style_display,
       CAST(NULL AS BOOLEAN)                                                  AS style_is_custom,
       CAST(NULL AS BOOLEAN)                                                  AS style_rule_missing
FROM uses u
LEFT JOIN names n ON n.font_key = u.font_key
UNION ALL BY NAME
SELECT s.Object_UUID                AS object_uuid,
       'style'                      AS kind,
       s.Style_Name                 AS style_name,
       s.Style_Display              AS style_display,
       s.Style_Is_Custom            AS style_is_custom,
       s.Style_Rule_Missing         AS style_rule_missing
FROM v_layout_object_style s
JOIN layout_match m ON m.L_ID = s.Layout_ID AND m.File_Name = s.File_Name
WHERE s.Style_Name IS NOT NULL
ORDER BY kind, object_uuid, font_key, detail;
