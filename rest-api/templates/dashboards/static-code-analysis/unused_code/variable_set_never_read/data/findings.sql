-- Variables that are written but never read anywhere in the catalog. Dead
-- weight at best; at worst the read side was renamed and the write is now
-- pointless. Translated from fmCheckMate VarsDefinedButUnused, but built on the
-- import-time variable resolution instead of the source's substring search over
-- calculation text — every read in a step, layout calculation, custom function
-- or field formula is a resolved usage here.
--
-- Aggregated over the variable's own scope key (script for local variables,
-- file for globals), because a variable can carry several catalog rows when it
-- was seen through more than one evidence source. That scope key is also what
-- makes the global case correct: FileMaker's $$ variables live per file, so a
-- global written in one script and read in another counts as read.
--
-- Deep link: the row click jumps to the script and marks the writing steps.
-- `step` is the scroll anchor (first write), `marks` carries every write in
-- that script as a literal step UUID — the script viewer highlights each line
-- whose step UUID is in the set. Step UUIDs are resolved through
-- StepsForScripts, because VariableUsages carries the SCRIPT in Context_UUID,
-- not the step.
--
-- False-positive classes documented in the rule description: values handed on
-- as script parameters, variable names assembled at runtime, and reads that
-- happen outside the exported files.
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
    GROUP BY 1, 2, 3, 4
),
findings AS (
    SELECT * FROM vars WHERE set_count > 0 AND read_count = 0
),
-- Writing steps in scope. Local variables are confined to their own script
-- (Scope_Anchor holds its UUID); globals are collected file-wide, which is
-- exactly the scope FileMaker gives them.
usage AS (
    SELECT f.File_Name, f.Variable_Scope, f.Scope_Anchor, f.Normalized_Name,
           vu.Script_UUID, vu.Step_Index, st.Step_UUID, sc.Script_Name
    FROM findings f
    JOIN VariableUsages vu
      ON vu.File_Name = f.File_Name
     AND vu.Variable_Scope = f.Variable_Scope
     AND vu.Variable_Name = f.display_name
     AND vu.Usage_Type = 'set'
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
-- A global can be written in several scripts (measured: up to 47). The jump
-- goes to the script carrying the most writes; the total and the number of
-- scripts stay visible in the message.
ranked AS (
    SELECT *,
           row_number() OVER (PARTITION BY File_Name, Variable_Scope, Scope_Anchor, Normalized_Name
                              ORDER BY occurrences DESC, script_name, Script_UUID) AS rn,
           sum(occurrences) OVER (PARTITION BY File_Name, Variable_Scope, Scope_Anchor, Normalized_Name) AS total_occurrences,
           count(*) OVER (PARTITION BY File_Name, Variable_Scope, Scope_Anchor, Normalized_Name) AS script_count
    FROM per_script
),
-- The finding rows. The keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone: (file, scope,
-- name) is not unique — a local variable of the same name lives in many scripts.
unkeyed AS MATERIALIZED (
    SELECT 'variable-set-never-read' AS rule_id, 'info' AS severity,
        f.File_Name AS file_name,
        COALESCE(f.script_uuid, r.Script_UUID) AS nav_uuid,
        f.display_name AS variable_name,
        f.Variable_Scope AS variable_scope,
        COALESCE(r.script_name, f.first_seen) AS context,
        f.set_count,
        f.source_reliability,
        r.step_uuids[1] AS step_uuid,
        -- Cap keeps the URL manageable; measured median is 1 write per finding.
        -- list_slice instead of the [1:25] slice syntax: the dashboard SQL
        -- preprocessor replaces every :word — including the ':25' of a slice.
        array_to_string(list_slice(r.step_uuids, 1, 25), ',') AS marks,
        'Variable is set ' || f.set_count || ' time(s) but never read'
          || CASE WHEN r.script_count > 1 THEN ' — writes spread over ' || r.script_count || ' scripts' ELSE '' END AS message,
        f.File_Name AS _ord_1, f.Variable_Scope AS _ord_2, f.Normalized_Name AS _ord_3
    FROM findings f
    LEFT JOIN ranked r
           ON r.File_Name = f.File_Name
          AND r.Variable_Scope = f.Variable_Scope
          AND r.Scope_Anchor IS NOT DISTINCT FROM f.Scope_Anchor
          AND r.Normalized_Name = f.Normalized_Name
          AND r.rn = 1
    WHERE (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR COALESCE(f.script_uuid, r.Script_UUID) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
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
    WHERE (getvariable('variable_scope') IS NULL OR variable_scope = getvariable('variable_scope'))
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
SELECT f.*, pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
