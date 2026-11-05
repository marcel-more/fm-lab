-- @template_type: report
-- @description: Structured layout-object data (one row per object) for interactive React rendering
-- @params: uuid (optional), name (optional), id (optional), file (optional)
-- @output_format: report
-- @author: Marcel
-- @version: 1.2
-- @tags: layouts, objects, data, react, interactive
-- @note: Ergänzt display_layout_svg.sql, das fertiges SVG-Markup liefert. Dieser Endpunkt
-- @note: gibt eine Zeile pro Layout-Objekt zurück mit allen Spalten, die das Frontend für
-- @note: Hover-Tooltip, Cross-Navigation, Suche, Filter und Label-Toggle benötigt.
-- @note: CF-/Trigger-Indikatoren kommen aus den eigentümer-verankerten Katalogtabellen
-- @note: (LayoutObjectConditions, ScriptTriggers) — das frühere XML-Regex-Flag war durch
-- @note: die Container-Verankerungs-Falle nachweislich falsch (False-Positives auf
-- @note: Containern, deren Object_XML die Kind-CF nestet, plus False-Negatives).

WITH RECURSIVE layout_match AS (
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
    lo.Z_Order,
    lo.Part_Type,
    lo.Hide_Calculation_Text,
    lo.Tooltip_Calculation_Text,
    lo.Label_Calculation_Text,
    lo.Text_Content,
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
    Bounds_Top AS Abs_Top,
    Bounds_Left AS Abs_Left,
    Bounds_Bottom AS Abs_Bottom,
    Bounds_Right AS Abs_Right,
    Parent_Object_ID, Nesting_Level, Z_Order, Part_Type,
    Hide_Calculation_Text, Tooltip_Calculation_Text, Label_Calculation_Text,
    Text_Content
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
    child.Parent_Object_ID, child.Nesting_Level, child.Z_Order, child.Part_Type,
    child.Hide_Calculation_Text, child.Tooltip_Calculation_Text, child.Label_Calculation_Text,
    child.Text_Content
  FROM layout_objects_raw child
  JOIN objects_absolute parent ON child.Parent_Object_ID = parent.Object_ID
),
-- Cross-Nav-Targets: erstes displays_field bzw. erstes triggers_script pro LayoutObject.
-- Alle Target-CTEs joinen über layout_objects_raw und sind damit datei-skopiert
-- (Klon-Korrektheit); das Ziel wird über (Target_UUID, Target_File) aufgelöst.
field_targets AS (
  SELECT
    ol.Source_UUID AS lo_uuid,
    arg_min(oc.Object_UUID, oc.Object_Name) AS field_uuid,
    arg_min(oc.Object_Name, oc.Object_Name) AS field_name
  FROM ObjectLinks ol
  JOIN layout_objects_raw lor ON ol.Source_UUID = lor.Object_UUID AND ol.Source_File = lor.File_Name
  JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
  WHERE ol.Source_Type = 'LayoutObject'
    AND ol.Link_Role = 'displays_field'
  GROUP BY ol.Source_UUID
),
script_targets AS (
  SELECT
    ol.Source_UUID AS lo_uuid,
    arg_min(oc.Object_UUID, oc.Object_Name) AS script_uuid,
    arg_min(oc.Object_Name, oc.Object_Name) AS script_name,
    count(*) AS script_count
  FROM ObjectLinks ol
  JOIN layout_objects_raw lor ON ol.Source_UUID = lor.Object_UUID AND ol.Source_File = lor.File_Name
  JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
  WHERE ol.Source_Type = 'LayoutObject'
    AND ol.Link_Role = 'triggers_script'
  GROUP BY ol.Source_UUID
),
-- Abgeleitete Modifier-Ziele: Go-to-Layout-Buttons (navigates_to_layout) und
-- Portal-TableOccurrence (portal_context).
nav_layout_targets AS (
  SELECT
    ol.Source_UUID AS lo_uuid,
    arg_min(oc.Object_UUID, oc.Object_Name) AS nav_layout_uuid,
    arg_min(oc.Object_Name, oc.Object_Name) AS nav_layout_name
  FROM ObjectLinks ol
  JOIN layout_objects_raw lor ON ol.Source_UUID = lor.Object_UUID AND ol.Source_File = lor.File_Name
  JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
  WHERE ol.Source_Type = 'LayoutObject'
    AND ol.Link_Role = 'navigates_to_layout'
  GROUP BY ol.Source_UUID
),
portal_targets AS (
  SELECT
    ol.Source_UUID AS lo_uuid,
    arg_min(oc.Object_UUID, oc.Object_Name) AS portal_to_uuid,
    arg_min(oc.Object_Name, oc.Object_Name) AS portal_to_name
  FROM ObjectLinks ol
  JOIN layout_objects_raw lor ON ol.Source_UUID = lor.Object_UUID AND ol.Source_File = lor.File_Name
  JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID AND ol.Target_File = oc.File_Name
  WHERE ol.Source_Type = 'LayoutObject'
    AND ol.Link_Role = 'portal_context'
  GROUP BY ol.Source_UUID
),
-- Regel-genaue CF-Anzahl aus der eigentümer-verankerten Import-Tabelle
-- (inkl. rein wertbasierter Bedingungen ohne Formeltext).
cf_counts AS (
  SELECT loc.Object_UUID AS lo_uuid, count(*) AS cf_count
  FROM LayoutObjectConditions loc
  JOIN layout_objects_raw lor ON loc.Object_UUID = lor.Object_UUID AND loc.File_Name = lor.File_Name
  GROUP BY loc.Object_UUID
),
-- Script-Trigger: Anzahl + vollständige Event-Liste in Slot-Reihenfolge
-- (Trigger_ID = FileMaker-Dialog-Reihenfolge; keine Deckelung — die Zahl ist
-- durch die 8 Objekt-Event-Typen natürlich begrenzt).
trigger_info AS (
  SELECT
    st.Owner_UUID AS lo_uuid,
    count(*) AS trigger_count,
    string_agg(st.Trigger_Action, ',' ORDER BY st.Trigger_ID) AS trigger_events
  FROM ScriptTriggers st
  JOIN layout_objects_raw lor ON st.Owner_UUID = lor.Object_UUID AND st.File_Name = lor.File_Name
  WHERE st.Owner_Type = 'LayoutObject'
  GROUP BY st.Owner_UUID
),
-- Layout-Calculation-Instanzen (<<ƒ:…>> in Textobjekten): Instanz-genaue
-- Anzahl aus CalculationsCatalog (Rolle display_calculation) — speist den
-- display-Chip der Calc-Filtergruppe; der Chip zählt TRÄGER, nicht Instanzen.
display_calc_counts AS (
  SELECT cc.Owner_UUID AS lo_uuid, count(*) AS display_calc_count
  FROM CalculationsCatalog cc
  JOIN layout_objects_raw lor ON cc.Owner_UUID = lor.Object_UUID AND cc.File_Name = lor.File_Name
  WHERE cc.Calc_Role = 'display_calculation'
  GROUP BY cc.Owner_UUID
),
-- Belegte typspezifische Calc-Slot-Rollen (Slot-Zeile im Tooltip):
-- Placeholder, Button-Label, Panel-Title, Popover-Title, Portal-Filter, Web-Viewer-URL,
-- aktives Segment (Button Bar).
other_calc_roles AS (
  SELECT lo_uuid, string_agg(Calc_Role, ',' ORDER BY role_rank) AS other_calc_roles
  FROM (
    SELECT DISTINCT
      cc.Owner_UUID AS lo_uuid,
      cc.Calc_Role,
      CASE cc.Calc_Role
        WHEN 'placeholder' THEN 0 WHEN 'button_label' THEN 1
        WHEN 'panel_title' THEN 2 WHEN 'popover_title' THEN 3
        WHEN 'portal_filter' THEN 4 WHEN 'web_viewer_url' THEN 5
        WHEN 'active_segment' THEN 6
        ELSE 7 END AS role_rank
    FROM CalculationsCatalog cc
    JOIN layout_objects_raw lor ON cc.Owner_UUID = lor.Object_UUID AND cc.File_Name = lor.File_Name
    WHERE cc.Calc_Role IN ('placeholder', 'button_label', 'panel_title',
                           'popover_title', 'portal_filter', 'web_viewer_url',
                           'active_segment')
  )
  GROUP BY lo_uuid
)

