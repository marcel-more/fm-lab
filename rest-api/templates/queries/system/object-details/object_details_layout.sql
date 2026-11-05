-- @template_type: content
-- @description: SVG visualization of all layout objects with color-coded rectangles, layout parts, and correct nesting
-- @params: uuid (optional), name (optional), id (optional), file (optional)
-- @output_format: content
-- @author: Marcel
-- @version: 2.0
-- @tags: layouts, objects, svg, visualization, parts
-- @note: Use generic parameters: uuid, name, file (consistent with REST API)
-- @note: Returns SVG markup - save as .svg or embed in HTML
-- @note: v2.0 - Layout-Parts visualization + recursive coordinate fix for nested objects

WITH RECURSIVE layout_match AS (
  SELECT L_ID, L_Name, L_UUID, L_TO_Name, File_Name
  FROM Layouts
  -- Clone-Scoping: L_UUID/L_ID sind in geklonten Lösungen nicht eindeutig → in JEDEM
  -- Zweig auf die aufgelöste Datei einschränken (getvariable('file')=NULL → Downgrade).
  -- Sonst zog der UUID-Pfad (get-details) via LIMIT 1 einen beliebigen Klon.
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
layout_parts_data AS (
  SELECT
    lp.Part_Type,
    lp.Part_Kind,
    lp.Part_Size,
    lp.Part_Absolute,
    lp.Object_Count
  FROM LayoutParts lp
  JOIN layout_match lm ON lp.Layout_ID = lm.L_ID
    AND lp.File_Name = lm.File_Name
),
layout_objects_raw AS (
  SELECT
    lo.Object_ID,
    lo.Object_Type,
    lo.Object_Name,
    lo.Object_UUID,
    lo.Bounds_Top,
    lo.Bounds_Left,
    lo.Bounds_Bottom,
    lo.Bounds_Right,
    lo.Parent_Object_ID,
    lo.Nesting_Level,
    lo.Part_Type,
    lo.Layout_ID,
    lo.File_Name
  FROM LayoutObjects lo
  JOIN layout_match lm ON lo.Layout_ID = lm.L_ID
    AND lo.File_Name = lm.File_Name
),
-- Recursive CTE: convert relative child bounds to absolute layout coordinates
objects_absolute AS (
  -- Base: root objects (Level 0) - bounds are already absolute
  SELECT
    Object_ID, Object_Type, Object_Name, Object_UUID,
    Bounds_Top as Abs_Top,
    Bounds_Left as Abs_Left,
    Bounds_Bottom as Abs_Bottom,
    Bounds_Right as Abs_Right,
    Parent_Object_ID, Nesting_Level, Part_Type
  FROM layout_objects_raw
  WHERE Parent_Object_ID IS NULL

  UNION ALL

  -- Recursion: children - add parent absolute offset
  SELECT
    child.Object_ID, child.Object_Type, child.Object_Name, child.Object_UUID,
    parent.Abs_Top + child.Bounds_Top,
    parent.Abs_Left + child.Bounds_Left,
    parent.Abs_Top + child.Bounds_Bottom,
    parent.Abs_Left + child.Bounds_Right,
    child.Parent_Object_ID, child.Nesting_Level, child.Part_Type
  FROM layout_objects_raw child
  JOIN objects_absolute parent ON child.Parent_Object_ID = parent.Object_ID
),
layout_objects AS (
  SELECT
    oa.*,
    GREATEST(oa.Abs_Right - oa.Abs_Left, 1) as Width,
    GREATEST(oa.Abs_Bottom - oa.Abs_Top, 1) as Height
  FROM objects_absolute oa
),
layout_dims AS (
  SELECT
    LEAST(
      COALESCE(MIN(lo.Abs_Left), 0),
      COALESCE((SELECT MIN(0) FROM layout_parts_data), 0)
    ) as min_x,
    LEAST(
      COALESCE(MIN(lo.Abs_Top), 0),
      COALESCE((SELECT MIN(Part_Absolute) FROM layout_parts_data), 0)
    ) as min_y,
    COALESCE(MAX(lo.Abs_Right), 800) as max_x,
    GREATEST(
      COALESCE(MAX(lo.Abs_Bottom), 600),
      COALESCE((SELECT MAX(Part_Absolute + Part_Size) FROM layout_parts_data), 600)
    ) as max_y
  FROM layout_objects lo
),
object_styles AS (
  SELECT
    lo.*,
    CASE
      WHEN lo.Object_Type IN ('Edit Box', 'Drop-down List', 'Pop-up Menu',
                               'Radio Button Set', 'Checkbox Set', 'Drop-down Calendar')
        THEN '#cce5ff'
      WHEN lo.Object_Type IN ('Text', 'Graphic', 'Container', 'Web Viewer', 'Chart')
        THEN '#e2e3e5'
      WHEN lo.Object_Type IN ('Button', 'Grouped Button', 'Button Bar', 'Popover Button')
        THEN '#d4edda'
      WHEN lo.Object_Type IN ('Portal', 'Group', 'Tab Control', 'Panel',
                               'Slide Control', 'PopoverPanel')
        THEN '#fff3cd'
      WHEN lo.Object_Type IN ('Rectangle', 'Line', 'Oval')
        THEN '#f8d7da'
      ELSE '#f0f0f0'
    END as fill_color,
    CASE
      WHEN lo.Object_Type IN ('Edit Box', 'Drop-down List', 'Pop-up Menu',
                               'Radio Button Set', 'Checkbox Set', 'Drop-down Calendar')
        THEN '#004085'
      WHEN lo.Object_Type IN ('Text', 'Graphic', 'Container', 'Web Viewer', 'Chart')
        THEN '#383d41'
      WHEN lo.Object_Type IN ('Button', 'Grouped Button', 'Button Bar', 'Popover Button')
        THEN '#155724'
      WHEN lo.Object_Type IN ('Portal', 'Group', 'Tab Control', 'Panel',
                               'Slide Control', 'PopoverPanel')
        THEN '#856404'
      WHEN lo.Object_Type IN ('Rectangle', 'Line', 'Oval')
        THEN '#721c24'
      ELSE '#666666'
    END as stroke_color,
    CASE
      WHEN lo.Object_Type IN ('Portal', 'Group', 'Tab Control', 'Panel',
                               'Slide Control', 'PopoverPanel')
        THEN ' stroke-dasharray="5,3"'
      ELSE ''
    END as stroke_style,
    LEFT(
      replace(replace(replace(replace(
        COALESCE(NULLIF(lo.Object_Name, ''), lo.Object_Type),
        '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'),
      25
    ) as label,
    replace(replace(replace(replace(
      COALESCE(NULLIF(lo.Object_Name, ''), lo.Object_Type) || ' (' || lo.Object_Type || ')',
      '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
    as tooltip
  FROM layout_objects lo
)

SELECT content FROM (
  -- SVG Header
  SELECT 0 as sort_key, 0 as sub_key,
    '<?xml version="1.0" encoding="UTF-8"?>'
    || chr(10)
    || '<svg xmlns="http://www.w3.org/2000/svg"'
    || ' viewBox="' || (d.min_x - 20) || ' ' || (d.min_y - 40) || ' '
    || (d.max_x - d.min_x + 40) || ' ' || (d.max_y - d.min_y + 60) || '"'
    || ' style="background:#ffffff;">'
    || chr(10)
    || '<title>' || replace(replace(lm.L_Name, '&', '&amp;'), '<', '&lt;') || '</title>'
    || chr(10)
    || '<style>'
    || chr(10)
    || '  .obj-label { font-family: -apple-system, "Segoe UI", Arial, sans-serif; font-size: 9px; fill: #333; pointer-events: none; }'
    || chr(10)
    || '  .part-label { font-family: -apple-system, "Segoe UI", Arial, sans-serif; font-size: 11px; fill: #999; font-weight: bold; }'
    || chr(10)
    || '  .title-label { font-family: -apple-system, "Segoe UI", Arial, sans-serif; font-size: 14px; fill: #333; font-weight: bold; }'
    || chr(10)
    || '</style>'
    as content
  FROM layout_dims d
  CROSS JOIN layout_match lm

  UNION ALL

  -- Layout Parts background areas
  SELECT 1 as sort_key,
    lp.Part_Kind as sub_key,
    '<rect x="' || (d.min_x - 5) || '" y="' || lp.Part_Absolute || '"'
    || ' width="' || (d.max_x - d.min_x + 10) || '" height="' || lp.Part_Size || '"'
    || ' fill="' || CASE lp.Part_Type
        WHEN 'Header' THEN '#f0f4ff'
        WHEN 'Footer' THEN '#fff8f0'
        ELSE '#f8f9fa'
      END || '" fill-opacity="0.4"'
    || ' stroke="#cccccc" stroke-width="0.5" stroke-dasharray="4,2"/>'
    || chr(10)
    || '<text x="' || (d.min_x - 2) || '" y="' || (lp.Part_Absolute + 12) || '"'
    || ' class="part-label">'
    || lp.Part_Type || '</text>'
    as content
  FROM layout_parts_data lp
  CROSS JOIN layout_dims d

  UNION ALL

  -- Layout title text
  SELECT 2 as sort_key, 0 as sub_key,
    '<text x="' || d.min_x || '" y="' || (d.min_y - 10) || '" class="title-label">'
    || replace(replace(lm.L_Name, '&', '&amp;'), '<', '&lt;')
    || ' (' || replace(replace(COALESCE(lm.L_TO_Name, ''), '&', '&amp;'), '<', '&lt;') || ')'
    || '</text>'
    as content
  FROM layout_dims d
  CROSS JOIN layout_match lm

  UNION ALL

  -- Layout object rectangles + labels (with absolute coordinates)
  SELECT 3 as sort_key,
    (os.Nesting_Level * 1000000 + os.Object_ID) as sub_key,
    '<g>'
    || '<rect x="' || os.Abs_Left || '" y="' || os.Abs_Top || '"'
    || ' width="' || os.Width || '" height="' || os.Height || '"'
    || ' fill="' || os.fill_color || '" fill-opacity="0.6"'
    || ' stroke="' || os.stroke_color || '" stroke-width="1"'
    || os.stroke_style
    || ' rx="2" ry="2">'
    || '<title>' || os.tooltip || '</title>'
    || '</rect>'
    || CASE
         WHEN os.Height >= 14 AND os.Width >= 30 THEN
           '<text x="' || (os.Abs_Left + os.Width / 2) || '"'
           || ' y="' || (os.Abs_Top + os.Height / 2 + 3) || '"'
           || ' text-anchor="middle" class="obj-label">'
           || os.label
           || '</text>'
         ELSE ''
       END
    || '</g>'
    as content
  FROM object_styles os

  UNION ALL

  -- SVG Footer
  SELECT 9 as sort_key, 0 as sub_key,
    '</svg>' as content
  FROM layout_match
) svg_output
ORDER BY sort_key, sub_key;
