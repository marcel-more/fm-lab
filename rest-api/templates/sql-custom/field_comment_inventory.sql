-- @template_type: report
-- @title: Field comment inventory
-- @description: Every field that carries a field comment (Manage Database → Fields → Comment), with the comment side by side — the solution's field-level documentation in one readable pass, next to the table the field belongs to. Fields without a comment are not listed; the row count is therefore the documentation coverage in fields. Each row opens the field detail view.
-- @icon: message-square
-- @category: Schema
-- @display: table
-- @params: file (optional), limit (optional, default 500)
-- @click_action: openObject
-- @click_args: uuid={{_field_uuid}}&type=Field&file={{file_name}}
-- @output_format: file_name, table_name, field_name, comment, _message, _row_total
-- @object_types: Field
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "commented_fields", "meaning": "Fields with a field comment (inventory — documentation coverage, not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: schema, fields, comments, documentation, inventory
--
-- Field_Comment is NULL for an empty comment attribute; NULLIF(trim(…)) also
-- drops whitespace-only comments. `scope_uuids` accepts field UUIDs (object /
-- object-list / cluster scope) and base-table UUIDs (a table's fields).
WITH sel AS (
    SELECT
        f.File_Name  AS file_name,
        f.Field_UUID AS _field_uuid,
        f.Table_Name AS table_name,
        f.Field_Name AS field_name,
        replace(f.Field_Comment, chr(10), ' ') AS comment,
        'Field "' || f.Table_Name || '::' || f.Field_Name || '" — '
          || replace(f.Field_Comment, chr(10), ' ') AS _message
    FROM FieldsForTables f
    WHERE NULLIF(trim(f.Field_Comment), '') IS NOT NULL
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
