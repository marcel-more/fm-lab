-- @template_type: object
-- @title: Table comment inventory
-- @description: Base tables that carry a table comment (the comment column of the Manage Database dialog), with the comment side by side — the place to read a solution's table-level documentation in one pass and to spot stale or copy-paste descriptions. Tables without a comment are not listed; the row count is therefore the documentation coverage in tables. Needs a catalog imported with converter 2.26.0 or later (schema 1.30.0 — the table comment was not extracted before).
-- @icon: table
-- @category: Schema
-- @display: table
-- @params: file (optional), limit (optional, default 500)
-- @click_action: openObject
-- @click_args: uuid={{uuid}}&type=BaseTable&file={{file}}
-- @output_format: uuid, name, type, file, comment, _message, _row_total
-- @object_types: BaseTable
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "commented_tables", "meaning": "Base tables with a table comment (inventory — documentation coverage, not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: schema, tables, comments, documentation, inventory
--
-- BT_Comment is NULL when the export carries an empty comment attribute, so
-- the presence predicate is a plain IS NOT NULL. Line breaks inside the
-- comment are flattened for the table cell; the detail view shows the
-- original text.
WITH sel AS (
    SELECT
        bt.BT_UUID   AS uuid,
        bt.BT_Name   AS name,
        'BaseTable'  AS type,
        bt.File_Name AS file,
        replace(bt.BT_Comment, chr(10), ' ') AS comment,
        'Table "' || bt.BT_Name || '" — ' || replace(bt.BT_Comment, chr(10), ' ') AS _message
    FROM BaseTableCatalog bt
    WHERE bt.BT_Comment IS NOT NULL
      AND (getvariable('file') IS NULL OR bt.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR bt.BT_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
)
SELECT s.*,
    (SELECT count(*) FROM sel) AS _row_total
FROM sel s
ORDER BY file, name
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
