-- @template_type: report
-- @description: Structured detail of a layout part (section) — kind, position among the layout's parts, geometry, break field, context (layout, TO, base table), part definition options incl. the row-state cascade
-- @params: uuid (required), file (optional, clone-scoping)
-- @output_format: json
-- @author: Marcel
-- @version: 1.1
-- @tags: layouts, parts, details
-- @note: One row with `section` = 'meta': part scalars, neighbours, break field, layout
--          context, part options and the effective row state with its origin. The objects
--          of the part are listed by GET /api/references (read path parent_part, from
--          LayoutObjects.Part_Seq — schema 1.39.0); v1.0 had a type_breakdown section.
-- @note: The part is matched by its catalog key
--        'part_' || Layout_ID || '_' || Part_Kind || '_' || Part_Seq || '_' || File_Name
--        (identical to the import), never by splitting the string.
-- @note: Row state ("alternate row state" / "use active row state") is CSS, not an option
--        bit. Cascade (body parts only, kind 4): local value of the part → named part style
--        of the layout's theme → theme default rule `body` → off. `*_source` names the stage:
--        'local' | 'style' | 'theme' | 'default'. Classic themes carry no rule → 'default'.
-- @note: Break field: UUID/file from the breaks_on_field edge (the import heals foreign
--        UUIDs via TO + field id); without an edge the raw name stays, uuid NULL.

