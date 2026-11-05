-- @template_type: report
-- @description: Count objects by type and file
-- @params: file_name (optional)
-- @output_format: object_type, file_name, count
-- @author: Marcel
-- @version: 1.0
-- @tags: statistics, objects

SELECT
    Object_Type as object_type,
    File_Name as file_name,
    COUNT(*) as count
FROM ObjectCatalog
WHERE (getvariable('file_name') IS NULL OR File_Name = getvariable('file_name'))
GROUP BY Object_Type, File_Name
ORDER BY Object_Type, File_Name;
