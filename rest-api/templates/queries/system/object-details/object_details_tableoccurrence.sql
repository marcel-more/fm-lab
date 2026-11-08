-- @template_type: report
-- @description: Structured detail of a TableOccurrence — definition (base table, data source, diagram display), every relationship seen from this occurrence, and the other occurrences of the same base table
-- @params: uuid (required), file (optional, clone-scoping)
-- @output_format: json
-- @author: Marcel
-- @version: 1.0
-- @tags: table-occurrence, relationship, join, predicates, data-source, structure
-- @note: Flat rows with a `section` discriminator:
--          'meta'      → one row: TO scalars, base table (resolved through the base_table edge,
--                        cross-file for external occurrences), data source + resolved file,
--                        diagram colour/view, sibling counts.
--          'predicate' → one row per (relationship, join predicate), normalised so that THIS
--                        occurrence is always the "self" side: self/partner field, the operator
--                        as stored (`operator`) plus `self_is_left` so the client can mirror it,
--                        options of both sides, the partner occurrence and the relationship UUID.
--          'sibling'   → one row per OTHER occurrence of the same base table, solution-wide
--                        (`file_name` = the sibling's file, `sibling_ds_name` = its data source
--                        or NULL for the current file, `sibling_ds_self` = that data source points
--                        back at the sibling's own file; meta carries the counts).
--        "External" (TO_Type) only says the occurrence reaches its base table through a data
--        source — the data source may even point at the own file (`ds_resolved_self`). Where the
--        base table lives is `bt_file`.
--        Usage (v_table_occurrence_usage / _class) comes from object_details_tableoccurrence_usage,
--        appended by the service only when those tables exist (schema >= 1.38.0).

-- Clone-Scoping: Object_UUID ist nur je (UUID, File_Name) eindeutig
WITH to_match AS (
  SELECT t.*
  FROM TableOccurrenceCatalog t
  WHERE t.TO_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
  LIMIT 1
),
-- Base table of every occurrence of this file, resolved through the graph: an external
-- occurrence points at the base table of ANOTHER file. `bt_file` is only set when the target
-- is in the catalog (otherwise the name stays plain text in the client).
-- Naming: DuckDB identifiers are case-insensitive — the catalog's own BT_Name/BT_UUID (the
-- reference as written in this file) are renamed so they cannot shadow the resolved bt_* columns.
to_bt AS (
  SELECT t.TO_UUID, t.File_Name, t.TO_Name, t.TO_Type, t.DS_Name,
         t.BT_Name AS ref_bt_name, t.BT_UUID AS ref_bt_uuid,
         oc.Object_UUID AS bt_uuid, oc.File_Name AS bt_file, oc.Object_Name AS bt_name
  FROM TableOccurrenceCatalog t
  JOIN to_match tm ON t.File_Name = tm.File_Name
  LEFT JOIN ObjectLinks ol
    ON ol.Source_UUID = t.TO_UUID AND ol.Source_File = t.File_Name AND ol.Link_Role = 'base_table'
  LEFT JOIN ObjectCatalog oc
    ON oc.Object_UUID = ol.Target_UUID AND oc.File_Name = ol.Target_File
   AND oc.Object_Type = 'BaseTable'
),
self_bt AS (
  SELECT b.* FROM to_bt b JOIN to_match tm ON b.TO_UUID = tm.TO_UUID LIMIT 1
),
data_source AS (
  SELECT d.DS_Name, d.DS_Type, d.Path,
         m.Resolved_File,
         EXISTS (SELECT 1 FROM FilesCatalog f WHERE f.File_Name = m.Resolved_File) AS resolved_imported,
         -- an "external" data source may point back at the occurrence's own file
         (m.Resolved_File = tm.File_Name) AS resolved_self
  FROM to_match tm
  JOIN ExternalDataSourceCatalog d ON d.DS_UUID = tm.DS_UUID AND d.File_Name = tm.File_Name
  LEFT JOIN DataSourceFileMap m ON m.DS_UUID = tm.DS_UUID AND m.File_Name = tm.File_Name
  LIMIT 1
),
-- Other occurrences of the same base table, solution-wide: every occurrence with a base_table
-- edge to the resolved base table (local and external ones of every file). When the base table
-- does not resolve, only the same-file occurrences with the same reference can be found.
siblings_raw AS (
  SELECT t.TO_UUID, t.TO_Name, t.TO_Type, t.File_Name, t.DS_UUID, t.DS_Name
  FROM self_bt s
  JOIN ObjectLinks ol
    ON ol.Target_UUID = s.bt_uuid AND ol.Target_File = s.bt_file
   AND ol.Link_Role = 'base_table' AND ol.Source_Type = 'TableOccurrence'
  JOIN TableOccurrenceCatalog t ON t.TO_UUID = ol.Source_UUID AND t.File_Name = ol.Source_File
  WHERE s.bt_uuid IS NOT NULL
    -- "other" occurrences: this one is not listed
    AND NOT (t.TO_UUID = s.TO_UUID AND t.File_Name = s.File_Name)
  UNION
  SELECT b.TO_UUID, b.TO_Name, b.TO_Type, b.File_Name, tc.DS_UUID, tc.DS_Name
  FROM to_bt b
  JOIN self_bt s ON s.bt_uuid IS NULL AND b.TO_UUID <> s.TO_UUID AND b.ref_bt_uuid = s.ref_bt_uuid
  JOIN TableOccurrenceCatalog tc ON tc.TO_UUID = b.TO_UUID AND tc.File_Name = b.File_Name
),
-- How each sibling reaches the base table: directly (no data source) or through a data
-- source, flagged when that data source points back at the sibling's own file.
siblings AS (
  SELECT r.TO_UUID, r.TO_Name, r.TO_Type, r.File_Name,
         CASE WHEN r.TO_Type = 'External' THEN r.DS_Name END AS DS_Name,
         (r.TO_Type = 'External' AND m.Resolved_File = r.File_Name) AS DS_Self
  FROM siblings_raw r
  LEFT JOIN DataSourceFileMap m ON m.DS_UUID = r.DS_UUID AND m.File_Name = r.File_Name
),
rel AS (
  SELECT r.*, (r.Left_TO_UUID = tm.TO_UUID) AS self_is_left
  FROM RelationshipCatalog r
  JOIN to_match tm
    ON r.File_Name = tm.File_Name AND tm.TO_UUID IN (r.Left_TO_UUID, r.Right_TO_UUID)
),
-- Normalised predicate rows: self = this occurrence, partner = the other side.
pred AS (
  SELECT
    r.Rel_ID, r.Predicate_Index, r.File_Name, r.Operator, r.self_is_left,
    CASE WHEN r.self_is_left THEN r.Right_TO_UUID ELSE r.Left_TO_UUID END AS partner_to_uuid,
    CASE WHEN r.self_is_left THEN r.Right_TO_Name ELSE r.Left_TO_Name END AS partner_to_name,
    CASE WHEN r.self_is_left THEN r.Left_Field_Name  ELSE r.Right_Field_Name END AS self_field_name,
    CASE WHEN r.self_is_left THEN r.Left_Field_ID    ELSE r.Right_Field_ID   END AS self_field_id,
    CASE WHEN r.self_is_left THEN r.Left_Field_UUID  ELSE r.Right_Field_UUID END AS self_field_raw_uuid,
    CASE WHEN r.self_is_left THEN r.Left_Field_TO_UUID  ELSE r.Right_Field_TO_UUID END AS self_field_to_uuid,
    CASE WHEN r.self_is_left THEN r.Right_Field_Name ELSE r.Left_Field_Name  END AS partner_field_name,
    CASE WHEN r.self_is_left THEN r.Right_Field_ID   ELSE r.Left_Field_ID    END AS partner_field_id,
    CASE WHEN r.self_is_left THEN r.Right_Field_UUID ELSE r.Left_Field_UUID  END AS partner_field_raw_uuid,
    CASE WHEN r.self_is_left THEN r.Right_Field_TO_UUID ELSE r.Left_Field_TO_UUID END AS partner_field_to_uuid,
    CASE WHEN r.self_is_left THEN r.Left_Create  ELSE r.Right_Create END AS self_create,
    CASE WHEN r.self_is_left THEN r.Left_Delete  ELSE r.Right_Delete END AS self_delete,
    CASE WHEN r.self_is_left THEN r.Left_Sort_Enabled ELSE r.Right_Sort_Enabled END AS self_sort_enabled,
    CASE WHEN r.self_is_left THEN r.Left_Sort_Fields  ELSE r.Right_Sort_Fields  END AS self_sort_fields,
    CASE WHEN r.self_is_left THEN r.Right_Create ELSE r.Left_Create  END AS partner_create,
    CASE WHEN r.self_is_left THEN r.Right_Delete ELSE r.Left_Delete  END AS partner_delete,
    CASE WHEN r.self_is_left THEN r.Right_Sort_Enabled ELSE r.Left_Sort_Enabled END AS partner_sort_enabled,
    CASE WHEN r.self_is_left THEN r.Right_Sort_Fields  ELSE r.Left_Sort_Fields  END AS partner_sort_fields
  FROM rel r
),
-- Field navigation target: the field lives in the base table (and file) of its TO. Resolve the
-- canonical field by (home file, base table, Field_ID); fall back to the raw reference UUID
-- without a file (graceful downgrade, as in the relationship detail).
pred_resolved AS (
  SELECT
    p.*,
    COALESCE(fs.Field_UUID, p.self_field_raw_uuid) AS self_field_uuid,
    CASE WHEN fs.Field_UUID IS NOT NULL THEN fs.File_Name END AS self_field_file,
    COALESCE(fp.Field_UUID, p.partner_field_raw_uuid) AS partner_field_uuid,
    CASE WHEN fp.Field_UUID IS NOT NULL THEN fp.File_Name END AS partner_field_file,
    pb.TO_Type AS partner_to_type,
    COALESCE(pb.bt_name, pb.ref_bt_name) AS partner_bt_name,
    pb.DS_Name AS partner_ds_name,
    roc.Object_UUID AS rel_uuid
  FROM pred p
  LEFT JOIN to_bt sb ON sb.TO_UUID = COALESCE(p.self_field_to_uuid, getvariable('uuid'))
  LEFT JOIN FieldsForTables fs
    ON fs.File_Name = sb.bt_file AND fs.Table_Name = sb.bt_name AND fs.Field_ID = p.self_field_id
  LEFT JOIN to_bt pb ON pb.TO_UUID = p.partner_to_uuid
  LEFT JOIN to_bt pfb ON pfb.TO_UUID = COALESCE(p.partner_field_to_uuid, p.partner_to_uuid)
  LEFT JOIN FieldsForTables fp
    ON fp.File_Name = pfb.bt_file AND fp.Table_Name = pfb.bt_name AND fp.Field_ID = p.partner_field_id
  LEFT JOIN ObjectCatalog roc
    ON roc.Object_Type = 'Relationship' AND roc.Object_ID = p.Rel_ID AND roc.File_Name = p.File_Name
)