WITH part_match AS (
  SELECT lp.*
  FROM LayoutParts lp
  WHERE 'part_' || CAST(lp.Layout_ID AS VARCHAR) || '_' || CAST(lp.Part_Kind AS VARCHAR) || '_'
          || CAST(lp.Part_Seq AS VARCHAR) || '_' || lp.File_Name = getvariable('uuid')
    AND (getvariable('file') IS NULL OR lp.File_Name = getvariable('file'))
  LIMIT 1
),
pm AS (
  SELECT p.*,
    'part_' || CAST(p.Layout_ID AS VARCHAR) || '_' || CAST(p.Part_Kind AS VARCHAR) || '_'
      || CAST(p.Part_Seq AS VARCHAR) || '_' || p.File_Name AS part_uuid
  FROM part_match p
),
layout_info AS (
  SELECT l.L_ID, l.L_Name, l.L_UUID, l.L_TO_Name, l.L_TO_UUID,
         l.L_Theme_Resolved_Name, l.L_Theme_Resolved_UUID, l.File_Name
  FROM Layouts l
  JOIN pm ON l.L_ID = pm.Layout_ID AND l.File_Name = pm.File_Name
  LIMIT 1
),
siblings AS (
  SELECT
    s.Part_Seq, s.Part_Kind, s.Part_Type, s.Break_Field_Name,
    'part_' || CAST(s.Layout_ID AS VARCHAR) || '_' || CAST(s.Part_Kind AS VARCHAR) || '_'
      || CAST(s.Part_Seq AS VARCHAR) || '_' || s.File_Name AS part_uuid,
    row_number() OVER (ORDER BY s.Part_Absolute, s.Part_Seq) AS pos,
    count(*) OVER () AS total
  FROM LayoutParts s
  JOIN pm ON s.Layout_ID = pm.Layout_ID AND s.File_Name = pm.File_Name
),
me AS (SELECT pos, total FROM siblings WHERE Part_Seq = (SELECT Part_Seq FROM pm)),
prev_part AS (SELECT * FROM siblings WHERE pos = (SELECT pos FROM me) - 1),
next_part AS (SELECT * FROM siblings WHERE pos = (SELECT pos FROM me) + 1),
break_edge AS (
  SELECT
    arg_min(ol.Target_UUID, ol.Target_File) AS field_uuid,
    arg_min(ol.Target_File, ol.Target_File) AS field_file
  FROM ObjectLinks ol
  JOIN pm ON ol.Source_UUID = pm.part_uuid AND ol.Source_File = pm.File_Name
  WHERE ol.Link_Role = 'breaks_on_field'
),
-- TOs liegen datei-lokal; die Basistabelle einer externen TO liegt in einer anderen
-- Datei → über die base_table-Kante der TO (Target_File) statt BT_UUID allein.
layout_to AS (
  SELECT toc.TO_UUID, toc.TO_Name, toc.File_Name
  FROM TableOccurrenceCatalog toc
  JOIN layout_info li ON toc.TO_UUID = li.L_TO_UUID AND toc.File_Name = li.File_Name
  LIMIT 1
),
layout_bt AS (
  SELECT oc.Object_UUID AS bt_uuid, oc.Object_Name AS bt_name, oc.File_Name AS bt_file
  FROM ObjectLinks ol
  JOIN layout_to lt ON ol.Source_UUID = lt.TO_UUID AND ol.Source_File = lt.File_Name
  JOIN ObjectCatalog oc ON oc.Object_UUID = ol.Target_UUID AND oc.File_Name = ol.Target_File
  WHERE ol.Link_Role = 'base_table'
  LIMIT 1
),
break_to AS (
  SELECT toc.TO_UUID, toc.TO_Name
  FROM TableOccurrenceCatalog toc
  JOIN pm ON toc.TO_UUID = pm.Break_TO_UUID AND toc.File_Name = pm.File_Name
  LIMIT 1
),
theme AS (
  SELECT tc.Theme_UUID, tc.Theme_Name, tc.Theme_Display
  FROM ThemeCatalog tc
  JOIN layout_info li ON tc.Theme_UUID = li.L_Theme_Resolved_UUID AND tc.File_Name = li.File_Name
  LIMIT 1
),
style_rule AS (
  SELECT tps.Alt_Background, tps.Active_Row_Style
  FROM ThemePartStyles tps
  JOIN layout_info li ON tps.Theme_UUID = li.L_Theme_Resolved_UUID AND tps.File_Name = li.File_Name
  WHERE tps.Style_Name = (SELECT Part_LocalCSS_Name FROM pm)
  LIMIT 1
),
body_rule AS (
  SELECT tps.Alt_Background, tps.Active_Row_Style
  FROM ThemePartStyles tps
  JOIN layout_info li ON tps.Theme_UUID = li.L_Theme_Resolved_UUID AND tps.File_Name = li.File_Name
  WHERE tps.Style_Name = 'body'
  LIMIT 1
),
objects_in_part AS (
  SELECT lo.Object_Type, lo.Nesting_Level
  FROM LayoutObjects lo
  JOIN pm ON lo.Layout_ID = pm.Layout_ID AND lo.File_Name = pm.File_Name
   AND lo.Part_Seq = pm.Part_Seq
),
meta_row AS (
  SELECT
    'meta'                                   AS section,
    pm.part_uuid                             AS part_uuid,
    pm.Part_Seq                              AS part_seq,
    pm.Part_Kind                             AS part_kind,
    pm.Part_Type                             AS part_type,
    pm.Definition_Type                       AS definition_type,
    pm.Part_Name                             AS part_name,
    pm.Part_Size                             AS part_size,
    pm.Part_Absolute                         AS part_top,
    pm.Part_Absolute + pm.Part_Size          AS part_bottom,
    pm.Part_Options                          AS part_options,
    pm.Part_Break_Every                      AS break_every,
    pm.Object_Count                          AS object_count_root,
    (SELECT count(*) FROM objects_in_part)   AS object_count_total,
    (SELECT pos FROM me)                     AS part_position,
    (SELECT total FROM me)                   AS part_total,
    (SELECT part_uuid FROM prev_part)        AS prev_part_uuid,
    (SELECT Part_Kind FROM prev_part)        AS prev_part_kind,
    (SELECT Part_Type FROM prev_part)        AS prev_part_type,
    (SELECT Break_Field_Name FROM prev_part) AS prev_part_break_field,
    (SELECT part_uuid FROM next_part)        AS next_part_uuid,
    (SELECT Part_Kind FROM next_part)        AS next_part_kind,
    (SELECT Part_Type FROM next_part)        AS next_part_type,
    (SELECT Break_Field_Name FROM next_part) AS next_part_break_field,
    pm.Break_Field_ID                        AS break_field_id,
    pm.Break_Field_Name                      AS break_field_name,
    (SELECT field_uuid FROM break_edge)      AS break_field_uuid,
    (SELECT field_file FROM break_edge)      AS break_field_file,
    pm.Break_TO_Name                         AS break_to_name,
    (SELECT TO_UUID FROM break_to)           AS break_to_uuid,
    li.L_UUID                                AS layout_uuid,
    li.L_Name                                AS layout_name,
    li.L_ID                                  AS layout_id,
    li.L_TO_Name                             AS layout_to_name,
    (SELECT TO_UUID FROM layout_to)          AS layout_to_uuid,
    (SELECT bt_name FROM layout_bt)          AS base_table_name,
    (SELECT bt_uuid FROM layout_bt)          AS base_table_uuid,
    (SELECT bt_file FROM layout_bt)          AS base_table_file,
    pm.File_Name                             AS file_name,
    pm.Part_LocalCSS_Name                    AS local_style_name,
    pm.Part_LocalCSS_Type                    AS local_style_type,
    li.L_Theme_Resolved_Name                 AS theme_name,
    (SELECT Theme_Display FROM theme)        AS theme_display,
    li.L_Theme_Resolved_UUID                 AS theme_uuid,
    (li.L_Theme_Resolved_Name = 'com.filemaker.theme.classic') AS theme_is_classic,
    -- Row state (kind 4 only, sonst NULL = nicht anwendbar)
    CASE WHEN pm.Part_Kind = 4 THEN COALESCE(
        pm.Part_Alt_Row_Local,
        (SELECT Alt_Background FROM style_rule),
        (SELECT Alt_Background FROM body_rule),
        FALSE) END                           AS alt_row,
    CASE WHEN pm.Part_Kind <> 4 THEN NULL
         WHEN pm.Part_Alt_Row_Local IS NOT NULL THEN 'local'
         WHEN (SELECT Alt_Background FROM style_rule) IS NOT NULL THEN 'style'
         WHEN (SELECT Alt_Background FROM body_rule) IS NOT NULL THEN 'theme'
         ELSE 'default' END                  AS alt_row_source,
    CASE WHEN pm.Part_Kind = 4 THEN COALESCE(
        pm.Part_Active_Row_Local,
        (SELECT Active_Row_Style FROM style_rule),
        (SELECT Active_Row_Style FROM body_rule),
        FALSE) END                           AS active_row,
    CASE WHEN pm.Part_Kind <> 4 THEN NULL
         WHEN pm.Part_Active_Row_Local IS NOT NULL THEN 'local'
         WHEN (SELECT Active_Row_Style FROM style_rule) IS NOT NULL THEN 'style'
         WHEN (SELECT Active_Row_Style FROM body_rule) IS NOT NULL THEN 'theme'
         ELSE 'default' END                  AS active_row_source
  FROM pm
  LEFT JOIN layout_info li ON TRUE
)

SELECT * FROM meta_row;
