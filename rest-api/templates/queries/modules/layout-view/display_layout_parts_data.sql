-- @template_type: report
-- @description: Layout parts (Header / Body / Footer) of a layout with absolute geometry data
-- @params: uuid (optional), name (optional), id (optional), file (optional)
-- @output_format: report
-- @author: Marcel
-- @version: 1.0
-- @tags: layouts, parts, data, react
-- @note: Komplementärer Endpunkt zu display_layout_objects_data.sql für die interaktive
-- @note: Layout-Visualisierung. Frontend lädt beide parallel und rendert die Parts als
-- @note: Hintergrund-Streifen unter den Layout-Objekten.

WITH layout_match AS (
  SELECT L_ID, L_Name, L_UUID, L_TO_Name, File_Name
  FROM Layouts
  WHERE (
    (getvariable('uuid') IS NOT NULL AND L_UUID = getvariable('uuid'))
    OR
    (getvariable('name') IS NOT NULL AND L_Name = getvariable('name')
     AND (getvariable('file') IS NULL OR File_Name = getvariable('file')))
    OR
    (getvariable('id') IS NOT NULL AND L_ID = CAST(getvariable('id') AS INTEGER))
  )
  LIMIT 1
)

SELECT
  lp.Part_Type      AS part_type,
  lp.Part_Kind      AS part_kind,
  lp.Part_Size      AS part_size,
  lp.Part_Absolute  AS part_absolute,
  lp.Object_Count   AS object_count,
  lm.L_Name         AS layout_name,
  lm.L_UUID         AS layout_uuid,
  lm.L_TO_Name      AS layout_to_name,
  lm.File_Name      AS file_name
FROM LayoutParts lp
JOIN layout_match lm ON lp.Layout_ID = lm.L_ID
  AND lp.File_Name = lm.File_Name
ORDER BY lp.Part_Absolute;
