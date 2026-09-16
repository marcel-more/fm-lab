-- @template_type: report
-- @title: Field annotation inventory
-- @description: Every field that carries a field annotation (FileMaker 26: Manage Database → Field Options → Annotation, the free-text note shown in the field picker), with the annotation side by side. FileMaker 26 only — annotations exist in SaXML 2.3.0.0 exports and later; a catalog imported from a FileMaker 22 or older export returns no rows. Fields without an annotation are not listed. Each row opens the field detail view.
-- @icon: sticky-note
-- @category: Schema
-- @display: table
-- @params: file (optional), limit (optional, default 500)
-- @click_action: openObject
-- @click_args: uuid={{_field_uuid}}&type=Field&file={{file_name}}
-- @output_format: file_name, table_name, field_name, annotation, _message, _row_total
-- @object_types: Field
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "annotated_fields", "meaning": "Fields with an annotation (FileMaker 26 exports only; inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: schema, fields, annotations, documentation, filemaker-26, inventory
--
-- Field_Annotation is filled only under the saxml23 profile (FileMaker 26+);
-- FileMaker <= 22 exports have no <Annotation> element and leave the column
-- NULL — an empty result on such a catalog is expected, not a defect.
WITH sel AS (
    SELECT
        f.File_Name  AS file_name,
        f.Field_UUID AS _field_uuid,
        f.Table_Name AS table_name,
        f.Field_Name AS field_name,
        replace(f.Field_Annotation, chr(10), ' ') AS annotation,
        'Field "' || f.Table_Name || '::' || f.Field_Name || '" — '
          || replace(f.Field_Annotation, chr(10), ' ') AS _message
    FROM FieldsForTables f
    WHERE NULLIF(trim(f.Field_Annotation), '') IS NOT NULL
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR f.Field_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
           OR f.Table_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
)
SELECT s.*,
    (SELECT count(*) FROM sel) AS _row_total
FROM sel s
ORDER BY file_name, table_name, field_name
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