SELECT
  oa.Object_UUID                      AS object_uuid,
  oa.Object_ID                        AS object_id,
  oa.Object_Type                      AS object_type,
  NULLIF(oa.Object_Name, '')          AS object_name,
  NULLIF(oa.Text_Content, '')         AS text_content,
  oa.Abs_Top                          AS abs_top,
  oa.Abs_Left                         AS abs_left,
  oa.Abs_Bottom                       AS abs_bottom,
  oa.Abs_Right                        AS abs_right,
  oa.Nesting_Level                    AS nesting_level,
  oa.Z_Order                          AS z_order,
  oa.Parent_Object_ID                 AS parent_object_id,
  oa.Part_Type                        AS part_type,
  NULLIF(oa.Hide_Calculation_Text, '') AS hide_text,
  NULLIF(oa.Tooltip_Calculation_Text, '') AS tooltip_text,
  NULLIF(oa.Label_Calculation_Text, '') AS label_calc_text,
  COALESCE(cf.cf_count, 0)            AS cf_count,
  COALESCE(ti.trigger_count, 0)       AS trigger_count,
  ti.trigger_events                   AS trigger_events,
  COALESCE(dc.display_calc_count, 0)  AS display_calc_count,
  ocr.other_calc_roles                AS other_calc_roles,
  COALESCE(st.script_count, 0)        AS script_count,
  ft.field_uuid                       AS field_uuid,
  ft.field_name                       AS field_name,
  st.script_uuid                      AS script_uuid,
  st.script_name                      AS script_name,
  nl.nav_layout_uuid                  AS nav_layout_uuid,
  nl.nav_layout_name                  AS nav_layout_name,
  pt.portal_to_uuid                   AS portal_to_uuid,
  pt.portal_to_name                   AS portal_to_name
FROM objects_absolute oa
LEFT JOIN field_targets      ft ON oa.Object_UUID = ft.lo_uuid
LEFT JOIN script_targets     st ON oa.Object_UUID = st.lo_uuid
LEFT JOIN nav_layout_targets nl ON oa.Object_UUID = nl.lo_uuid
LEFT JOIN portal_targets     pt ON oa.Object_UUID = pt.lo_uuid
LEFT JOIN cf_counts          cf ON oa.Object_UUID = cf.lo_uuid
LEFT JOIN trigger_info       ti ON oa.Object_UUID = ti.lo_uuid
LEFT JOIN display_calc_counts dc ON oa.Object_UUID = dc.lo_uuid
LEFT JOIN other_calc_roles   ocr ON oa.Object_UUID = ocr.lo_uuid
ORDER BY oa.Nesting_Level, COALESCE(oa.Z_Order, oa.Object_ID);
