-- @template_type: report
-- @description: Structured detail of a Relationship — two TO boxes, per-predicate join conditions, cascade-create/delete + record-sort options per side
-- @params: uuid (required), file (optional, clone-scoping) — uuid = ObjectCatalog.Object_UUID (native FileMaker UUID; rel_<Rel_ID>_<File_Name> only for exports without <UUID>)
-- @output_format: json
-- @author: Marcel
-- @version: 1.0
-- @tags: relationship, join, predicates, graph
-- @note: Flat rows with a `section` discriminator:
--          'meta'      → one row, relationship-level scalars (TO names/uuids, cascade flags,
--                        sort config per side, composed name). predicate_* are NULL.
--          'predicate' → one row per join predicate (Predicate_Index order); left/right field
--                        name+uuid + operator. relationship-level cols are NULL.
--        RelationshipCatalog carries one row per predicate since schema 1.2.0; the meta row
--        picks any single predicate row (cascade/sort cols are constant per relationship).

WITH rel AS (
  -- Object_UUID → (Rel_ID, File_Name) via ObjectCatalog.
  -- Clone-Scoping: UUID ist nur je (UUID, File_Name) eindeutig → optional auf 'file' einschränken.
  SELECT Object_UUID, Object_ID AS Rel_ID, File_Name
  FROM ObjectCatalog
  WHERE Object_UUID = getvariable('uuid') AND Object_Type = 'Relationship'
    AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
  LIMIT 1
),
preds AS (
  SELECT rc.*, rel.Object_UUID AS Catalog_UUID
  FROM RelationshipCatalog rc
  JOIN rel ON rc.Rel_ID = rel.Rel_ID AND rc.File_Name = rel.File_Name
)

SELECT * FROM (
  -- ── META (one row): relationship-level scalars ──
  SELECT
    'meta' AS section,
    0 AS order_hint,
    NULL AS predicate_index,
    m.Rel_ID AS rel_id,
    m.Catalog_UUID AS object_uuid,
    m.Left_TO_Name || ' → ' || m.Right_TO_Name AS rel_name,
    m.File_Name AS file_name,
    m.Left_TO_Name  AS left_to_name,  m.Left_TO_UUID  AS left_to_uuid,
    m.Right_TO_Name AS right_to_name, m.Right_TO_UUID AS right_to_uuid,
    m.Left_Create  AS left_create,  m.Left_Delete  AS left_delete,
    m.Right_Create AS right_create, m.Right_Delete AS right_delete,
    m.Left_Sort_Enabled  AS left_sort_enabled,  m.Left_Sort_Fields  AS left_sort_fields,
    m.Right_Sort_Enabled AS right_sort_enabled, m.Right_Sort_Fields AS right_sort_fields,
    NULL AS operator,
    NULL AS left_field_name,  NULL AS left_field_uuid,
    NULL AS right_field_name, NULL AS right_field_uuid
  FROM (SELECT * FROM preds ORDER BY Predicate_Index LIMIT 1) m

  UNION ALL

  -- ── PREDICATE (one row per join condition) ──
  SELECT
    'predicate' AS section,
    p.Predicate_Index AS order_hint,
    p.Predicate_Index AS predicate_index,
    NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL,
    p.Operator AS operator,
    p.Left_Field_Name  AS left_field_name,  p.Left_Field_UUID  AS left_field_uuid,
    p.Right_Field_Name AS right_field_name, p.Right_Field_UUID AS right_field_uuid
  FROM preds p
)
ORDER BY order_hint;
