-- Hand-maintained wrapper around the rule core (variable_set_never_read).
-- The scope chips (local / global) must show their true totals, so the
-- variable_scope filter is deliberately NOT applied here.
WITH vars AS (
    SELECT File_Name, Variable_Scope, Scope_Anchor, Normalized_Name,
           any_value(Display_Name) AS display_name,
           any_value(Script_UUID) AS script_uuid,
           -- Variable object UUIDs (ObjectCatalog identity) — an object scope on a
           -- Variable matches its own finding, not only the script it lives in.
           list(md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) ORDER BY Variable_Scope, Scope_Anchor, Variable_Name) AS var_uuids,
           CAST(sum(Set_Count) AS INTEGER) AS set_count,
           CAST(sum(Read_Count) AS INTEGER) AS read_count
    FROM VariablesCatalog
    GROUP BY 1, 2, 3, 4
),
nav AS (
    SELECT File_Name, Variable_Scope, Variable_Name, min(Script_UUID) AS script_uuid
    FROM VariableUsages
    WHERE Script_UUID IS NOT NULL AND Usage_Type = 'set'
    GROUP BY 1, 2, 3
)
SELECT COUNT(*) AS finding_count,
       COUNT(*) FILTER (WHERE v.Variable_Scope = 'local')  AS local_count,
       COUNT(*) FILTER (WHERE v.Variable_Scope = 'global') AS global_count,
       COUNT(DISTINCT COALESCE(v.script_uuid, n.script_uuid)) AS affected_scripts,
       COUNT(DISTINCT v.File_Name) AS affected_files
FROM vars v
LEFT JOIN nav n ON n.File_Name = v.File_Name
                AND n.Variable_Scope = v.Variable_Scope
                AND n.Variable_Name = v.display_name
WHERE v.set_count > 0 AND v.read_count = 0
  AND (getvariable('file') IS NULL OR v.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR COALESCE(v.script_uuid, n.script_uuid) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
       OR list_has_any(v.var_uuids, string_split(getvariable('scope_uuids'), ',')));
