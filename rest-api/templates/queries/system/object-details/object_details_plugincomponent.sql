-- @template_type: report
-- @description: Structured detail of a plug-in component - identity, its member functions with their own where-used counts, and the component's aggregated where-used summary
-- @params: uuid (required)
-- @output_format: json
-- @author: Marcel
-- @version: 2.0
-- @tags: plugincomponent, details, mbs, aggregate
-- @note: Synthetic ObjectCatalog entry - Object_Name = 'MBS::XL', 'MBS::JSON', …
--        PluginComponent keeps the DOUBLE colon; only PluginFunction is qualified
--        as 'MBS:<Sub>::<Sub>'. Namespace = before the first ':', component name =
--        after the last '::' (utils/plugin-name.js, mirrored inline).
--
--        Flat rows with a `section` discriminator:
--          'meta'     -> one row: catalog name, namespace, component name, how many
--                        member functions exist and how many of them are used, plus
--                        the component's DEDUPLICATED where-used totals.
--          'function' -> one row per member function (groups_into): name, UUID
--                        (clickable) and its own where-used counts.
--          'usage'    -> one row per (link role x source type), aggregated over ALL
--                        member functions.
--
--        The two-level caller LIST of the old text view is gone: a component can
--        aggregate thousands of call sites. The per-function counts are the bridge -
--        each function's own detail and References tab hold the individual callers.
--        The totals are deduplicated on purpose: one script calling three functions
--        of this component is ONE using object, not three.
--
--        The reference layer (component size per the vendor map, documentation
--        cross-links) is NOT resolved here - it comes from plugin_spec.duckdb via
--        /api/plugin-spec/components/:prefix/:name.

WITH self AS (
  SELECT Object_UUID, Object_Type, Object_Name
  FROM ObjectCatalog
  WHERE Object_UUID = getvariable('uuid')
    AND Object_Type = 'PluginComponent'
  LIMIT 1
),
self_parts AS (
  SELECT
    Object_UUID,
    Object_Name,
    CASE WHEN Object_Name LIKE '%::%'
         THEN regexp_extract(Object_Name, '^([^:]+):', 1)
         ELSE NULL END AS plugin_name,
    regexp_replace(Object_Name, '^.*::', '') AS component_name
  FROM self
),
-- Mitglieds-Funktionen (strukturelle groups_into-Kante, keine Verwendung).
funcs AS (
  SELECT
    pf.Object_UUID AS function_uuid,
    regexp_replace(pf.Object_Name, '^.*::', '') AS function_name
  FROM self pc
  JOIN ObjectLinks ol ON ol.Target_UUID = pc.Object_UUID
                     AND ol.Link_Role = 'groups_into'
  JOIN ObjectCatalog pf ON pf.Object_UUID = ol.Source_UUID
                       AND pf.Object_Type = 'PluginFunction'
),
-- Jede operationale Eingangskante auf eine Mitglieds-Funktion ist eine
-- Verwendung der Komponente.
usages AS (
  SELECT
    f.function_uuid,
    f.function_name,
    ol.Link_Role,
    src.Object_Type AS used_by_type,
    src.Object_UUID AS src_uuid,
    ol.Source_File  AS src_file
  FROM funcs f
  JOIN ObjectLinks ol ON ol.Target_UUID = f.function_uuid
                     AND ol.Link_Type = 'operational'
  JOIN ObjectCatalog src ON src.Object_UUID = ol.Source_UUID
),
func_usage AS (
  SELECT
    f.function_uuid,
    f.function_name,
    COUNT(DISTINCT u.src_uuid) AS object_count,
    COUNT(u.src_uuid)          AS occurrence_count
  FROM funcs f
  LEFT JOIN usages u ON u.function_uuid = f.function_uuid
  GROUP BY f.function_uuid, f.function_name
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
    sp.Object_Name   AS object_name,
    sp.plugin_name   AS plugin_name,
    sp.component_name AS component_name,
    (SELECT COUNT(*) FROM funcs) AS function_count,
    (SELECT COUNT(*) FROM func_usage WHERE occurrence_count > 0) AS used_function_count,
    (SELECT total_objects     FROM usage_totals) AS total_objects,
    (SELECT total_files       FROM usage_totals) AS total_files,
    (SELECT total_occurrences FROM usage_totals) AS total_occurrences,
    CAST(NULL AS VARCHAR) AS function_uuid,
    CAST(NULL AS VARCHAR) AS function_name,
    CAST(NULL AS VARCHAR) AS link_role,
    CAST(NULL AS VARCHAR) AS used_by_type,
    CAST(NULL AS BIGINT)  AS object_count,
    CAST(NULL AS BIGINT)  AS file_count,
    CAST(NULL AS BIGINT)  AS occurrence_count
  FROM self_parts sp

  UNION ALL

  -- ── FUNCTIONS (one row per member function) ──
  SELECT
    'function', 1,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL,
    fu.function_uuid, fu.function_name,
    NULL, NULL,
    fu.object_count, NULL, fu.occurrence_count
  FROM func_usage fu

  UNION ALL

  -- ── USAGE (one row per link role x source type, over all member functions) ──
  SELECT
    'usage', 2,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL,
    NULL, NULL,
    ug.link_role, ug.used_by_type,
    ug.object_count, ug.file_count, ug.occurrence_count
  FROM usage_groups ug
) details
ORDER BY order_hint, occurrence_count DESC NULLS FIRST, function_name, used_by_type;
