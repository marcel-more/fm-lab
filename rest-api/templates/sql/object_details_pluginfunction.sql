-- @template_type: report
-- @description: Structured detail of a plug-in function - identity (plug-in namespace, sub-function, component object) and the where-used summary per link role and source type
-- @params: uuid (required)
-- @output_format: json
-- @author: Marcel
-- @version: 2.0
-- @tags: pluginfunction, details, mbs
-- @note: Synthetic ObjectCatalog entry (file-independent), built from the plug-in
--        calls found in the formula chunks. Object_Name is deliberately redundant:
--          Container plug-in:     `MBS:XL.Book.AddFormat::XL.Book.AddFormat`
--          Non-container plug-in: `Fensternamen`
--        Namespace = before the FIRST ':', SubName = after the LAST '::' —
--        format-tolerant for the old `MBS::<Sub>` spelling. The canonical rule
--        lives in rest-api/src/utils/plugin-name.js; SQL mirrors it inline
--        because DuckDB cannot import JS.
--
--        Flat rows with a `section` discriminator:
--          'meta'  -> one row: catalog name, plug-in namespace, sub-function,
--                     the component object it groups into (clickable) and the
--                     where-used totals.
--          'usage' -> one row per (link role x source type): distinct source
--                     objects, distinct files and total occurrences.
--        The caller LIST is deliberately NOT part of this projection - the
--        References tab is its home (every inbound edge, navigable). Counting
--        every operational inbound edge keeps the summary role-complete
--        without naming `calls_pluginfunction` explicitly.
--
--        The reference layer (platform map, component, version, status) and the
--        documentation cross-links are NOT resolved here: they come from
--        plugin_spec.duckdb via /api/plugin-spec/functions/:prefix/:name, which
--        also decides whether the vendor doc-set is installed.

WITH self AS (
  SELECT Object_UUID, Object_Type, Object_Name, Source_Table
  FROM ObjectCatalog
  WHERE Object_UUID = getvariable('uuid')
    AND Object_Type = 'PluginFunction'
  LIMIT 1
),
self_parts AS (
  SELECT
    Object_UUID,
    Object_Name,
    CASE WHEN Object_Name LIKE '%::%'
         THEN regexp_extract(Object_Name, '^([^:]+):', 1)
         ELSE Object_Name END AS plugin_name,
    CASE WHEN Object_Name LIKE '%::%'
         THEN regexp_replace(Object_Name, '^.*::', '')
         ELSE NULL END AS sub_name
  FROM self
),
-- Komponenten-Objekt (PluginComponent), in das die Funktion eingruppiert ist —
-- strukturelle Kante, keine Verwendung. Macht die Komponente anklickbar.
component AS (
  SELECT oc.Object_Name AS component_name, oc.Object_UUID AS component_uuid
  FROM ObjectLinks ol
  JOIN ObjectCatalog oc ON oc.Object_UUID = ol.Target_UUID
  WHERE ol.Source_UUID = getvariable('uuid')
    AND ol.Link_Role = 'groups_into'
  LIMIT 1
),
-- Jede operationale Eingangskante ist eine Verwendung; PluginFunction-Knoten
-- kennen keine anderen Eingangsrollen.
usages AS (
  SELECT
    ol.Link_Role,
    src.Object_Type AS used_by_type,
    src.Object_UUID AS src_uuid,
    ol.Source_File  AS src_file
  FROM ObjectLinks ol
  JOIN ObjectCatalog src ON src.Object_UUID = ol.Source_UUID
  WHERE ol.Target_UUID = getvariable('uuid')
    AND ol.Link_Type = 'operational'
),
usage_groups AS (
  SELECT
    Link_Role AS link_role,
    used_by_type,
    COUNT(DISTINCT src_uuid) AS object_count,
    COUNT(DISTINCT src_file) AS file_count,
    COUNT(*) AS occurrence_count
  FROM usages
  GROUP BY Link_Role, used_by_type
),
usage_totals AS (
  SELECT
    COUNT(DISTINCT src_uuid) AS total_objects,
    COUNT(DISTINCT src_file) AS total_files,
    COUNT(*) AS total_occurrences
  FROM usages
)

SELECT * FROM (
  -- ── META (one row) ──
  SELECT
    'meta' AS section,
    0 AS order_hint,
    sp.Object_Name AS object_name,
    sp.plugin_name AS plugin_name,
    sp.sub_name    AS sub_name,
    (SELECT component_name FROM component) AS component_name,
    (SELECT component_uuid FROM component) AS component_uuid,
    (SELECT total_objects     FROM usage_totals) AS total_objects,
    (SELECT total_files       FROM usage_totals) AS total_files,
    (SELECT total_occurrences FROM usage_totals) AS total_occurrences,
    CAST(NULL AS VARCHAR) AS link_role,
    CAST(NULL AS VARCHAR) AS used_by_type,
    CAST(NULL AS BIGINT)  AS object_count,
    CAST(NULL AS BIGINT)  AS file_count,
    CAST(NULL AS BIGINT)  AS occurrence_count
  FROM self_parts sp

  UNION ALL

  -- ── USAGE (one row per link role x source type) ──
  SELECT
    'usage', 1,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL,
    ug.link_role, ug.used_by_type,
    ug.object_count, ug.file_count, ug.occurrence_count
  FROM usage_groups ug
) details
ORDER BY order_hint, occurrence_count DESC NULLS FIRST, used_by_type;
