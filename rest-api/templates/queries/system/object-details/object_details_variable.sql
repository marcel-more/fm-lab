-- @template_type: content
-- @description: Display variable details with all usages, contexts, and cross-references
-- @params: uuid (optional), name (optional), file (optional)
-- @output_format: content
-- @author: Marcel
-- @version: 1.2
-- @tags: variables, variable-usages, dependencies, cross-reference
-- @note: Use generic parameters: uuid, name, file (consistent with REST API)
-- @note: UUID is md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name)
-- @note: The UUID carries no file. Local variables of clone files (same script
--        UUIDs) share it; VariablesCatalog keeps one row per file, so the UUID
--        branch and the usages are scoped to the resolved file.

WITH var_match AS (
    SELECT
        vc.Variable_Name,
        vc.Variable_Scope,
        vc.Scope_Anchor,
        vc.Display_Name,
        vc.Normalized_Name,
        vc.Set_Count,
        vc.Read_Count,
        vc.Script_Count,
        vc.File_Count,
        vc.Files,
        vc.First_Seen_Context,
        vc.Has_Spaces,
        vc.Source_Reliability,
        vc.File_Name
    FROM VariablesCatalog vc
    WHERE (
        -- Match by UUID (preferred), scoped to the resolved file
        (getvariable('uuid') IS NOT NULL
         AND md5(vc.Variable_Scope || '::' || vc.Scope_Anchor || '::' || vc.Variable_Name) = getvariable('uuid')
         AND (getvariable('file') IS NULL OR vc.File_Name = getvariable('file')))
        OR
        -- Match by Name (with optional file filter)
        (getvariable('name') IS NOT NULL
         AND (vc.Variable_Name = getvariable('name') OR vc.Display_Name = getvariable('name'))
         AND (getvariable('file') IS NULL OR vc.File_Name = getvariable('file')))
    )
    LIMIT 1
),
usages AS (
    SELECT
        vu.Usage_Type,
        vu.Context_Type,
        vu.Context_Name,
        vu.Script_Name,
        vu.Step_Index,
        vu.Table_Name,
        vu.Field_Name,
        vu.Source,
        vu.File_Name,
        -- line order of the sections (string_agg needs an explicit ORDER BY:
        -- the REST connection runs with preserve_insertion_order=false)
        row_number() OVER (ORDER BY vu.Usage_Type DESC, vu.Context_Type, vu.Context_Name,
                                    vu.Step_Index, vu.Script_Name, vu.File_Name, vu.Source) AS ord
    FROM VariableUsages vu
    JOIN var_match vm
        ON vu.Variable_Name  = vm.Variable_Name
       AND vu.Variable_Scope = vm.Variable_Scope
       AND vu.Scope_Anchor   = vm.Scope_Anchor
       -- local/let_local: one catalog row per file (clone files share the anchor)
       AND (vm.Variable_Scope NOT IN ('local', 'let_local') OR vu.File_Name = vm.File_Name)
),
header AS (
    SELECT string_agg(line, chr(10) ORDER BY ord) as content FROM (
        SELECT 1 AS ord, '# Variable: ' || vm.Display_Name as line FROM var_match vm
        UNION ALL SELECT 2, '' FROM var_match
        UNION ALL
        SELECT 3, 'Scope: ' || vm.Variable_Scope
            || '  |  Sets: ' || vm.Set_Count
            || '  |  Reads: ' || vm.Read_Count
            || '  |  Scripts: ' || vm.Script_Count
            || '  |  Dateien: ' || vm.File_Count
        FROM var_match vm
        UNION ALL SELECT 4, '' FROM var_match
        UNION ALL
        SELECT 5, 'Quelle: ' || vm.Source_Reliability
            || CASE WHEN vm.Has_Spaces THEN '  |  Leerzeichen im Namen' ELSE '' END
        FROM var_match vm
        UNION ALL
        SELECT 6, 'Dateien: ' || array_to_string(vm.Files, ', ') FROM var_match vm
        UNION ALL SELECT 7, '' FROM var_match
        UNION ALL SELECT 8, '---' FROM var_match
        UNION ALL SELECT 9, '' FROM var_match
    )
),
set_section AS (
    SELECT string_agg(line, chr(10) ORDER BY ord) as content FROM (
        SELECT -1 AS ord, '## Zuweisungen (Set)' as line
        UNION ALL SELECT 0, ''
        UNION ALL
        SELECT
            u.ord,
            CASE u.Context_Type
                WHEN 'script_step' THEN '  ' || u.Script_Name || ' [Schritt ' || u.Step_Index || ']'
                WHEN 'layout_object' THEN '  Layout: ' || u.Context_Name
                ELSE '  ' || COALESCE(u.Context_Name, '?')
            END
            || '  (' || u.Source || ', ' || u.File_Name || ')'
        FROM usages u
        WHERE u.Usage_Type = 'set'
    )
),
read_section AS (
    SELECT string_agg(line, chr(10) ORDER BY ord) as content FROM (
        SELECT -1 AS ord, '## Lesezugriffe (Read)' as line
        UNION ALL SELECT 0, ''
        UNION ALL
        SELECT
            u.ord,
            CASE u.Context_Type
                WHEN 'script_step' THEN '  ' || u.Script_Name || ' [Schritt ' || u.Step_Index || ']'
                WHEN 'calculation' THEN '  Feld: ' || u.Context_Name
                WHEN 'auto_enter_calc' THEN '  AutoEnter: ' || u.Context_Name
                WHEN 'custom_function' THEN '  CF: ' || u.Context_Name
                WHEN 'layout_object' THEN '  Layout: ' || u.Context_Name
                ELSE '  ' || COALESCE(u.Context_Name, '?')
            END
            || '  (' || u.Source || ', ' || u.File_Name || ')'
        FROM usages u
        WHERE u.Usage_Type = 'read'
    )
)
SELECT
    COALESCE(h.content, '') || chr(10)
    || COALESCE(s.content, '') || chr(10) || chr(10)
    || COALESCE(r.content, '')
    as content
FROM header h, set_section s, read_section r;
