-- @template_type: report
-- @description: Beziehungen einer FileMaker-Datei mit JoinPredicates für das Beziehungsdiagramm
-- @params: file_name (required)
-- @author: Marcel
-- @version: 1.0
-- @tags: relationship-graph, relationship, join-predicates

SELECT
    Rel_ID,
    Left_TO_UUID,
    Left_TO_Name,
    Left_Delete,
    Left_Create,
    Right_TO_UUID,
    Right_TO_Name,
    Right_Delete,
    Right_Create,
    Operator,
    Left_Field_UUID,
    Left_Field_Name,
    Right_Field_UUID,
    Right_Field_Name
FROM RelationshipCatalog
WHERE File_Name = getvariable('file_name')
ORDER BY Rel_ID;
