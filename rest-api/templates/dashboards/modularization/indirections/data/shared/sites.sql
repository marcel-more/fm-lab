-- Shared core of the indirections inventory (included by every dataset of the
-- bundle): one row per place where the solution addresses an object through a
-- computed name, number or text, plus the filtered base population.
-- A fragment of one statement: CTE pieces, each ending with a comma.
steps AS (
    SELECT Step_UUID, File_Name, Script_UUID, Script_Name, Step_Index, Step_ID, Is_Enabled, Parameters_XML
    FROM StepsForScripts
),
-- Navigation mode of a step's target layout parameter (Go to Layout, Go to
-- List of Records, GTRR): 3 = name by calculation, 4 = number by calculation.
-- The mode is written only into the step parameters; the match is anchored at
-- the target parameter (Go to List of Records carries a second container in
-- its window parameter).
layout_mode AS (
    SELECT s.*, TRY_CAST(regexp_extract(s.Parameters_XML,
               '<Parameter type="LayoutReferenceContainer">\s*<LayoutReferenceContainer value="(\d)"', 1) AS INTEGER) AS mode
    FROM steps s
    WHERE contains(s.Parameters_XML, '<Parameter type="LayoutReferenceContainer">')
),
-- Perform Script (1) / on Server (164) / with Callback (210) in mode "By name".
script_byname AS (
    SELECT s.* FROM steps s
    WHERE s.Step_ID IN (1, 164, 210) AND regexp_matches(s.Parameters_XML, '<List [^>]*value="2"')
),
step_slot_sites AS (
    -- M01/M02 script by name (with formula)
    SELECT c.Step_UUID, c.File_Name, CASE WHEN c.Step_ID = 1 THEN 'M01' ELSE 'M02' END AS mechanism_id, c.Calc_Text AS expr
    FROM StepCalculations c WHERE c.Step_ID IN (1, 164, 210) AND c.Slot = 'List'
    UNION ALL
    -- M01/M02 by name without formula
    SELECT b.Step_UUID, b.File_Name, CASE WHEN b.Step_ID = 1 THEN 'M01' ELSE 'M02' END, NULL
    FROM script_byname b
    WHERE NOT EXISTS (SELECT 1 FROM StepCalculations c
                      WHERE c.Step_UUID = b.Step_UUID AND c.File_Name = b.File_Name AND c.Slot = 'List')
    UNION ALL
    -- M10/M11 layout by name / number (formula may be missing)
    SELECT m.Step_UUID, m.File_Name, CASE m.mode WHEN 3 THEN 'M10' ELSE 'M11' END,
           (SELECT c.Calc_Text FROM StepCalculations c
             WHERE c.Step_UUID = m.Step_UUID AND c.File_Name = m.File_Name AND c.Slot = 'LayoutReferenceContainer'
             ORDER BY c.Calc_Position LIMIT 1)
    FROM layout_mode m WHERE m.mode IN (3, 4)
    UNION ALL
    -- M12 Execute FileMaker Data API (request formula)
    SELECT c.Step_UUID, c.File_Name, 'M12', c.Calc_Text
    FROM StepCalculations c WHERE c.Step_ID = 203 AND c.Slot = ('Parameter' || ':' || 'Calculation')
    UNION ALL
    -- M20 Set Field By Name: target formula (position 1) or the active field
    SELECT s.Step_UUID, s.File_Name, 'M20',
           (SELECT c.Calc_Text FROM StepCalculations c
             WHERE c.Step_UUID = s.Step_UUID AND c.File_Name = s.File_Name
               AND c.Slot = ('Parameter' || ':' || 'Calculation') AND c.Calc_Position = 1)
    FROM steps s WHERE s.Step_ID = 147
    UNION ALL
    -- M33 Execute SQL with calculated SQL text
    SELECT c.Step_UUID, c.File_Name, 'M33', c.Calc_Text
    FROM StepCalculations c WHERE c.Step_ID = 117 AND c.Slot = 'SQL'
    UNION ALL
    -- M40 Go to Object, M41 other object-name slots
    SELECT c.Step_UUID, c.File_Name, CASE WHEN c.Step_ID = 145 THEN 'M40' ELSE 'M41' END, c.Calc_Text
    FROM StepCalculations c
    WHERE (c.Step_ID IN (145, 167, 180, 177) AND c.Slot = 'Name')
       OR (c.Step_ID = 146 AND c.Slot = ('Parameter' || ':' || 'Calculation') AND c.Calc_Position = 0)
       OR (c.Step_ID = 175 AND c.Slot = ('Parameter' || ':' || 'Name'))
    UNION ALL
    -- M70 window by name
    SELECT c.Step_UUID, c.File_Name, 'M70', c.Calc_Text
    FROM StepCalculations c WHERE c.Step_ID IN (119, 121, 123, 124) AND c.Slot = 'Name'
),
step_sites AS (
    SELECT x.mechanism_id, x.expr, s.File_Name AS file_name,
           'Script' AS carrier_type, s.Script_UUID AS nav_uuid, 'Script' AS nav_type, s.Script_Name AS carrier_name,
           s.Step_Index, s.Step_UUID AS step_uuid, s.Step_ID, s.Is_Enabled AS is_enabled,
           FALSE AS low_confidence, CAST(NULL AS VARCHAR) AS target_hint
    FROM step_slot_sites x
    JOIN steps s ON s.Step_UUID = x.Step_UUID AND s.File_Name = x.File_Name
),
-- Formula functions per calculation instance (locale-independent function id).
fn_map(function_id, mechanism_id) AS (VALUES
    (245, 'M30'), (250, 'M21'), (268, 'M42'),
    (80, 'M50v'), (63, 'M50f'), (64, 'M50f'), (67, 'M50f'), (68, 'M50f'), (69, 'M50f'), (70, 'M50f'),
    (375, 'M50f'), (376, 'M50f'), (65, 'M50l'), (66, 'M50l'), (73, 'M50l'), (74, 'M50t'), (374, 'M50t'),
    (60, 'M60'), (61, 'M60'), (62, 'M60'), (71, 'M60'), (72, 'M60'), (75, 'M60'), (76, 'M60'),
    (77, 'M60'), (78, 'M60'), (79, 'M60'), (81, 'M60'), (82, 'M60')
),
builtin AS (SELECT DISTINCT Object_UUID, Function_ID FROM v_builtin_token_lookup),
calc_fn_edge AS (
    SELECT DISTINCT l.Calculation_UUID, m.mechanism_id
    FROM v_calculation_links l
    JOIN builtin b ON b.Object_UUID = l.Target_UUID
    JOIN fn_map m ON m.function_id = b.Function_ID
    WHERE l.Link_Role = 'calls_function'
),
-- Files exported without DDR-Info carry no calls_function edges: the calls are
-- matched in the formula text instead (low confidence). String literals and
-- comments are blanked first; a token counts when "(" follows it (any
-- whitespace incl. no-break space). WindowNames and DatabaseNames may be
-- written without parentheses and also count as a bare token. Token names
-- resolve through the reference (every language FileMaker spells a function
-- in) — the catalog's own built-in nodes exist only where DDR chunks named them.
fn_names AS (
    SELECT DISTINCT lower(l.lookup_name) AS name_norm, l.function_id
    FROM ref.function_name_lookup l
    WHERE l.chunk_role = 'function' AND l.lookup_name IS NOT NULL AND l.lookup_name <> ''
),
noddr_calcs AS (
    SELECT cc.Calculation_UUID,
           regexp_replace(regexp_replace(regexp_replace(coalesce(cc.Formula_Text, cc.Display_Text),
               '"([^"\\]|\\.)*"', '""', 'g'), '/\*(.|\n)*?\*/', ' ', 'g'), '//[^\n]*', ' ', 'g') AS txt
    FROM CalculationsCatalog cc
    JOIN FilesCatalog fc ON fc.File_Name = cc.File_Name
    WHERE NOT coalesce(fc.Has_DDR_INFO, FALSE)
),
noddr_tokens AS (
    SELECT DISTINCT n.Calculation_UUID, lower(t.tok) AS tok, TRUE AS is_call
    FROM noddr_calcs n, unnest(regexp_extract_all(n.txt, '([\pL\pN_.]+)[\s\p{Z}]*\(', 1)) AS t(tok)
    UNION
    SELECT DISTINCT n.Calculation_UUID, lower(t.tok) AS tok, FALSE AS is_call
    FROM noddr_calcs n, unnest(regexp_extract_all(n.txt, '[\pL\pN_.]+')) AS t(tok)
),
calc_fn_text AS (
    SELECT DISTINCT k.Calculation_UUID, m.mechanism_id
    FROM noddr_tokens k
    JOIN fn_names fnn ON fnn.name_norm = k.tok
    JOIN fn_map m ON m.function_id = fnn.function_id
    WHERE k.is_call OR fnn.function_id IN (62, 82)   -- DatabaseNames, WindowNames
),
calc_fn AS (
    SELECT e.Calculation_UUID, e.mechanism_id, FALSE AS low_conf FROM calc_fn_edge e
    UNION
    SELECT t.Calculation_UUID, t.mechanism_id, TRUE AS low_conf FROM calc_fn_text t
    WHERE NOT EXISTS (SELECT 1 FROM calc_fn_edge e
                      WHERE e.Calculation_UUID = t.Calculation_UUID AND e.mechanism_id = t.mechanism_id)
),
-- SQL statements of ExecuteSQL with parts built at run time (M31) or with
-- plain names in the SQL text (M32), one row per statement.
sql_stmt AS (
    SELECT r.Calculation_UUID, r.File_Name, r.Sql_Index,
           bool_or(r.Resolution = 'dynamic' AND coalesce(r.Clause, '') <> 'parameter') AS is_dynamic,
           bool_or(r.Resolution = 'name') AS has_name,
           bool_or(r.Resolution = 'name' AND r.Target_Type IS NULL AND NOT r.Low_Confidence
                   AND r.Clause <> 'parameter') AS name_missing,
           bool_or(r.Low_Confidence) AS low_conf,
           string_agg(DISTINCT CASE WHEN r.Resolution = 'dynamic' AND coalesce(r.Clause, '') <> 'parameter'
                                    THEN r.Raw_Name END, ' · '
                      ORDER BY CASE WHEN r.Resolution = 'dynamic' AND coalesce(r.Clause, '') <> 'parameter'
                                    THEN r.Raw_Name END) AS dyn_parts,
           string_agg(DISTINCT CASE WHEN r.Resolution = 'name' THEN r.Raw_Name END, ' · '
                      ORDER BY CASE WHEN r.Resolution = 'name' THEN r.Raw_Name END) AS names
    FROM CalculationSqlRefs r
    GROUP BY ALL
),
calc_sites_raw AS (
    SELECT f.Calculation_UUID, f.mechanism_id, CAST(NULL AS VARCHAR) AS target_hint, FALSE AS sql_missing, f.low_conf, CAST(NULL AS BIGINT) AS sql_index
    FROM calc_fn f
    UNION ALL
    SELECT q.Calculation_UUID, CASE WHEN q.is_dynamic THEN 'M31' ELSE 'M32' END,
           CASE WHEN q.is_dynamic THEN q.dyn_parts ELSE q.names END, q.name_missing AND NOT q.is_dynamic, q.low_conf, q.Sql_Index
    FROM sql_stmt q WHERE q.is_dynamic OR q.has_name
),
calc_sites AS (
    SELECT x.mechanism_id, coalesce(c.Formula_Text, c.Display_Text) AS expr, c.File_Name AS file_name,
           CASE WHEN c.Owner_Type = 'ScriptStep' THEN 'Script' ELSE c.Owner_Type END AS carrier_type,
           CASE WHEN c.Owner_Type = 'ScriptStep' THEN s.Script_UUID ELSE c.Owner_UUID END AS nav_uuid,
           CASE WHEN c.Owner_Type = 'ScriptStep' THEN 'Script' ELSE c.Owner_Type END AS nav_type,
           CASE WHEN c.Owner_Type = 'ScriptStep' THEN s.Script_Name
                WHEN c.Owner_Type = 'LayoutObject' THEN coalesce(lay.L_Name || ' › ', '') || c.Owner_Name
                ELSE c.Owner_Name END AS carrier_name,
           s.Step_Index, s.Step_UUID AS step_uuid, s.Step_ID,
           coalesce(c.Is_Enabled, TRUE) AND coalesce(s.Is_Enabled, TRUE) AS is_enabled,
           x.low_conf AS low_confidence,
           x.target_hint,
           x.sql_missing, x.sql_index
    FROM calc_sites_raw x
    JOIN CalculationsCatalog c ON c.Calculation_UUID = x.Calculation_UUID
    LEFT JOIN steps s ON c.Owner_Type = 'ScriptStep' AND s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    LEFT JOIN LayoutObjects lo ON c.Owner_Type = 'LayoutObject' AND lo.Object_UUID = c.Owner_UUID AND lo.File_Name = c.File_Name
    LEFT JOIN Layouts lay ON lay.L_ID = lo.Layout_ID AND lay.File_Name = lo.File_Name
),
all_sites AS (
    SELECT *, FALSE AS sql_missing, CAST(NULL AS BIGINT) AS sql_index FROM step_sites
    UNION ALL BY NAME
    SELECT * FROM calc_sites
),
-- Literal recognition: exactly one string literal (FileMaker escapes " as \").
lit AS (
    SELECT a.*,
           CASE WHEN a.expr IS NULL THEN NULL
                WHEN regexp_full_match(trim(a.expr), '"([^"\\]|\\.)*"')
                     THEN replace(replace(trim(a.expr)[2:-2], '\"', '"'), '\\', '\')
                WHEN a.mechanism_id = 'M11' AND regexp_full_match(trim(a.expr), '\d+') THEN trim(a.expr)
           END AS literal
    FROM all_sites a
),
-- Script literal: "<data source>::<script>" (cross-file, case-sensitive) or
-- "<script>" (same file, case-insensitive).
script_lit AS (
    SELECT l.*,
           CASE WHEN contains(l.literal, '::') THEN split_part(l.literal, '::', 1) END AS ds_name,
           CASE WHEN contains(l.literal, '::') THEN l.literal[strpos(l.literal, '::') + 2:] ELSE l.literal END AS script_part
    FROM lit l WHERE l.mechanism_id IN ('M01', 'M02') AND l.literal IS NOT NULL
),
script_target AS (
    SELECT sl.file_name, sl.step_uuid, sl.mechanism_id,
           min(sc.Script_UUID) AS target_uuid, min(sc.Script_Name) AS target_name,
           min(sc.File_Name) AS target_file, count(sc.Script_UUID) AS match_count,
           CASE WHEN bool_or(sl.ds_name IS NOT NULL AND d.DS_UUID IS NULL) THEN 'data_source_missing'
                WHEN bool_or(d.DS_UUID IS NOT NULL AND m.Resolved_File IS NULL) THEN 'file_not_imported'
           END AS target_note
    FROM script_lit sl
    LEFT JOIN ExternalDataSourceCatalog d ON sl.ds_name IS NOT NULL AND d.File_Name = sl.file_name AND d.DS_Name = sl.ds_name
    LEFT JOIN DataSourceFileMap m ON m.File_Name = d.File_Name AND m.DS_UUID = d.DS_UUID
    LEFT JOIN ScriptCatalog sc
      ON sc.File_Name = coalesce(m.Resolved_File, CASE WHEN sl.ds_name IS NULL THEN sl.file_name END)
     AND coalesce(sc.Folder_Type, '') = '' AND NOT coalesce(sc.Is_Separator, FALSE)
     AND CASE WHEN sl.ds_name IS NULL THEN lower(sc.Script_Name) = lower(sl.script_part)
              ELSE sc.Script_Name = sl.script_part END
    GROUP BY ALL
),
-- Layout literal: by name the first-created layout wins (smallest id); by
-- number the position among real layouts (folders and folder ends excluded).
layouts_real AS (
    SELECT File_Name, L_ID, L_Name, L_UUID,
           row_number() OVER (PARTITION BY File_Name ORDER BY Sequence_ID) AS layout_no
    FROM Layouts WHERE Folder_Type IS NULL
),
layout_target AS (
    SELECT l.file_name, l.step_uuid, l.mechanism_id,
           arg_min(lr.L_UUID, lr.L_ID) AS target_uuid, arg_min(lr.L_Name, lr.L_ID) AS target_name,
           count(lr.L_UUID) AS match_count
    FROM lit l
    LEFT JOIN layouts_real lr ON lr.File_Name = l.file_name
     AND CASE WHEN l.mechanism_id = 'M10' THEN lower(lr.L_Name) = lower(l.literal)
              ELSE lr.layout_no = TRY_CAST(l.literal AS BIGINT) END
    WHERE l.mechanism_id IN ('M10', 'M11') AND l.literal IS NOT NULL
    GROUP BY ALL
),
-- Layout-object literal: the step's layout context is not known statically —
-- a match is "an object of this name exists on some layout of the file".
-- A name missing in the step's own file but present in another imported file
-- (data and interface split over files) is not reported as missing: the
-- window the step acts on may show a layout of that file.
object_names AS (
    SELECT lower(o.Object_Name) AS name_l, list(DISTINCT o.File_Name ORDER BY o.File_Name) AS files
    FROM LayoutObjects o
    WHERE o.Object_Name <> ''
    GROUP BY lower(o.Object_Name)
),
object_target AS (
    SELECT l.file_name, l.step_uuid, l.mechanism_id,
           CASE WHEN count(o.Object_UUID) = 1 THEN min(o.Object_UUID) END AS target_uuid,
           CASE WHEN count(o.Object_UUID) = 1 THEN min(o.Object_Name)
                WHEN count(o.Object_UUID) = 0
                     THEN array_to_string(list_filter(any_value(onm.files), lambda f: f <> l.file_name), ', ')
           END AS target_name,
           count(o.Object_UUID) AS match_count,
           CASE WHEN count(o.Object_UUID) = 0
                 AND len(list_filter(any_value(onm.files), lambda f: f <> l.file_name)) > 0
                THEN 'other_file' END AS target_note
    FROM lit l
    LEFT JOIN LayoutObjects o ON o.File_Name = l.file_name AND o.Object_Name <> ''
     AND lower(o.Object_Name) = lower(l.literal)
    LEFT JOIN object_names onm ON onm.name_l = lower(l.literal)
    WHERE l.mechanism_id IN ('M40', 'M41') AND l.literal IS NOT NULL
    GROUP BY l.file_name, l.step_uuid, l.mechanism_id
),
targets AS (
    SELECT *, 'Script' AS target_type FROM script_target
    UNION ALL BY NAME SELECT *, 'Layout' AS target_type FROM layout_target
    UNION ALL BY NAME SELECT *, 'LayoutObject' AS target_type FROM object_target
),
-- Guard: the next step reads Get(LastError) — a tolerated, optional target.
guarded AS (
    SELECT DISTINCT s.Script_UUID, s.File_Name, s.Step_Index - 1 AS site_index
    FROM StepCalculations s
    WHERE regexp_matches(s.Calc_Text, 'Get\s*\(\s*LastError\s*\)', 'i')
),
sites AS (
    SELECT
        l.mechanism_id,
        CASE
            WHEN l.mechanism_id IN ('M01', 'M02') THEN 'script'
            WHEN l.mechanism_id IN ('M10', 'M11', 'M12', 'M50l') THEN 'layout'
            WHEN l.mechanism_id IN ('M20', 'M21', 'M50f') THEN 'field'
            WHEN l.mechanism_id = 'M50t' THEN 'table'
            WHEN l.mechanism_id IN ('M31', 'M32', 'M33') THEN 'sql'
            WHEN l.mechanism_id IN ('M40', 'M41', 'M42') THEN 'layout_object'
            WHEN l.mechanism_id = 'M50v' THEN 'value_list'
            WHEN l.mechanism_id = 'M30' THEN 'formula'
            WHEN l.mechanism_id = 'M60' THEN 'introspection'
            WHEN l.mechanism_id = 'M70' THEN 'window'
        END AS kind,
        l.file_name, l.carrier_type, l.carrier_name, l.nav_uuid, l.nav_type,
        CAST(l.Step_Index + 1 AS INTEGER) AS step_no, l.step_uuid, l.sql_index, l.Step_ID AS step_id, l.is_enabled,
        CASE WHEN l.expr IS NULL AND l.mechanism_id = 'M20' THEN '(active field)' ELSE l.expr END AS expression,
        CASE
            WHEN l.mechanism_id = 'M20' AND l.expr IS NULL THEN 'dynamic'
            WHEN l.expr IS NULL AND l.mechanism_id IN ('M01', 'M02', 'M10', 'M11') THEN 'empty'
            WHEN l.mechanism_id = 'M32' THEN CASE WHEN l.sql_missing THEN 'literal_unresolved' ELSE 'literal_resolved' END
            WHEN l.mechanism_id IN ('M30', 'M31', 'M60') THEN 'no_target'
            WHEN l.literal = '' THEN 'no_target'
            WHEN l.mechanism_id IN ('M01', 'M02', 'M10', 'M11', 'M40', 'M41') AND l.literal IS NOT NULL
                 THEN CASE WHEN t.match_count > 0 THEN 'literal_resolved'
                           WHEN t.target_note = 'file_not_imported' THEN 'literal_external'
                           WHEN t.target_note = 'other_file' THEN 'literal_other_file'
                           ELSE 'literal_unresolved' END
            WHEN l.mechanism_id IN ('M12', 'M33', 'M70') AND l.literal IS NOT NULL THEN 'no_target'
            WHEN l.mechanism_id LIKE 'M5%' OR l.mechanism_id IN ('M21', 'M42') THEN 'no_target'
            ELSE 'dynamic'
        END AS resolution_class,
        t.target_type, t.target_uuid, coalesce(t.target_name, l.target_hint) AS target_name, t.match_count,
        CASE WHEN t.match_count > 1 THEN 'ambiguous' ELSE t.target_note END AS target_note,
        (g.site_index IS NOT NULL) AS guarded,
        l.low_confidence OR l.mechanism_id = 'M11' AS low_confidence
    FROM lit l
    LEFT JOIN targets t ON t.step_uuid = l.step_uuid AND t.file_name = l.file_name AND t.mechanism_id = l.mechanism_id
    LEFT JOIN guarded g ON g.Script_UUID = l.nav_uuid AND g.File_Name = l.file_name AND g.site_index = l.Step_Index
),
-- English mechanism captions (the tables translate the codes via valueLabels).
mech_labels(mechanism_id, mechanism_label) AS (VALUES
    ('M01', 'Perform Script by name'),
    ('M02', 'Perform Script on Server by name'),
    ('M10', 'Layout by name (calculation)'),
    ('M11', 'Layout by number (calculation)'),
    ('M12', 'Execute FileMaker Data API'),
    ('M20', 'Set Field By Name'),
    ('M21', 'GetField()'),
    ('M30', 'Evaluate()'),
    ('M31', 'ExecuteSQL, statement built at run time'),
    ('M32', 'ExecuteSQL, names in the SQL text'),
    ('M33', 'Execute SQL, calculated SQL text'),
    ('M40', 'Go to Object by name'),
    ('M41', 'Object name of a script step'),
    ('M42', 'GetLayoutObjectAttribute()'),
    ('M50v', 'ValueListItems()'),
    ('M50f', 'Design function, field by name'),
    ('M50l', 'Design function, layout by name'),
    ('M50t', 'Design function, table by name'),
    ('M60', 'Design function, list of names'),
    ('M70', 'Window by name')
),
-- File filter, analysis scope (S-Block) and the disabled-steps switch.
base AS (
    SELECT s.*, ml.mechanism_label
    FROM sites s
    LEFT JOIN mech_labels ml ON ml.mechanism_id = s.mechanism_id
    WHERE (getvariable('file') IS NULL OR s.file_name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.nav_uuid IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
      AND (s.is_enabled
           OR coalesce(NULLIF(CAST(getvariable('disabled') AS VARCHAR), ''), 'hide') = 'include')
),
-- Lens predicates of the chip bars. "all" leaves out the two signal kinds
-- (introspection, window) — they have chips of their own.
lens AS (
    SELECT b.*,
           CASE WHEN coalesce(NULLIF(CAST(getvariable('kind') AS VARCHAR), ''), 'all') = 'all'
                     THEN b.kind NOT IN ('introspection', 'window')
                ELSE b.kind = CAST(getvariable('kind') AS VARCHAR) END AS in_kind,
           coalesce(NULLIF(CAST(getvariable('resolution') AS VARCHAR), ''), 'all') IN ('all', b.resolution_class) AS in_resolution,
           (NULLIF(CAST(getvariable('mechanism') AS VARCHAR), '') IS NULL
            OR b.mechanism_id = CAST(getvariable('mechanism') AS VARCHAR)) AS in_mechanism
    FROM base b
),
