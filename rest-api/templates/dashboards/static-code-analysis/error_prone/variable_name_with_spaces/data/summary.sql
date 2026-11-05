-- Hand-maintained wrapper around the rule core (variable_name_with_spaces).
-- The scope chips must show their true totals, so the variable_scope filter is
-- deliberately NOT applied here.
WITH vars AS (
    SELECT File_Name, Variable_Scope, Scope_Anchor, Normalized_Name,
           any_value(Display_Name) AS display_name,
           any_value(Script_UUID) AS script_uuid,
           -- Variable object UUIDs (ObjectCatalog identity) — an object scope on a
           -- Variable matches its own finding, not only the script it lives in.
           list(md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) ORDER BY Variable_Scope, Scope_Anchor, Variable_Name) AS var_uuids,
           bool_or(Has_Spaces) AS has_spaces
    FROM VariablesCatalog
    GROUP BY 1, 2, 3, 4
),
nav AS (
    SELECT File_Name, Variable_Scope, Variable_Name, min(Script_UUID) AS script_uuid
    FROM VariableUsages
    WHERE Script_UUID IS NOT NULL
    GROUP BY 1, 2, 3
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE v.Variable_Scope = 'local')       AS local_count,
       COUNT(*) FILTER (WHERE v.Variable_Scope = 'global')      AS global_count,
       COUNT(*) FILTER (WHERE v.Variable_Scope = 'let_local')   AS let_local_count,
       COUNT(*) FILTER (WHERE v.Variable_Scope = 'superglobal') AS superglobal_count,
       COUNT(DISTINCT v.File_Name) AS affected_files
FROM vars v
LEFT JOIN nav n ON n.File_Name = v.File_Name
                AND n.Variable_Scope = v.Variable_Scope
                AND n.Variable_Name = v.display_name
WHERE v.has_spaces
  AND (getvariable('file') IS NULL OR v.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR COALESCE(v.script_uuid, n.script_uuid) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
       OR list_has_any(v.var_uuids, string_split(getvariable('scope_uuids'), ',')));
