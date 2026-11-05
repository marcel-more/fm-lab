-- @template_type: report
-- @description: KPI-Übersicht ODBC/ESS/SQL — Execute-SQL-Steps, ODBC/ESS-Datenquellen, fmxdbc-Grants, betroffene Dateien.
-- @params: file (optional)

SELECT
    (SELECT COUNT(*) FROM StepsForScripts s WHERE s.Step_ID = 117
       AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file')))  AS execute_sql_steps,
    (SELECT COUNT(DISTINCT DS_Name) FROM ExternalDataSourceCatalog
       WHERE DS_Type <> 'FileMaker'
         AND (getvariable('file') IS NULL OR File_Name = getvariable('file')))  AS ess_sources,
    (SELECT COUNT(*) FROM ObjectLinks ol
       JOIN ObjectCatalog sc ON ol.Source_UUID = sc.Object_UUID AND sc.File_Name = ol.Source_File
       JOIN ObjectCatalog tc ON ol.Target_UUID = tc.Object_UUID AND tc.File_Name IS NOT DISTINCT FROM ol.Target_File
       WHERE ol.Link_Role = 'grants_privilege' AND tc.Object_Name = 'fmxdbc'
         AND (getvariable('file') IS NULL OR sc.File_Name = getvariable('file'))) AS fmxdbc_grants,
    (SELECT COUNT(DISTINCT s.File_Name) FROM StepsForScripts s WHERE s.Step_ID = 117
       AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file')))  AS files_with_sql;
