-- @template_type: report
-- @description: Aggregierte Anzahlen je Objekttyp aus ObjectCatalog.
-- @params: none

SELECT
    COUNT(*) FILTER (WHERE Object_Type = 'Script')                                 AS scripts,
    COUNT(*) FILTER (WHERE Object_Type = 'Field')           AS fields,
    COUNT(*) FILTER (WHERE Object_Type = 'BaseTable')       AS tables,
    COUNT(*) FILTER (WHERE Object_Type = 'TableOccurrence') AS occurrences,
    COUNT(*) FILTER (WHERE Object_Type = 'Layout')          AS layouts,
    COUNT(*) FILTER (WHERE Object_Type = 'CustomFunction')  AS custom_functions,
    COUNT(*) FILTER (WHERE Object_Type = 'ValueList')       AS value_lists,
    COUNT(*) FILTER (WHERE Object_Type = 'Relationship')    AS relationships,
    COUNT(*) FILTER (WHERE Object_Type = 'Variable')        AS variables
FROM ObjectCatalog;
