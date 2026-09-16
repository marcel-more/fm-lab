-- @template_type: report
-- @title: Field display names inventory
-- @description: Every field with customized display names (FileMaker 26: Manage Database → Field Options → Display Names — the default labels FileMaker uses for the field in the Common, Export, Sort and Table View contexts), one column per context. A label that is a formula rather than a literal is prefixed with "ƒ". FileMaker 26 only — display names exist in SaXML 2.3.0.0 exports and later; a catalog imported from a FileMaker 22 or older export returns no rows. Fields without display names are not listed. Each row opens the field detail view.
-- @icon: tag
-- @category: Schema
-- @display: table
-- @params: file (optional), limit (optional, default 500)
-- @click_action: openObject
-- @click_args: uuid={{_field_uuid}}&type=Field&file={{file_name}}
-- @output_format: file_name, table_name, field_name, common, export, sort, table_view, _message, _row_total
-- @object_types: Field
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "fields_with_display_names", "meaning": "Fields with customized display names (FileMaker 26 exports only; inventory — not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: schema, fields, display-names, labels, documentation, filemaker-26, inventory
--
-- The display-names formula is a JSONSetElement(...) over the four fixed keys
-- fm_common / fm_export / fm_sort / fm_table_view; the importer splits it into
-- FieldDisplayNames (one row per key, Value_Kind = literal | formula). The
-- pivot below reads those rows — never the formula text. A field whose
-- formula is present but disabled (Field_DisplayNames_Enabled = false) is
-- still listed; the state is named in the hidden _message.
WITH labels AS (
    SELECT
        d.Field_UUID, d.File_Name, d.Element_Key,
        CASE WHEN d.Value_Kind = 'formula' THEN 'ƒ ' || replace(d.Value_Text, chr(10), ' ')
             ELSE d.Value_Text END AS label
    FROM FieldDisplayNames d
),
sel AS (
    SELECT
        f.File_Name  AS file_name,
        f.Field_UUID AS _field_uuid,
        f.Table_Name AS table_name,
        f.Field_Name AS field_name,
        max(CASE WHEN l.Element_Key = 'fm_common'     THEN l.label END) AS common,
        max(CASE WHEN l.Element_Key = 'fm_export'     THEN l.label END) AS export,
        max(CASE WHEN l.Element_Key = 'fm_sort'       THEN l.label END) AS sort,
        max(CASE WHEN l.Element_Key = 'fm_table_view' THEN l.label END) AS table_view,
        'Field "' || f.Table_Name || '::' || f.Field_Name || '" — display names'
          || CASE WHEN f.Field_DisplayNames_Enabled IS FALSE THEN ' (disabled)' ELSE '' END
          || ': common='  || COALESCE(max(CASE WHEN l.Element_Key = 'fm_common'     THEN l.label END), '')
          || ', export='  || COALESCE(max(CASE WHEN l.Element_Key = 'fm_export'     THEN l.label END), '')
          || ', sort='    || COALESCE(max(CASE WHEN l.Element_Key = 'fm_sort'       THEN l.label END), '')
          || ', table view=' || COALESCE(max(CASE WHEN l.Element_Key = 'fm_table_view' THEN l.label END), '') AS _message
    FROM FieldsForTables f
    LEFT JOIN labels l ON l.Field_UUID = f.Field_UUID AND l.File_Name = f.File_Name
    WHERE NULLIF(trim(f.DisplayNames_Calc_Text), '') IS NOT NULL
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR f.Field_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
           OR f.Table_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
    GROUP BY f.File_Name, f.Field_UUID, f.Table_Name, f.Field_Name, f.Field_DisplayNames_Enabled
)
SELECT s.*,
    (SELECT count(*) FROM sel) AS _row_total
FROM sel s
ORDER BY file_name, table_name, field_name
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
