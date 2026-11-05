-- @template_type: report
-- @description: Felder aller BaseTables einer Datei für die TO-Box-Darstellung im Beziehungsdiagramm
-- @params: file_name (required)
-- @author: Marcel
-- @version: 1.0
-- @tags: relationship-graph, fields

SELECT
    Field_UUID,
    Field_ID,
    Field_Name,
    Field_Type,
    Data_Type,
    Table_UUID,
    Table_Name
FROM FieldsForTables
WHERE File_Name = getvariable('file_name')
ORDER BY Table_Name, Field_ID;