SELECT * EXCLUDE (order_hint) FROM (
  -- ── META (one row) ──
  SELECT
    'meta' AS section,
    0 AS order_hint,
    tm.TO_ID AS to_id,
    tm.TO_Name AS to_name,
    tm.TO_Type AS to_type,
    tm.File_Name AS file_name,
    COALESCE(sb.bt_name, tm.BT_Name) AS bt_name,
    sb.bt_uuid AS bt_uuid,
    sb.bt_file AS bt_file,
    (sb.bt_file IS NOT NULL AND sb.bt_file <> tm.File_Name) AS bt_cross_file,
    ds.DS_Name AS ds_name,
    ds.DS_Type AS ds_type,
    ds.Path AS ds_path,
    ds.Resolved_File AS ds_resolved_file,
    ds.resolved_imported AS ds_resolved_imported,
    tm.View_State AS view_state,
    tm.Color_R AS color_r, tm.Color_G AS color_g, tm.Color_B AS color_b,
    (SELECT COUNT(DISTINCT Rel_ID) FROM rel) AS relationship_count,
    (SELECT COUNT(*) FROM siblings sl WHERE sl.File_Name = tm.File_Name) AS sibling_local_count,
    (SELECT COUNT(*) FROM siblings) AS sibling_solution_count,
    (SELECT COUNT(DISTINCT File_Name) FROM siblings) AS sibling_solution_files,
    CAST(NULL AS BIGINT) AS rel_id, CAST(NULL AS VARCHAR) AS rel_uuid, CAST(NULL AS BIGINT) AS predicate_index,
    CAST(NULL AS VARCHAR) AS operator, CAST(NULL AS BOOLEAN) AS self_is_left,
    CAST(NULL AS VARCHAR) AS partner_to_uuid, CAST(NULL AS VARCHAR) AS partner_to_name,
    CAST(NULL AS VARCHAR) AS partner_to_type, CAST(NULL AS VARCHAR) AS partner_bt_name, CAST(NULL AS VARCHAR) AS partner_ds_name,
    CAST(NULL AS VARCHAR) AS self_field_name, CAST(NULL AS VARCHAR) AS self_field_uuid, CAST(NULL AS VARCHAR) AS self_field_file,
    CAST(NULL AS VARCHAR) AS partner_field_name, CAST(NULL AS VARCHAR) AS partner_field_uuid, CAST(NULL AS VARCHAR) AS partner_field_file,
    CAST(NULL AS BOOLEAN) AS self_create, CAST(NULL AS BOOLEAN) AS self_delete,
    CAST(NULL AS BOOLEAN) AS self_sort_enabled, CAST(NULL AS VARCHAR) AS self_sort_fields,
    CAST(NULL AS BOOLEAN) AS partner_create, CAST(NULL AS BOOLEAN) AS partner_delete,
    CAST(NULL AS BOOLEAN) AS partner_sort_enabled, CAST(NULL AS VARCHAR) AS partner_sort_fields,
    CAST(NULL AS VARCHAR) AS sibling_uuid, CAST(NULL AS VARCHAR) AS sibling_name, CAST(NULL AS VARCHAR) AS sibling_type,
    ds.resolved_self AS ds_resolved_self,
    CAST(NULL AS VARCHAR) AS sibling_ds_name, CAST(NULL AS BOOLEAN) AS sibling_ds_self
  FROM to_match tm
  LEFT JOIN self_bt sb ON TRUE
  LEFT JOIN data_source ds ON TRUE

  UNION ALL

  -- ── PREDICATE (one row per relationship × join predicate) ──
  SELECT
    'predicate', 1,
    NULL, NULL, NULL, p.File_Name,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL,
    p.Rel_ID, p.rel_uuid, p.Predicate_Index,
    p.Operator, p.self_is_left,
    p.partner_to_uuid, p.partner_to_name,
    p.partner_to_type, p.partner_bt_name, p.partner_ds_name,
    -- A field of a file that is not imported carries no name in the export, only its id.
    COALESCE(p.self_field_name, '#' || p.self_field_id), p.self_field_uuid, p.self_field_file,
    COALESCE(p.partner_field_name, '#' || p.partner_field_id), p.partner_field_uuid, p.partner_field_file,
    p.self_create, p.self_delete, p.self_sort_enabled, p.self_sort_fields,
    p.partner_create, p.partner_delete, p.partner_sort_enabled, p.partner_sort_fields,
    NULL, NULL, NULL,
    NULL, NULL, NULL
  FROM pred_resolved p

  UNION ALL

  -- ── SIBLING (other occurrences of the same base table, solution-wide; file_name = their file) ──
  SELECT
    'sibling', 2,
    NULL, NULL, NULL, s.File_Name,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    s.TO_UUID, s.TO_Name, s.TO_Type,
    NULL, s.DS_Name, s.DS_Self
  FROM siblings s
)
ORDER BY order_hint, partner_to_name, rel_id, predicate_index, sibling_name;
