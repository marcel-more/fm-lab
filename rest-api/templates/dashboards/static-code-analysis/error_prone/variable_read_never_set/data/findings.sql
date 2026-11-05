-- Variables that are read although nothing in the catalog ever writes them.
-- Either the write side was renamed or removed, or the value is expected to
-- arrive from somewhere the export does not cover. Translated from fmCheckMate
-- VarsUndefined.
--
-- Let() definitions are excluded outright: a Let variable is defined and read
-- inside the same formula, so the import records it as a read without a
-- matching write — on a large solution that class alone is roughly five times
-- the size of the real finding set and would drown it.
--
-- Scope: local variables are confined to their own script, globals are counted
-- file-wide — which is exactly the scope FileMaker gives a $$ variable. A
-- global written in one script and read in another is therefore no finding.
--
-- `also_set_in` counts the OTHER files whose catalog writes the same name. A
-- high number means the reading side assumes a value crossing file boundaries,
-- which FileMaker's per-file scope does not provide — a different (and usually
-- more interesting) defect than a plain typo.
--
-- Deep link: reads inside script steps jump to the script, with `step` as the
-- scroll anchor and `marks` highlighting every reading step. Reads that only
-- happen in a custom function, a field calculation or a layout object have no
-- step at all; those rows navigate to that object instead (layout objects via
-- their layout plus `ref`, the pattern the layout rules use).
WITH vars AS (
    SELECT File_Name, Variable_Scope, Scope_Anchor, Normalized_Name,
           any_value(Display_Name) AS display_name,
           any_value(First_Seen_Context) AS first_seen,
           any_value(Script_UUID) AS script_uuid,
           -- Variable object UUIDs (ObjectCatalog identity) — an object scope on a
           -- Variable matches its own finding, not only the script it lives in.
           list(md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) ORDER BY Variable_Scope, Scope_Anchor, Variable_Name) AS var_uuids,
           any_value(Source_Reliability) AS source_reliability,
           CAST(sum(Set_Count) AS INTEGER) AS set_count,
           CAST(sum(Read_Count) AS INTEGER) AS read_count
    FROM VariablesCatalog
    WHERE Variable_Scope <> 'let_local'
    GROUP BY 1, 2, 3, 4
),
findings AS (
    SELECT * FROM vars WHERE set_count = 0 AND read_count > 0
),
usage AS (
    SELECT f.File_Name, f.Variable_Scope, f.Scope_Anchor, f.Normalized_Name,
           vu.Script_UUID, vu.Step_Index, st.Step_UUID, sc.Script_Name
    FROM findings f
    JOIN VariableUsages vu
      ON vu.File_Name = f.File_Name
     AND vu.Variable_Scope = f.Variable_Scope
     AND vu.Variable_Name = f.display_name
     AND vu.Usage_Type = 'read'
     AND vu.Context_Type = 'script_step'
     AND (f.Variable_Scope <> 'local' OR vu.Script_UUID = f.Scope_Anchor)
    JOIN StepsForScripts st ON st.Script_UUID = vu.Script_UUID AND st.Step_Index = vu.Step_Index AND st.File_Name = vu.File_Name
    LEFT JOIN ScriptCatalog sc ON sc.Script_UUID = vu.Script_UUID AND sc.File_Name = vu.File_Name
),
per_script AS (
    SELECT File_Name, Variable_Scope, Scope_Anchor, Normalized_Name, Script_UUID,
           any_value(Script_Name) AS script_name,
           count(*) AS occurrences,
           list(Step_UUID ORDER BY Step_Index) AS step_uuids
    FROM usage
    GROUP BY 1, 2, 3, 4, 5
),
ranked AS (
    SELECT *,
           row_number() OVER (PARTITION BY File_Name, Variable_Scope, Scope_Anchor, Normalized_Name
                              ORDER BY occurrences DESC, script_name, Script_UUID) AS rn,
           count(*) OVER (PARTITION BY File_Name, Variable_Scope, Scope_Anchor, Normalized_Name) AS script_count
    FROM per_script
),
-- Fallback for reads outside scripts. The context object is always a catalog
-- object; a layout object is redirected to its layout so the canvas can
-- highlight it.
other AS (
    SELECT f.File_Name, f.Variable_Scope, f.Scope_Anchor, f.Normalized_Name,
           CASE WHEN oc.Object_Type = 'LayoutObject' THEN ly.L_UUID ELSE oc.Object_UUID END AS nav_uuid,
           CASE WHEN oc.Object_Type = 'LayoutObject' THEN 'Layout' ELSE oc.Object_Type END AS nav_type,
           CASE WHEN oc.Object_Type = 'LayoutObject' THEN oc.Object_UUID END AS nav_ref,
           CASE WHEN oc.Object_Type = 'LayoutObject' THEN ly.L_Name ELSE oc.Object_Name END AS nav_name,
           row_number() OVER (PARTITION BY f.File_Name, f.Variable_Scope, f.Scope_Anchor, f.Normalized_Name
                              ORDER BY oc.Object_Type, oc.Object_Name) AS rn
    FROM findings f
    JOIN VariableUsages vu
      ON vu.File_Name = f.File_Name
     AND vu.Variable_Scope = f.Variable_Scope
     AND vu.Variable_Name = f.display_name
     AND vu.Usage_Type = 'read'
     AND vu.Context_Type <> 'script_step'
    JOIN ObjectCatalog oc ON oc.Object_UUID = vu.Context_UUID
    LEFT JOIN LayoutObjects lo ON lo.Object_UUID = vu.Context_UUID
    LEFT JOIN Layouts ly ON ly.L_ID = lo.Layout_ID AND ly.File_Name = lo.File_Name
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'variable-read-never-set' AS rule_id, 'info' AS severity,
        f.File_Name AS file_name,
        COALESCE(f.script_uuid, r.Script_UUID, o.nav_uuid) AS nav_uuid,
        COALESCE(CASE WHEN r.Script_UUID IS NOT NULL OR f.script_uuid IS NOT NULL THEN 'Script' END, o.nav_type) AS nav_type,
        o.nav_ref,
        f.display_name AS variable_name,
        f.Variable_Scope AS variable_scope,
        COALESCE(r.script_name, o.nav_name, f.first_seen) AS context,
        f.read_count,
        f.source_reliability,
        CAST((SELECT count(DISTINCT vc.File_Name) FROM VariablesCatalog vc
               WHERE vc.Variable_Scope = f.Variable_Scope
                 AND vc.Normalized_Name = f.Normalized_Name
                 AND vc.File_Name <> f.File_Name
                 AND vc.Set_Count > 0) AS INTEGER) AS also_set_in,
        r.step_uuids[1] AS step_uuid,
        -- list_slice instead of the [1:25] slice syntax: the dashboard SQL
        -- preprocessor replaces every :word — including the ':25' of a slice.
        array_to_string(list_slice(r.step_uuids, 1, 25), ',') AS marks,
        'Variable is read ' || f.read_count || ' time(s) but never set'
          || CASE WHEN r.script_count > 1 THEN ' — read in ' || r.script_count || ' scripts' ELSE '' END AS message,
           f.File_Name AS _ord_1,
           f.Variable_Scope AS _ord_2,
           f.Normalized_Name AS _ord_3
    FROM findings f
    LEFT JOIN ranked r
           ON r.File_Name = f.File_Name
          AND r.Variable_Scope = f.Variable_Scope
          AND r.Scope_Anchor IS NOT DISTINCT FROM f.Scope_Anchor
          AND r.Normalized_Name = f.Normalized_Name
          AND r.rn = 1
    LEFT JOIN other o
           ON o.File_Name = f.File_Name
          AND o.Variable_Scope = f.Variable_Scope
          AND o.Scope_Anchor IS NOT DISTINCT FROM f.Scope_Anchor
          AND o.Normalized_Name = f.Normalized_Name
          AND o.rn = 1
    WHERE (getvariable('variable_scope') IS NULL OR f.Variable_Scope = getvariable('variable_scope'))
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR COALESCE(f.script_uuid, r.Script_UUID, o.nav_uuid) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
           OR list_has_any(f.var_uuids, string_split(getvariable('scope_uuids'), ',')))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u) AS row_key
    FROM unkeyed u
),
-- >>> shared paging table-search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) NOT IN ('uuid', 'nav_uuid', 'row_key')))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging table-search block
filtered AS (
    SELECT * FROM searched
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
