-- @template_type: report
-- @description: KPI-Übersicht der serverseitigen Ausführung — PSoS, Data API, OnTimer-Installationen, betroffene Dateien und server-relevante Grants.
-- @params: file (optional)

SELECT
    (SELECT COUNT(*) FROM StepsForScripts s WHERE s.Step_ID = 164
       AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file')))  AS psos,
    (SELECT COUNT(*) FROM StepsForScripts s WHERE s.Step_ID = 203
       AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file')))  AS data_api,
    (SELECT COUNT(*) FROM StepsForScripts s WHERE s.Step_ID = 148
       AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file')))  AS ontimer,
    (SELECT COUNT(DISTINCT s.File_Name) FROM StepsForScripts s WHERE s.Step_ID IN (164,203,148)
       AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file')))  AS files_affected,
    (SELECT COUNT(*) FROM ObjectLinks ol
       JOIN ObjectCatalog sc ON ol.Source_UUID = sc.Object_UUID AND sc.File_Name = ol.Source_File
       JOIN ObjectCatalog tc ON ol.Target_UUID = tc.Object_UUID AND tc.File_Name IS NOT DISTINCT FROM ol.Target_File
       WHERE ol.Link_Role = 'grants_privilege'
         AND tc.Object_Name IN ('fmrest','fmurlscript','fmodata','fmxml','fmphp','fmextscriptaccess')
         AND (getvariable('file') IS NULL OR sc.File_Name = getvariable('file')))  AS server_grants;
