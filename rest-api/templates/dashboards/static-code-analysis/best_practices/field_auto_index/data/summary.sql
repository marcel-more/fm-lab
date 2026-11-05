-- @template_type: report
-- @description: KPI summary for the field_auto_index rule — total findings plus the
--   distinct files and tables affected. Detection logic mirrors data/findings.sql.
-- @params: file (optional)
SELECT
    COUNT(*)                    AS finding_count,
    'warning'                      AS severity,
    COUNT(DISTINCT file_name)   AS affected_files,
    COUNT(DISTINCT table_uuid)  AS affected_tables
FROM (
    SELECT f.File_Name AS file_name, f.Table_UUID AS table_uuid
    FROM FieldsForTables f
    WHERE f.Storage_Index = 'None'
      AND f.Storage_AutoIndex = TRUE
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
) _summary;
