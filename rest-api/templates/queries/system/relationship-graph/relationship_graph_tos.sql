-- @template_type: report
-- @description: Table Occurrences einer FileMaker-Datei mit Geometrie und Farbe für das Beziehungsdiagramm
-- @params: file_name (required)
-- @author: Marcel
-- @version: 1.0
-- @tags: relationship-graph, table-occurrence, geometry

SELECT
    TO_UUID,
    TO_ID,
    TO_Name,
    TO_Type,
    BT_Name,
    BT_UUID,
    DS_Name,
    DS_UUID,
    View_State,
    Box_Height,
    Coord_Top,
    Coord_Left,
    Coord_Bottom,
    Coord_Right,
    Color_R,
    Color_G,
    Color_B,
    Color_Alpha
FROM TableOccurrenceCatalog
WHERE File_Name = getvariable('file_name')
ORDER BY TO_ID;
