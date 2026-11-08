-- @template_type: report
-- @description: Layout parts (Header / Body / Footer …) of a layout with absolute geometry, sequence, catalog UUID and break field
-- @params: uuid (optional), name (optional), id (optional), file (optional)
-- @output_format: report
-- @author: Marcel
-- @version: 2.0
-- @tags: layouts, parts, data, react
-- @note: Komplementärer Endpunkt zu display_layout_objects_data.sql für die interaktive
-- @note: Layout-Visualisierung. Frontend lädt beide parallel und rendert die Parts als
-- @note: Hintergrund-Streifen unter den Layout-Objekten.
-- @note: v2.0 — part_seq (Identität eines Parts im Layout; mehrere Zwischenergebnisse
-- @note: gleicher Art bleiben unterscheidbar), part_uuid (= Katalog-UUID
-- @note: part_<Layout_ID>_<Part_Kind>_<Part_Seq>_<File_Name>, Detailansicht), part_name und
-- @note: das Umbruchfeld der Zwischenergebnisse. Feld-UUID/-Datei kommen aus der
-- @note: breaks_on_field-Kante (Import heilt Fremd-UUIDs über TO + Feld-ID).
-- @note: Part_Name (Schema 1.39.0) wird über UNION ALL BY NAME eingeblendet → auf älteren
-- @note: Katalogen NULL statt Binder-Fehler (der Canvas bleibt nutzbar).

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
),
parts AS (
  -- Schema-tolerant: Spalten neuerer Schemata fehlen in alten Katalogen → NULL.
  SELECT * FROM (
    SELECT lp.* FROM LayoutParts lp
    JOIN layout_match lm ON lp.Layout_ID = lm.L_ID AND lp.File_Name = lm.File_Name
    UNION ALL BY NAME
    SELECT CAST(NULL AS VARCHAR) AS Part_Name WHERE false
  )
),
part_keys AS (
  SELECT
    p.*,
    'part_' || CAST(p.Layout_ID AS VARCHAR) || '_' || CAST(p.Part_Kind AS VARCHAR) || '_'
      || CAST(p.Part_Seq AS VARCHAR) || '_' || p.File_Name AS part_uuid
  FROM parts p
),
break_targets AS (
  SELECT
    ol.Source_UUID                              AS part_uuid,
    arg_min(ol.Target_UUID, ol.Target_File)     AS break_field_uuid,
    arg_min(ol.Target_File, ol.Target_File)     AS break_field_file
  FROM ObjectLinks ol
  JOIN part_keys pk ON ol.Source_UUID = pk.part_uuid AND ol.Source_File = pk.File_Name
  WHERE ol.Link_Role = 'breaks_on_field'
  GROUP BY ol.Source_UUID
)

SELECT
  pk.Part_Seq       AS part_seq,
  pk.part_uuid      AS part_uuid,
  pk.Part_Type      AS part_type,
  pk.Part_Kind      AS part_kind,
  pk.Part_Size      AS part_size,
  pk.Part_Absolute  AS part_absolute,
  pk.Object_Count   AS object_count,
  pk.Part_Name      AS part_name,
  pk.Break_Field_Name AS break_field_name,
  bt.break_field_uuid AS break_field_uuid,
  bt.break_field_file AS break_field_file,
  pk.Break_TO_Name  AS break_to_name,
  lm.L_Name         AS layout_name,
  lm.L_UUID         AS layout_uuid,
  lm.L_TO_Name      AS layout_to_name,
  lm.File_Name      AS file_name
FROM part_keys pk
JOIN layout_match lm ON pk.Layout_ID = lm.L_ID AND pk.File_Name = lm.File_Name
LEFT JOIN break_targets bt ON bt.part_uuid = pk.part_uuid
ORDER BY pk.Part_Absolute, pk.Part_Seq;
