-- @template_type: report
-- @description: Referenzen des button-eingebetteten Steps eines LayoutObjects (für die inline-Tokenisierung/Verlinkung), Ref-Shape wie object_references_script.sql
-- @params: uuid (required) — Object_UUID des Button-LayoutObjects; file (optional) — Klon-Disambiguierung
-- @author: Marcel
-- @version: 1.0
-- @tags: layout-objects, buttons, references, tokens

-- Liefert die operativen Ausgangs-Referenzen des Button-Objekts im Ref-Zeilen-Format
-- des tokens.formatter (line_index, source_priority, type, name, uuid, field_file,
-- field_basetable, to_name, cross_file, data_source, variable_scope, variable_usage,
-- sub_function). Alle auf line_index=0 (der eine Step). Der Tokenizer verlinkt nur
-- Refs, deren NAME im Step-Klartext vorkommt (z.B. "Zahlung" in
-- Go to Layout [ "Zahlung" … ]) → zusätzliche, nicht-matchende Refs sind harmlos.
--
-- Quelle ist ObjectLinks (bereits heimat-/klon-aufgelöst): die button-eingebetteten
-- Step-Referenzen sind dort als navigates_to_* / sorts_by_* / reads_field / … mit
-- Source_Type='LayoutObject' abgelegt (P2 XMLLayoutReferences → P4). Die Container-
-- Rollen parent_layout/parent_object laufen ebenfalls als Link_Type='operational',
-- gehören aber NICHT zu den Step-Parametern → explizit ausgeschlossen.

SELECT
  0 AS line_index,
  0 AS source_priority,
  CASE oc.Object_Type
    WHEN 'Layout'          THEN 'layout'
    WHEN 'TableOccurrence' THEN 'tableOccurrence'
    WHEN 'Field'           THEN 'field'
    WHEN 'ValueList'       THEN 'valueList'
    WHEN 'Script'          THEN 'script'
    WHEN 'Variable'        THEN 'variable'
    ELSE lower(oc.Object_Type)
  END AS type,
  oc.Object_Name AS name,
  ol.Target_UUID AS uuid,
  oc.File_Name AS field_file,
  CAST(NULL AS VARCHAR) AS field_basetable,
  CAST(NULL AS VARCHAR) AS to_name,
  COALESCE(ol.Is_Cross_File, FALSE) AS cross_file,
  CAST(NULL AS VARCHAR) AS data_source,
  CAST(NULL AS VARCHAR) AS variable_scope,
  CAST(NULL AS VARCHAR) AS variable_usage,
  CAST(NULL AS VARCHAR) AS sub_function
FROM ObjectLinks ol
JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID
WHERE ol.Source_UUID = getvariable('uuid')
  AND ol.Source_Type = 'LayoutObject'
  AND ol.Link_Type = 'operational'
  AND ol.Link_Role NOT IN ('parent_layout', 'parent_object')
  AND (getvariable('file') IS NULL OR ol.Source_File = getvariable('file'));
