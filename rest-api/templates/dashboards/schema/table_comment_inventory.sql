-- @template_type: report
-- @title: Table comment inventory
-- @description: Base tables that carry a table comment (the comment column of the Manage Database dialog), with the comment side by side — the place to read a solution's table-level documentation in one pass and to spot stale or copy-paste descriptions. Tables without a comment are not listed; the row count is therefore the documentation coverage in tables. Needs a catalog imported with converter 2.26.0 or later (schema 1.30.0 — the table comment was not extracted before).
-- @icon: table
-- @display: table
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 500
-- @params: file (optional), page (optional), page_size (optional, default 500), q (optional), sort (optional), dir (optional)
-- @click_action: openObject
-- @click_args: uuid={{uuid}}&type=BaseTable&file={{file}}
-- @output_format: uuid, name, file, comment, _message, _row_total, _page, _page_size
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
WITH result AS MATERIALIZED (
    SELECT
        bt.BT_UUID   AS uuid,
        bt.BT_Name   AS name,
        bt.File_Name AS file,
        replace(bt.BT_Comment, chr(10), ' ') AS comment,
        'Table "' || bt.BT_Name || '" — ' || replace(bt.BT_Comment, chr(10), ' ') AS _message
    FROM BaseTableCatalog bt
    WHERE bt.BT_Comment IS NOT NULL
      AND (getvariable('file') IS NULL OR bt.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR bt.BT_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
ORDER BY /*@sort*/ file, name, uuid, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
