-- @template_type: report
-- @title: Top variables
-- @description: Variables with the most set/read operations.
-- @icon: variable
-- @display: table
-- @chip_filter: scope
-- @params: limit (optional, default 100), file (optional)
-- @click_action: openObject
-- @click_args: uuid={{uuid}}&type=Variable
-- @output_format: uuid, name, scope, file, usage_count
-- @object_types: Variable
-- @author: fm-lab core
-- @version: 1.2
-- @note: VariablesCatalog is aggregated and has no own UUID — we resolve the UUID
--        of an arbitrary usage instance from ObjectCatalog so clicks can jump into
--        the detail view (same approach as the health_hints variable hot-spots).
--        The `scope` column is bucketed to the FileMaker prefix convention
--        ($ local, $$ global, $$$ superglobal) so the generic renderer's
--        @chip_filter draws one chip per scope over the loaded top-N rows.
-- @tags: variables, top, ranking

WITH agg AS (
    SELECT
        vc.Variable_Name,
        vc.Display_Name                     AS name,
        vc.File_Name,
        vc.Set_Count + vc.Read_Count        AS usage_count,
        CASE vc.Variable_Scope
            WHEN 'local'       THEN '$'
            WHEN 'let_local'   THEN '$'
            WHEN 'global'      THEN '$$'
            WHEN 'superglobal' THEN '$$$'
            ELSE COALESCE(vc.Variable_Scope, '?')
        END                                 AS scope
    FROM VariablesCatalog vc
    WHERE (getvariable('file') IS NULL OR vc.File_Name = getvariable('file'))
)
SELECT
    (
        SELECT MIN(oc.Object_UUID)
        FROM ObjectCatalog oc
        WHERE oc.Object_Type = 'Variable'
          AND oc.Object_Name = a.Variable_Name
          AND oc.File_Name   = a.File_Name
    )                                       AS uuid,
    a.name                                  AS name,
    a.scope                                 AS scope,
    a.File_Name                             AS file,
    a.usage_count                           AS usage_count
FROM agg a
WHERE a.usage_count > 0
ORDER BY a.usage_count DESC, a.name, a.File_Name, a.scope   -- tie-breakers: stable rows at the LIMIT
LIMIT CAST(COALESCE(getvariable('limit'), '100') AS INTEGER);
