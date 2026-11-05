-- @template_type: report
-- @description: KPI summary for the unstored_calc_field rule — total findings plus the
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
    WHERE f.Field_Type = 'Calculated'
      AND f.Storage_StoreCalcResults = FALSE
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
) _summary;
