-- @template_type: report
-- @title: Top tables
-- @description: Base tables with the most fields.
-- @icon: table
-- @display: table
-- @params: limit (optional, default 100), file (optional)
-- @click_action: openObject
-- @click_args: uuid={{uuid}}&type=BaseTable
-- @output_format: uuid, name, file, field_count
-- @object_types: BaseTable
-- @author: fm-lab core
-- @version: 1.1
-- @tags: tables, top, ranking

SELECT
    bt.BT_UUID                AS uuid,
    bt.BT_Name                AS name,
    bt.File_Name              AS file,
    COUNT(f.Field_UUID)       AS field_count
FROM BaseTableCatalog bt
LEFT JOIN FieldsForTables f
       ON f.Table_Name = bt.BT_Name AND f.File_Name = bt.File_Name
WHERE (getvariable('file') IS NULL OR bt.File_Name = getvariable('file'))
GROUP BY ALL
ORDER BY field_count DESC, name, file, uuid   -- tie-breakers: stable rows at the LIMIT
LIMIT CAST(COALESCE(getvariable('limit'), '100') AS INTEGER);
