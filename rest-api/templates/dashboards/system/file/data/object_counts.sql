-- Per-type object counts, scoped to one file. File-scoped clone of the home
-- object_counts dataset. File_Name is carried so the KPI tiles can navigate into
-- the file-filtered search of that type (applyFilter { type, file }).
SELECT
    :file AS File_Name,
    COUNT(*) FILTER (WHERE Object_Type = 'Script')          AS scripts,
    COUNT(*) FILTER (WHERE Object_Type = 'Field')           AS fields,
    COUNT(*) FILTER (WHERE Object_Type = 'BaseTable')       AS tables,
    COUNT(*) FILTER (WHERE Object_Type = 'TableOccurrence') AS occurrences,
    COUNT(*) FILTER (WHERE Object_Type = 'Layout')          AS layouts,
    COUNT(*) FILTER (WHERE Object_Type = 'CustomFunction')  AS custom_functions,
    COUNT(*) FILTER (WHERE Object_Type = 'ValueList')       AS value_lists,
    COUNT(*) FILTER (WHERE Object_Type = 'Relationship')    AS relationships,
    COUNT(*) FILTER (WHERE Object_Type = 'Variable')        AS variables
FROM ObjectCatalog
WHERE File_Name = :file;
