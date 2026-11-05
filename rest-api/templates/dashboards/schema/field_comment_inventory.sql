-- @template_type: report
-- @title: Field comment inventory
-- @description: Every field that carries a field comment (Manage Database → Fields → Comment), with the comment side by side — the solution's field-level documentation in one readable pass, next to the table the field belongs to. Fields without a comment are not listed; the row count is therefore the documentation coverage in fields. Each row opens the field detail view.
-- @icon: message-square
-- @display: table
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 500
-- @params: file (optional), page (optional), page_size (optional, default 500), q (optional), sort (optional), dir (optional)
-- @click_action: openObject
-- @click_args: uuid={{_field_uuid}}&type=Field&file={{file_name}}
-- @output_format: file_name, table_name, field_name, comment, _message, _row_total, _page, _page_size
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
WITH result AS MATERIALIZED (
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
),
-- >>> shared paging search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) <> 'uuid'))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging search block
filtered AS (
    SELECT * FROM searched
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ file_name, table_name, field_name, _field_uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
