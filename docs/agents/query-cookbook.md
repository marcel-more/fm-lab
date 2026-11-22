# Query Cookbook — SQL Patterns & DuckDB Idioms

> Referenced from CLAUDE.md §8. Canonical query patterns for the object catalog
> plus DuckDB-specific syntax hints. More prepared queries: `docs/agents/sql/sample_queries.sql`.

## DuckDB commands for this project

```bash
# Execute a query
duckdb -readonly db/fm_catalog.duckdb -c "SELECT * FROM ScriptCatalog"

# Execute a prepared query file
duckdb -readonly db/fm_catalog.duckdb < docs/agents/sql/sample_queries.sql
```

Reminder (rule from CLAUDE.md §2): one plain command per call — no subshells,
no `&&` chains, no `$DB` variables.

## DuckDB idioms worth using

When building complex SQL, research syntax with the `duckdb-skills:duckdb-docs` skill.
Particularly useful here:

- **DuckDB-specific syntax:** `GROUP BY ALL`, `ORDER BY ALL`, `SELECT * EXCLUDE(...)`, `SELECT * REPLACE(...)`, the `COLUMNS()` expression
- **Efficient aggregation:** `arg_max()` / `arg_min()` instead of complex window functions, `QUALIFY` instead of subqueries
- **String/list functions:** function chaining (`'text'.upper().replace(...)`), list comprehensions, slicing
- **Query structure:** `FROM`-first queries, `UNION BY NAME`, CTEs instead of repeated subqueries
- **XML access:** `xml_extract_text(Object_XML, '/xpath')[1]` for polymorphic attributes in LayoutObjects (requires `LOAD webbed;`)

## Basic object queries

**List all scripts (excluding folders/separators):**
```sql
SELECT Script_ID, Script_Name
FROM ScriptCatalog
WHERE (Folder_Type IS NULL OR Folder_Type = 'False')
  AND NOT Is_Separator
ORDER BY Script_Name;
```

**Fields of a table:**
```sql
SELECT Field_Name, Field_Type, Data_Type
FROM FieldsForTables
WHERE Table_Name = 'YourTableName'
ORDER BY Field_ID;
```

**Check object existence (across all object types):**
```sql
SELECT Object_Type, Object_Name, File_Name
FROM ObjectCatalog
WHERE Object_Name LIKE '%Import%'
ORDER BY Object_Type, File_Name;
```

## Where-used & dependencies

**Where is a field used?** (analogous for any object type)
```sql
SELECT
    ol.Source_Type,
    oc_source.Object_Name as Used_In,
    oc_source.File_Name as File,
    ol.Link_Role as Kind
FROM ObjectCatalog oc_field
JOIN ObjectLinks ol ON oc_field.Object_UUID = ol.Target_UUID
JOIN ObjectCatalog oc_source ON ol.Source_UUID = oc_source.Object_UUID
WHERE oc_field.Object_Type = 'Field'
  AND oc_field.Object_Name LIKE '%Email%'
  AND ol.Link_Type = 'operational'
ORDER BY ol.Source_Type, oc_source.Object_Name;
```

⚠️ For dead-code / "unused" analyses, exclude roles that don't count as usage —
authoritative flag: `LinkRoleRegistry.Counts_For_Where_Used` (e.g. `restricts_field`/
`restricts_object` are restrictions, not usages; `trigger_script` is the non-counting
granular twin of the `triggers_script·<event>` owner mirror since converter 2.17.0 —
counting both double-counts every script trigger). See `analysis-workflows.md`.

### Which step sets / calls / reads X? — `v_script_step_links`

`ObjectLinks` attributes a script's references to the **script**; the step is lost.
`v_script_step_links` (schema 1.41.0) projects the same edges onto the step, with the
same roles — query it for every "which step …" question instead of regexing
`Parameters_XML` / `Step_XML`.

**Which step writes field F?**
```sql
SELECT sl.File_Name, sc.Script_Name, sl.Step_Index + 1 AS Step_No, sl.Step_Name,
       sl.Link_Role, sl.Via, sl.Is_Enabled, f.Object_Name AS Field
FROM v_script_step_links sl
JOIN ObjectCatalog f  ON f.Object_UUID = sl.Target_UUID AND f.File_Name = sl.Target_File
JOIN ScriptCatalog sc ON sc.Script_UUID = sl.Script_UUID AND sc.File_Name = sl.File_Name
WHERE sl.Target_Type = 'Field'
  AND f.Object_Name = '<Table>::<Field>'
  AND sl.Link_Role IN ('sets_field', 'imports_to_field', 'inputs_to_field')
ORDER BY sl.File_Name, sc.Script_Name, sl.Step_Index;
```

- Other questions only swap the filter: callers of a script → `Link_Role = 'calls_script'`
  (`Link_Subrole` `on_server` / `on_server_callback`), navigation → `navigates_to_layout`,
  readers of a field → `reads_field` (with `Via = 'calculation'` for formula reads).
- `Via = 'parameter'`: the reference is the step's own target/option; `Via = 'calculation'`:
  it sits in one of the step's formulas (`Calculation_UUID` names it).
- Join a step on `(Step_UUID, File_Name)` — cloned files share step UUIDs.
- Variables are in the view since converter 2.50.0: `Target_Type = 'Variable'`,
  `Link_Role` `sets_variable` / `reads_variable` (`Via = 'parameter'` = the step's target
  variable, e.g. *Set Variable*; `Via = 'calculation'` = inside a formula — read, or set in a
  `Let` header, `Link_Subrole = 'let_assign'`). Which step sets `$$X`: filter `Target_Type =
  'Variable'`, `Link_Role = 'sets_variable'` and join `VariablesCatalog`/`ObjectCatalog` on
  the variable UUID (or match the name via `VariableUsages`). Script calls from formulas via
  `MBS("FM.RunScript")` are the one known gap (edge `Link_Subrole` `MBS:FM.RunScript` on the
  script only).

### Call sites with their condition — `v_script_step_links` + `v_step_guards`

Who calls script S, from which step, under which If / Else If / Else, in a loop? The step
view gives the call site, `v_step_guards` the enclosing branch, `v_script_block_tree` the
loop depth.

```sql
SELECT l.File_Name, bt.Script_Name AS Caller, l.Step_Index + 1 AS Step_No, l.Step_ID,
       l.Link_Subrole, l.Is_Enabled,
       g.Guard_Kind, g.Guard_Step_Index + 1 AS Guard_Step_No,
       c.Formula_Text AS Condition,
       bt.loop_depth_before > 0 AS In_Loop
FROM ObjectCatalog tgt
JOIN v_script_step_links l
  ON l.Target_UUID = tgt.Object_UUID AND l.Target_File = tgt.File_Name
 AND l.Link_Role = 'calls_script'
JOIN v_script_block_tree bt
  ON bt.Step_UUID = l.Step_UUID AND bt.File_Name = l.File_Name
LEFT JOIN v_step_guards g
  ON g.Step_UUID = l.Step_UUID AND g.File_Name = l.File_Name
 AND g.Guard_Kind IN ('if', 'elseif', 'else')
LEFT JOIN CalculationsCatalog c
  ON c.Calculation_UUID = g.Guard_Calculation_UUID AND c.File_Name = g.File_Name
WHERE tgt.Object_Type = 'Script' AND tgt.Object_Name = '<Script>'
QUALIFY row_number() OVER (PARTITION BY l.Step_UUID, l.File_Name
                           ORDER BY g.Guard_Level DESC NULLS LAST) = 1  -- innermost branch
ORDER BY l.File_Name, Caller, l.Step_Index;
```

- `Guard_Level` 1 = outermost; the `QUALIFY` keeps the innermost branch. Drop it (and add
  `g.Guard_Level` to the select list) to see every enclosing branch. `Guard_Kind = 'else'`
  has no formula — the condition is "all earlier branches of the chain are false"
  (`Chain_Open_Index` names the chain's If). `Condition` NULL with `Guard_Kind` NULL = the call
  runs unconditionally within its script.
- `Is_Enabled = false`: the call step is disabled and never runs. `v_step_guards` has no row
  for it, so filter `l.Is_Enabled` when the question is about what actually runs.
- Other step kinds swap the role: the step that enters layout L (and fires its
  `OnLayoutEnter` cascade) → `Link_Role = 'navigates_to_layout'`, `Target_Type = 'Layout'`.
  `v_step_guards` covers every enabled call and navigation step since converter 2.51.3.
- Not in the view: calls without a static callee (by name — `v_script_block_tree` with
  `Step_ID IN (1, 164, 210)` and no `calls_script` row) and `MBS("FM.RunScript")` calls (edge
  only). Unreachable call sites after *Exit Script* / *Halt Script*: rule
  `dead_code_after_exit`.
- Parameter of the call: `StepCalculations` with `Step_ID IN (1, 164, 210)` and
  `Slot = 'Parameter:'`; which later step reads the result: `v_dataflow_edges`
  `Flow_Kind = 'result_to_step'` with `Pair_Step_UUID` = the call step.
- The flow trace returns the same per edge for a whole chain (`GET /api/graph/trace?mode=flow`
  → `edges[].callSites[]`, ways with the conditions on the path; `/fm-trace` prints them).

### Where does the value of field F come from? — `v_dataflow_edges`

The dataflow view (schema 1.43.0) follows the value, not the object edge: which steps,
formulas, entries write the field, and how those steps are started. Level 1 = direct writers
with their triggers (the whole chain over variables, parameters and callers is the data trace
endpoint's job). `Writer_Kind = 'reset'` (only `""` written) is no origin; an auto-enter
option without formula (serial number, creation/modification value, constant data) appears as
`entry_auto_enter` with the option in `Link_Subrole`; the table exists in every catalog
from schema 1.43.0 on (absent only after a failed dataflow phase — re-import).

```sql
WITH f AS (SELECT Object_UUID, File_Name FROM ObjectCatalog
           WHERE Object_Type = 'Field' AND Object_Name = 'MyTable::MyField'),
w AS (SELECT e.* FROM v_dataflow_edges e JOIN f ON e.To_UUID = f.Object_UUID AND e.To_File = f.File_Name
      WHERE e.Flow_Class IN ('data', 'entry') AND COALESCE(e.Writer_Kind, '') <> 'reset'
        AND COALESCE(e.Is_Enabled, TRUE))
SELECT w.Flow_Kind, w.Writer_Kind, sc.Object_Name AS Script, w.Step_Index + 1 AS Step_No,
       count(t.From_UUID) AS Entries,
       string_agg(DISTINCT t.From_Kind || ':' || coalesce(t.Link_Subrole, ''), ', ') AS Entry_Kinds
FROM w
LEFT JOIN ObjectCatalog sc ON sc.Object_UUID = w.Script_UUID AND sc.File_Name = w.File_Name
LEFT JOIN v_dataflow_edges t ON t.Flow_Kind = 'triggers_script'
                            AND t.To_UUID = w.Script_UUID AND t.To_File = w.File_Name
GROUP BY ALL ORDER BY Entries DESC;
```

- One level further: the data edges INTO a writing step (`To_Kind = 'ScriptStep' AND To_UUID =
  <Step_UUID>`, `Flow_Class = 'data'`) — fields, `local_def_use` setters, global variables,
  `param_to_step`, `result_to_step`.
- Where the value goes (usage): start at `From_UUID = <field>` and follow `Flow_Class = 'data'`;
  `sink` rows are counters (display, sort, export, relationship, value list).

**Where does an import take its data from?** (`ImportStepSources`, one row per
*Import Records* step; target fields stay `imports_to_field` rows)
```sql
SELECT i.File_Name, sc.Script_Name, i.Step_Index + 1 AS Step_No, i.Source_Kind,
       coalesce(i.Source_File, i.Source_Location, i.Source_Formula) AS Source,
       count(DISTINCT sl.Target_UUID) AS Target_Fields
FROM ImportStepSources i
JOIN ScriptCatalog sc ON sc.Script_UUID = i.Script_UUID AND sc.File_Name = i.File_Name
LEFT JOIN v_script_step_links sl ON sl.Step_UUID = i.Step_UUID AND sl.File_Name = i.File_Name
                                AND sl.Link_Role = 'imports_to_field'
GROUP BY ALL
ORDER BY 1, 2, 3;
```
`Source_File` is set only for FileMaker sources that resolve to a file **of the solution**
(the cross-file data path); `$variable` paths and outside files stay NULL.

**Where is field F (or TO T) used in SQL?** (`CalculationSqlRefs`, schema ≥ 1.42.0 — one
row per table, column and parameter of an `ExecuteSQL`/`ExecuteSQLe` statement; never regex
`Formula_Text` for SQL)
```sql
SELECT r.File_Name, c.Owner_Type,
       coalesce(s.Script_Name, c.Owner_Name) AS Object, s.Step_Index + 1 AS Step_No,
       r.Clause, r.Column_Pos, r.Resolution, r.Raw_Name
FROM CalculationSqlRefs r
JOIN CalculationsCatalog c ON c.Calculation_UUID = r.Calculation_UUID AND c.File_Name = r.File_Name
JOIN FieldsForTables f     ON f.Field_UUID = r.Target_UUID AND f.File_Name = r.Target_File
LEFT JOIN StepsForScripts s ON c.Owner_Type = 'ScriptStep'
                           AND s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
WHERE r.Target_Type = 'Field' AND f.Field_Name = 'MyField'
ORDER BY 1, 3, 4;
```
- TO instead of field: `r.Target_Type = 'TableOccurrence'` and join `TableOccurrenceCatalog`
  on `(Target_UUID, Target_File)` — the rows of `FROM`/`JOIN`.
- `Resolution = 'name'`: the name is plain text in the SQL — **a rename breaks the query
  silently** (FileMaker does not track it). `reference`: built from a field reference
  (`GetFieldName`, a name wrapper), safe on rename.
- Broken references: `Target_Type IS NULL AND NOT Low_Confidence AND Clause <> 'parameter'`
  (missing TO or field, `<Field Missing>`). Both checks are the Analysis Test
  `sql-reference-integrity` (`/fm-test sql-reference-integrity`).
- `Clause = 'parameter'` rows bind the k-th argument (`Arg_Pos`) to the k-th `?`;
  `Let_Var` names the Let variable the SQL text came from. Statements whose text comes
  from another step are one `dynamic` row without clause.
- The field links themselves are ordinary `reads_field` edges (also for plain names), so
  where-used and `v_object_usage` already include them — this table adds clause and origin.

### Where-used for Table Occurrences

The generic pattern above is **not enough for a TO**. A `TO::Field` reference — in a
formula, a script step, a field on a layout — creates an edge to the *field*, never to the
TO. `ObjectLinks` alone therefore shows only layout contexts, portals, relationships,
GTRR/navigation, lookups and value-list sources, and a TO that is read in hundreds of
formulas looks almost unused. Read `v_table_occurrence_usage` (schema ≥ 1.38.0): one row
per (TO, using object, category, role), edges included (`Is_Edge = true`).

```sql
-- Where is TO X used? — grouped by category (scope by file: TO names repeat across files)
SELECT u.Category, u.User_Type,
       count(DISTINCT u.User_UUID)    AS Users,
       CAST(sum(u.Ref_Count) AS BIGINT) AS Refs,
       bool_or(u.Is_Edge)             AS Via_Edge
FROM ObjectCatalog o
JOIN v_table_occurrence_usage u
  ON u.TO_UUID = o.Object_UUID AND u.File_Name = o.File_Name
WHERE o.Object_Type = 'TableOccurrence'
  AND o.Object_Name = 'Invoices' AND o.File_Name = 'Sales'
GROUP BY ALL
ORDER BY Refs DESC;

-- The single usages of one category (LayoutObject users carry their layout as container)
SELECT u.User_Type,
       coalesce(u.Container_Name || ' / ', '') || u.User_Name AS Used_In,
       u.User_File, u.Role, u.Ref_Count
FROM v_table_occurrence_usage u
WHERE u.TO_Name = 'Invoices' AND u.File_Name = 'Sales'
  AND u.Category = 'script_step'          -- e.g. calculation, layout_field, calc_context
ORDER BY u.User_Name, u.Role;

-- "Can I delete it?" — usage class per TO from count + relationship-path analysis
SELECT c.File_Name, c.TO_Name, c.Usage_Class, c.Reason,
       c.Usage_Ref_Count, c.Relationship_Count,
       c.Dead_Group_Size, c.Anchor_TO_Name, c.Low_Confidence
FROM v_table_occurrence_class c
WHERE c.Usage_Class IN ('unused', 'dead_branch', 'dead_island')
ORDER BY c.File_Name, c.Dead_Group_ID, c.TO_Name;
```

⚠️ Reading the result:
- **Formula references need DDR info.** In files without it the category
  `calculation_text` stands in: `TO::Field` found in the formula text (about 95 % of the
  pairs, false hits count as usage; unqualified field names and evaluation contexts stay
  invisible). `v_table_occurrence_class.Low_Confidence = true` marks those files — there
  `unused`/`dead_*` are **unverified**; `used`/`relationship_bridge` rest on found usages
  and hold.
- **`relationship_bridge` is not a finding.** A TO without own usage that sits on the
  relationship path between two used TOs (the join TO of an n:m relationship) or on a
  relationship with cascade delete is needed. `dead_*` means "no statically visible path"
  — a review candidate, not a delete recommendation; `Dead_Group_ID` groups a dead
  subtree that is cleaned up together.
- **Dynamic references are invisible** (`GetField`, `Evaluate`, SQL text assembled in
  another step). TO names in `ExecuteSQL` statements count since schema 1.42.0 —
  category `sql`, also as a plain name in the SQL text.
- Don't add `ObjectLinks` rows on top of the table — the edges are already in it
  (`Is_Edge`). Sum `Ref_Count` instead of counting rows when the question is "how often".
- **"Can I delete TO X?" / "which TOs are dead?" is a test run:** `/fm-test unused-code`
  (profile `data-model`) — in object scope on the TO it returns its finding with class,
  dead group and anchor, or none; also file, object-list and cluster scope. Other views:
  dashboard `schema/table_occurrence_usage`, references tab of the TO in the web frontend.
  Column details: `schema-reference.md` → `v_table_occurrence_usage` /
  `v_table_occurrence_class`.

### Usage counts for any object type

"Is X used / unused / rarely used?" and "rank objects by usage" read `v_object_usage`
(schema 1.40.0) — one row per Field, Script, Layout, CustomFunction, ValueList,
BaseTable, ExternalDataSource, PrivilegeSet, TableOccurrence, Relationship. It is the
definition the `unused_*` rules use, so a hand-written `NOT EXISTS` over `ObjectLinks`
can only drift from it. Calls by name (`Perform Script` by name, `Go to Layout` by
calculation, …) are invisible to it — see § Objects addressed by name (indirections)
before reporting a script or layout as unused.

```sql
-- Rarely used custom functions (1–2 using containers), with the roles behind the count
SELECT File_Name, Object_Name, Usage_Owners, Usage_Refs, Usage_Roles, Usage_Files
FROM v_object_usage
WHERE Object_Type = 'CustomFunction' AND Usage_Owners BETWEEN 1 AND 2
ORDER BY Usage_Owners, File_Name, Object_Name;

-- Unused objects per type and file (= the findings of the test unused-code, TO aside)
SELECT Object_Type, File_Name, count(*) AS n,
       count(*) FILTER (WHERE Low_Confidence) AS unverified
FROM v_object_usage
WHERE Usage_Class = 'unused'
GROUP BY ALL
ORDER BY Object_Type, n DESC;

-- Who uses it? — the edges behind the count (Usage_Refs = these rows)
SELECT ol.Link_Role, src.Object_Type, src.Object_Name, ol.Source_File
FROM v_object_usage u
JOIN ObjectLinks ol ON ol.Target_UUID = u.Object_UUID AND ol.Target_File = u.File_Name
JOIN LinkRoleRegistry r ON r.Link_Role = ol.Link_Role AND r.Counts_For_Where_Used
JOIN ObjectCatalog src ON src.Object_UUID = ol.Source_UUID AND src.File_Name = ol.Source_File
WHERE u.Object_Type = 'ValueList' AND u.Object_Name = 'Status' AND u.File_Name = 'Sales'
  -- for a Field: drop the aggregate Layout → Field edge (twin of the layout-object edges)
  AND NOT (ol.Source_Type = 'Layout' AND ol.Link_Role = 'displays_field' AND ol.Link_Subrole IS NULL)
ORDER BY ol.Link_Role, src.Object_Name;
```

⚠️ Reading the result:
- **`Usage_Owners` is the number to show.** A layout object counts as its layout, so a
  field placed 40 times on one layout is one owner; `Usage_Refs` counts edges (the
  aggregate Layout → Field edge excluded — every placement has a layout-object edge).
  Base tables: count `base_table` only, never `parent_table` (their own fields).
- **Not every zero is a finding.** `entry_point` (script/layout in a menu) and `builtin`
  (privilege sets 1–3) have no usage but are no delete candidates; TableOccurrence adds
  `relationship_bridge` (needed) and `dead_*` (findings); Relationship rows have no counts.
- **`Low_Confidence`** = file without DDR info: formula references are missing there, an
  `unused` is unverified.
- The "who uses it" query above applies the registry flag only — for BaseTable keep
  `Link_Role = 'base_table'`, for a TO use § Where-used for Table Occurrences.

**Which fields does a script set/read?** (forward direction — the reverse of where-used)
```sql
-- sets_field = written, reads_field = read. These are Script→Field edges,
-- resolved at import — do NOT regex Step_XML for this.
SELECT
    oc_target.File_Name as File,
    oc_target.Object_Name as Field,
    ol.Link_Role,
    count(*) as n
FROM ObjectLinks ol
JOIN ObjectCatalog oc_source ON ol.Source_UUID = oc_source.Object_UUID
JOIN ObjectCatalog oc_target ON ol.Target_UUID = oc_target.Object_UUID
WHERE oc_source.Object_Type = 'Script'
  AND oc_source.Object_Name = 'MyScript'
  AND ol.Link_Role IN ('sets_field', 'reads_field')
GROUP BY ALL
ORDER BY ol.Link_Role, oc_target.Object_Name;
```

⚠️ These `Script→Field` links are resolved at **script granularity**, carrying a count
`n` — not the step number nor the concrete written value. For the exact step or value use
the structured step columns (`StepsForScripts.Calculation_Text`, `DDR_ScriptSteps`) when
DDR-Info is present; regex on `Step_XML` is the last resort for files without DDR-Info.
The same forward pattern works for any resolved edge (`calls_script`, `navigates_to_layout`,
`sets_variable`, …) — swap the role. `fm-summarize <script>` returns this grouped for free.

**All calculations of an owner / calculations matching a criterion** (schema 1.22.0):
```sql
-- Slot inventory of one object (field, step, layout object, …)
SELECT Calc_Role, Calc_Index, Source_Path, Is_Static,
       left(COALESCE(Formula_Text, Display_Text), 100) AS Formula
FROM CalculationsCatalog
WHERE Owner_UUID = '<UUID>' AND File_Name = '<FILE>'
ORDER BY Calc_Role, Calc_Index;

-- Corpus-wide: e.g. all hide conditions calling a specific function —
-- one catalog query instead of five type-specific joins
SELECT c.Owner_Type, c.Owner_Name, c.Calc_Role, c.File_Name
FROM CalculationsCatalog c
JOIN v_calculation_links vl ON vl.Calculation_UUID = c.Calculation_UUID
JOIN ObjectCatalog tgt ON tgt.Object_UUID = vl.Target_UUID
WHERE c.Calc_Role = 'hide'
  AND tgt.Object_Type = 'BuiltinFunction' AND tgt.Object_Name = 'Get(AccountName)';
```
⚠️ `has_calculation` is containment (`Counts_For_Where_Used = false`) and
`v_calculation_links` is a **derived** per-slot resolution — where-used/dead-code
still runs on the owner-projected edges, never on this layer.

**Cross-file dependencies:**
```sql
SELECT
    oc_source.File_Name as From_File,
    oc_source.Object_Type as Type,
    oc_source.Object_Name as Object,
    oc_target.File_Name as To_File,
    oc_target.Object_Name as Target_Object,
    ol.Link_Role
FROM ObjectLinks ol
JOIN ObjectCatalog oc_source ON ol.Source_UUID = oc_source.Object_UUID
JOIN ObjectCatalog oc_target ON ol.Target_UUID = oc_target.Object_UUID
WHERE ol.Is_Cross_File = TRUE
ORDER BY oc_source.File_Name, oc_source.Object_Type;
```

### Objects addressed by name (indirections)

`Perform Script` by name, `Go to Layout` by name/number, `Set Field By Name`,
`Go to Object` by name, `Evaluate`, `GetField`, `ExecuteSQL` with names in the SQL
text … carry **no** edge — `ObjectLinks`, `v_object_usage` and the `unused_*` rules
cannot see them, a string literal included. Before calling an object unused, or
when renaming one, check this inventory too.

The full population (one row per site: mechanism, carrier, expression, resolution
class, presumed target for a literal) is the shared core of the dashboard
`modularization/indirections` —
`rest-api/templates/dashboards/modularization/indirections/data/shared/sites.sql`
(a CTE fragment; it reads `ref.function_name_lookup`, so attach
`reference/fm_spec.duckdb AS ref` when running it in the CLI). Through the API:
`GET /api/dashboards/indirections/data?kind=script&q=<name>` → dataset `findings`.

The most frequent single question needs no fragment:

```sql
-- Is script X called by name? (slot List = the by-name formula; FileMaker's
-- by-name form for another file is "<data source>::<script>")
SELECT c.File_Name, c.Script_Name AS caller, c.Step_Index + 1 AS step, c.Calc_Text
FROM StepCalculations c
WHERE c.Step_ID IN (1, 164, 210)   -- Perform Script, … on Server, … with Callback
  AND c.Slot = 'List'
  AND contains(lower(c.Calc_Text), lower('MyScript'));
```

⚠️ The mode of `Go to Layout` / `Go to List of Records` (3 = name, 4 = number by
calculation) lives only in `StepsForScripts.Parameters_XML`
(`<Parameter type="LayoutReferenceContainer"><LayoutReferenceContainer value="…">`);
`StepCalculations` carries the formula in slot `LayoutReferenceContainer` with the
same position for both modes. Without DDR info, formula functions have no
`calls_function` edge — the dashboard matches them in `Formula_Text` and marks them
low confidence.

## Layout queries

**All objects of a layout, with nesting depth:**
```sql
SELECT Object_Type, COUNT(*) as Count, MAX(Nesting_Level) as Max_Depth
FROM LayoutObjects
WHERE Layout_ID = 1065088
GROUP BY Object_Type
ORDER BY Count DESC;
```

**Nested objects (e.g. inside portals):**
```sql
SELECT
    parent.Object_Type as Parent_Type,
    child.Object_Type as Child_Type,
    child.Bounds_Top,
    child.Bounds_Left
FROM LayoutObjects child
JOIN LayoutObjects parent ON child.Parent_Object_ID = parent.Object_ID
WHERE child.Layout_ID = 1065088
ORDER BY parent.Object_ID, child.Object_ID;
```

**Objects together with layout names:**
```sql
SELECT l.L_Name, o.Object_Type, COUNT(*) as Object_Count
FROM LayoutObjects o
JOIN Layouts l ON o.Layout_ID = l.L_ID
GROUP BY l.L_Name, o.Object_Type
ORDER BY l.L_Name, Object_Count DESC;
```

**Which fields are displayed on a layout?**
```sql
SELECT DISTINCT
    oc_field.Object_Name as Field_Name,
    oc_field.File_Name as Field_File,
    ol2.Is_Cross_File as Cross_File
FROM ObjectCatalog oc_layout
JOIN ObjectLinks ol1 ON oc_layout.Object_UUID = ol1.Target_UUID
    AND ol1.Source_Type = 'LayoutObject'
    AND ol1.Link_Role = 'parent_layout'
JOIN ObjectLinks ol2 ON ol1.Source_UUID = ol2.Source_UUID
    AND ol2.Target_Type = 'Field'
    AND ol2.Link_Role = 'displays_field'
JOIN ObjectCatalog oc_field ON ol2.Target_UUID = oc_field.Object_UUID
WHERE oc_layout.Object_Type = 'Layout'
  AND oc_layout.Object_Name = 'YourLayoutName'
ORDER BY oc_field.Object_Name;
```

### Which font does an object show / where is font F used? — `v_layout_object_font`

Fonts are CSS (theme + local) plus rich-text runs and chart elements; the cascade is
resolved at import (schema 1.44.0). Never regex `Object_XML` / `Theme_XML` for fonts.
`Family_Source` = `local` · `local_redundant` (local, but the inherited family — e.g.
written by "bold", no deliberate choice) · `style` · `part_theme` (rank assumed →
`Low_Confidence`) · `theme` · `group` (`field` rule) · `default` (theme declares no
family — Classic, Minimalist: a per-file default that is NOT in the export, so
`Font_Family` is NULL; never name a font for it). Group by `Font_Key`, not by
`Font_Family` (same family appears as `arial` and `Arial`).

```sql
-- Fonts per layout (base font of every text-bearing object)
SELECT File_Name, Layout_Name, coalesce(Font_Family, '(file default)') AS font,
       Family_Source, count(*) AS objects
FROM v_layout_object_font
GROUP BY ALL
ORDER BY File_Name, Layout_Name, objects DESC;

-- Where is a font used — base font, rich-text runs and chart text areas
SELECT 'base' AS kind, File_Name, Layout_Name, Object_Type, Object_Name, Family_Source AS source
FROM v_layout_object_font WHERE Font_Key = 'courier new'
UNION ALL
SELECT r.Source, r.File_Name, l.L_Name, r.Object_Type, lo.Object_Name, coalesce(r.Slot, 'run')
FROM LayoutObjectFontRuns r
JOIN Layouts l        ON l.L_ID = r.Layout_ID AND l.File_Name = r.File_Name
JOIN LayoutObjects lo ON lo.Object_UUID = r.Object_UUID AND lo.File_Name = r.File_Name
WHERE lower(r.Font_Family) = 'courier new';
```

Rich-text runs are always partial (FileMaker stores a whole-text format as local CSS):
`Rich_Font_Families` adds to the base font, never replaces it. `CF_Font_Families` = font of
an enabled conditional-formatting rule with the font bit. Charts are not in the view —
their fonts are per text area in `LayoutObjectFontRuns` (`Source = 'chart'`).

### Which styles are used / where is style S applied? — `v_layout_object_style`

One row per layout object of every type (also shapes, lines, groups; also objects
without a style — `Style_Name` NULL), resolved to the layout's theme (schema 1.45.0).
Style usage is a grouping of this view; only **used** styles exist — the full style
list of a theme is not imported. `Style_Name` is the class (`FM-<UUID>` for a custom
style), `Style_Display` the Inspector name at export time (in the theme's language);
group by `Style_Name`, show `Style_Display`. `Style_Rule_Missing` = the layout's theme
has no rule for the style (left behind by a theme change). Never regex `Object_XML`
for `LocalCSS`.

```sql
-- Styles per theme: how many layouts and objects use each
SELECT File_Name, coalesce(Theme_Display, Theme_Name, '(no theme)') AS theme,
       coalesce(Style_Display, Style_Name) AS style, Style_Is_Custom,
       count(DISTINCT Layout_UUID) AS layouts, count(*) AS objects
FROM v_layout_object_style
WHERE Style_Name IS NOT NULL
GROUP BY ALL
ORDER BY File_Name, theme, objects DESC;

-- Styles of one layout, incl. objects without a style, with the object types per style
SELECT coalesce(Style_Display, Style_Name, '(default, no style)') AS style,
       Style_Is_Custom, Style_Rule_Missing,
       string_agg(DISTINCT Object_Type, ', ' ORDER BY Object_Type) AS object_types,
       count(*) AS objects
FROM v_layout_object_style
WHERE Layout_Name = 'YourLayoutName'
GROUP BY Style_Name, Style_Display, Style_Is_Custom, Style_Rule_Missing
ORDER BY Style_Name IS NULL DESC, objects DESC;

-- Styles without a rule in the layout's theme
SELECT File_Name, Layout_Name, Object_Type, Style_Name, Style_Display
FROM v_layout_object_style
WHERE Style_Rule_Missing
ORDER BY ALL;
```

The font a style produces is in `v_layout_object_font` (`Family_Source = 'style'`, text
objects only); the CSS a style declares is in `ThemeStyleRules` (`Style_Class = Style_Name`).

### Which custom styles does a theme have and which are unused? — `ThemeNamedStyles`

`v_layout_object_style` knows only **applied** styles. Every style a theme defines —
used or not, with its Inspector name — is in `ThemeNamedStyles` (schema 1.46.0;
`Is_Custom` = `FM-<UUID>` class). Count usage per file of the theme (a theme cloned
into several files has its own usage per file); the object type comes from the
`Type_Token`s of the style's rules in `ThemeStyleRules` (one style can have several).

```sql
-- Custom styles of one theme with object type tokens and usage (0 = unused)
WITH usage AS (
    SELECT File_Name, Theme_UUID, Style_Name,
           count(*) AS objects, count(DISTINCT Layout_UUID) AS layouts
    FROM v_layout_object_style
    WHERE Style_Name IS NOT NULL
    GROUP BY ALL
),
tokens AS (
    SELECT File_Name, Theme_UUID, Style_Class,
           string_agg(DISTINCT Type_Token, ', ' ORDER BY Type_Token) AS type_tokens
    FROM ThemeStyleRules
    WHERE Style_Class IS NOT NULL
    GROUP BY ALL
)
SELECT n.Style_Display, t.type_tokens,
       coalesce(u.objects, 0) AS objects, coalesce(u.layouts, 0) AS layouts
FROM ThemeNamedStyles n
JOIN ThemeCatalog tc ON tc.Theme_UUID = n.Theme_UUID AND tc.File_Name = n.File_Name
LEFT JOIN tokens t ON t.File_Name = n.File_Name AND t.Theme_UUID = n.Theme_UUID
                  AND t.Style_Class = n.Style_Class
LEFT JOIN usage u  ON u.File_Name = n.File_Name AND u.Theme_UUID = n.Theme_UUID
                  AND u.Style_Name = n.Style_Class
WHERE tc.Theme_Display = 'YourThemeName'
  AND n.Is_Custom
ORDER BY objects = 0, n.Style_Display;

-- Unused custom styles across the solution, per theme and file
SELECT n.File_Name, tc.Theme_Display, count(*) AS unused_custom_styles
FROM ThemeNamedStyles n
JOIN ThemeCatalog tc ON tc.Theme_UUID = n.Theme_UUID AND tc.File_Name = n.File_Name
WHERE n.Is_Custom
  AND NOT EXISTS (SELECT 1 FROM v_layout_object_style s
                  WHERE s.File_Name = n.File_Name AND s.Theme_UUID = n.Theme_UUID
                    AND s.Style_Name = n.Style_Class)
GROUP BY ALL
ORDER BY unused_custom_styles DESC;
```

Themes without `namedstyles` (Classic, Minimalist) return no rows. Theme header
(custom vs. built-in, base theme, default theme of the file) → `ThemeCatalog`
`Theme_Group`, `Base_Name`, `Is_Default`.

## Statistics

**Object count per type and file:**
```sql
SELECT Object_Type, File_Name, COUNT(*) as Count
FROM ObjectCatalog
GROUP BY Object_Type, File_Name
ORDER BY Object_Type, File_Name;
```

## Change metadata (last modified)

`ObjectChangeMeta` holds one row per object with its own `<UUID>` stamp (typed
`Modified_At`, `Modified_By`, `Modified_Account`, `Modifications`, `Author_Key`,
`Author_Kind`, `Burst_ID`, `Bulk_Event_ID`); `ChangeBulkEvents` the mass events,
`CatalogChangeMeta` the catalog-level stamps. Semantics and pitfalls →
`schema-reference.md`. Three rules for every change question:

- The stamp is the **last** save only — distributions show last changes, not activity.
- Anchor time windows at the **data state** (newest stamp), never at `now()` —
  an export is weeks or months old.
- **Mass actions dominate** real solutions (thousands of objects of one file in
  the same minute: migrations, find & replace, pastes). Individual changes are
  `Bulk_Event_ID IS NULL`, developer activity additionally `Author_Kind IS NULL`;
  mark the events (`ChangeBulkEvents`) instead of silently dropping them.
  `v_check_change_meta.bulk_pct` tells how much is at stake.

**Recent changes, anchored at the data state** (newest individual change):
```sql
WITH anchor AS (SELECT max(Modified_At) AS a FROM ObjectChangeMeta WHERE Bulk_Event_ID IS NULL)
SELECT m.Modified_At, m.Object_Type, m.Object_Name, m.File_Name, m.Modified_By
FROM ObjectChangeMeta m, anchor
WHERE m.Modified_At > anchor.a - INTERVAL 30 DAY
  AND m.Bulk_Event_ID IS NULL
  AND m.Author_Kind IS NULL
ORDER BY m.Modified_At DESC;
```

**Activity per day without mass events** — `changes` counts objects, `actions`
counts bursts (a quick series of saves counts once):
```sql
SELECT CAST(Modified_At AS DATE) AS day,
       count(*) AS changes,
       count(DISTINCT Burst_ID) AS actions,
       count(DISTINCT Author_Key) AS authors
FROM ObjectChangeMeta
WHERE Bulk_Event_ID IS NULL
  AND Author_Kind IS NULL
GROUP BY ALL
ORDER BY day DESC;
```

**Mass events — the solution's timeline** (migrations, pastes, tool runs):
```sql
SELECT Start_At, End_At, Scope, Kind, Files, Objects, Object_Types, Authors
FROM ChangeBulkEvents
ORDER BY Start_At;
```
`Kind = 'paste_import'` = pasted or imported objects (counter 1), `tool` = the
Data Migration Tool, `mass_action` = the rest. To list the objects of an event,
join `ObjectChangeMeta` on `Bulk_Event_ID` in the same query — the ID is
renumbered on every import.

**Authors** — group on `Author_Key` (case-folded user name); the account is
stored as typed at login (`Admin` / `admin`), user names vary in case:
```sql
SELECT Author_Key, any_value(Author_Kind) AS author_kind, any_value(Modified_By) AS spelling,
       count(*) AS objects, count(*) FILTER (WHERE Bulk_Event_ID IS NULL) AS individual,
       count(DISTINCT Modified_Account) AS accounts, max(Modified_At) AS last_change
FROM ObjectChangeMeta
GROUP BY ALL
ORDER BY objects DESC;
```
Spelling variants of one person (`Jane Doe` / `Jane Q. Doe`) stay separate keys
in the catalog; the REST API merges them via curated aliases
(`v_change_meta_authors.Person_Key`, API connection only).
Accounts and authorizations are also stamped by **runtime** changes (a user's
password change; WebDirect sessions are `Author_Kind = 'runtime'`) — exclude
`Object_Type IN ('Account', 'Authorization')` from developer-activity questions.

**Effective stamp of any object** — own stamp, else the container's (script
steps, layout objects/parts, calculations, script triggers and menu items carry
none; at most two hops, e.g. Calculation → ScriptStep → Script). Present a
`container` result as "container changed", not as a change of the object:
```sql
WITH RECURSIVE up(uuid, file, hop) AS (
    SELECT '<Object_UUID>', '<File>', 0
    UNION ALL
    SELECT CASE WHEN l.Link_Role = 'has_calculation' THEN l.Source_UUID ELSE l.Target_UUID END,
           CASE WHEN l.Link_Role = 'has_calculation' THEN l.Source_File ELSE l.Target_File END,
           up.hop + 1
    FROM up
    JOIN ObjectLinks l
      ON (l.Link_Role IN ('parent_script', 'parent_layout', 'parent_menu', 'trigger_owner')
          AND l.Source_UUID = up.uuid AND l.Source_File = up.file)
      OR (l.Link_Role = 'has_calculation'
          AND l.Target_UUID = up.uuid AND l.Target_File = up.file)
    WHERE up.hop < 2
      AND NOT EXISTS (SELECT 1 FROM ObjectChangeMeta m
                      WHERE m.Object_UUID = up.uuid AND m.File_Name = up.file)
)
SELECT CASE WHEN up.hop = 0 THEN 'own' ELSE 'container' END AS Meta_Source,
       m.Object_Type, m.Object_Name, m.Modified_At, m.Modified_By, m.Modifications
FROM up
JOIN ObjectChangeMeta m ON m.Object_UUID = up.uuid AND m.File_Name = up.file
ORDER BY up.hop
LIMIT 1;
```
Never inherit along `parent_folder`, `contains_menu` or `groups_into` — a folder's
or menu set's stamp says nothing about its content.

**Most-changed objects** (save counter = churn):
```sql
SELECT Object_Type, Object_Name, File_Name, Modifications, Modified_At
FROM ObjectChangeMeta
WHERE Object_Type NOT IN ('Account', 'Authorization')
ORDER BY Modifications DESC
LIMIT 20;
```

**Field deleted after the last field edit** — the only reliable deletion
indicator among the catalog stamps (compare with a tolerance: catalog stamps
trail their newest child by seconds):
```sql
SELECT c.File_Name, b.BT_Name AS Base_Table, c.Modified_At, c.Newest_Child_At
FROM CatalogChangeMeta c
LEFT JOIN BaseTableCatalog b ON b.BT_UUID = c.Scope_UUID AND b.File_Name = c.File_Name
WHERE c.Catalog = 'FieldCatalog'
  AND c.Modified_At > c.Newest_Child_At + INTERVAL 1 MINUTE
ORDER BY c.Modified_At DESC;
```

## Script dump

**Read a script's steps — ordered, human-readable, with nesting and disabled flag.**
This is the canonical way to look at a script; do not hand-roll a variant. Run it as
`duckdb -readonly -markdown db/fm_catalog.duckdb -c "…"`: without an output mode DuckDB 2.0
shows a script above ~150 steps only as its first and last 20 (`tooling.md` → Agent output
mode).

```sql
SELECT lpad(CAST(s.Step_Index + 1 AS VARCHAR), 3, ' ')            -- user-facing numbering
       || ' ' || repeat('   ', CAST(coalesce(t.block_depth_before, 0) AS INT))
       || coalesce(d.Step_Text, s.Step_Name)                       -- DDR text, else locale name
       || CASE WHEN s.Is_Enabled = false THEN '   <<disabled>>' ELSE '' END AS step
FROM StepsForScripts s
LEFT JOIN DDR_ScriptSteps     d ON d.Step_UUID = s.Step_UUID AND d.File_Name = s.File_Name
LEFT JOIN v_script_block_tree t ON t.Step_UUID = s.Step_UUID AND t.File_Name = s.File_Name
WHERE s.File_Name = '<File>' AND s.Script_Name = '<Script>'
ORDER BY s.Step_Index;
```

Both joins carry `File_Name`: a UUID is unique only **within** one file. Clone
suites (copies of the same FileMaker file) share their step UUIDs across files,
and a `Step_UUID`-only join multiplies every step by the number of copies.
The same rule holds for every `*_UUID` join between catalog tables.

The `coalesce` replaces the old DDR case distinction: without DDR-Info
`Step_Text` is NULL and the query falls back to the (localized) `Step_Name` by
itself — no unscoped `XMLMetadata` lookup, correct in multi-file catalogs.
Nesting comes from `v_script_block_tree`, never from re-reading `Step_Index`
sequences (`analysis-patterns.md` → `control-flow-reachability`).

⚠️ **Locale caveat:** `Step_Name` is written in the exporting client's UI language.
Never gate logic on `Step_Name` literals — use `Step_ID` (via `ScriptStepRoleMap` /
`step_metadata`) for locale-independent step matching.

## Reference cross-checks (fm_spec ≥ 2.8.0)

Both recipes read the language reference next to the catalog. Attach it
read-only as `ref` (the REST API does this automatically; on the direct path
it is one extra statement in the same call):

```sql
ATTACH 'reference/fm_spec.duckdb' AS ref (READ_ONLY);
```

**Trigger compatibility of a layout — which events do not (fully) fire on a runtime?**
Join over the slot id, never over the raw event name. Tri-state: `false` = No,
`NULL` = Partial (conditionally supported — never "undocumented"), `true` = Yes.

```sql
SELECT st.event_name, t.Owner_Type, t.Script_Name,
       c.webdirect, c.go                       -- true / false / NULL = Partial
FROM ScriptTriggers t
JOIN ref.script_triggers st ON st.trigger_id = t.Trigger_ID
LEFT JOIN ref.trigger_compat c ON c.trigger_id = t.Trigger_ID
LEFT JOIN Layouts l ON t.Owner_Type = 'Layout' AND l.L_UUID = t.Owner_UUID AND l.File_Name = t.File_Name
LEFT JOIN LayoutObjects lo ON t.Owner_Type = 'LayoutObject' AND lo.Object_UUID = t.Owner_UUID AND lo.File_Name = t.File_Name
LEFT JOIN Layouts lol ON lo.Layout_ID = lol.L_ID AND lol.File_Name = lo.File_Name
WHERE COALESCE(l.L_Name, lol.L_Name) = '<Layout>' AND t.File_Name = '<File>'
  AND (c.webdirect IS DISTINCT FROM true OR c.go IS DISTINCT FROM true)
ORDER BY st.event_name;
```

**Error-code literals of a script — what does each compared code mean?**
Literals carry no where-used edge, so the calculation text is the source
(plain `Calc_Text`, never `*_XML`). Codes are spans: `BETWEEN`, not `=`.

```sql
WITH pattern AS (                         -- every spelling of Get(LastError) the reference knows
  SELECT '(?i)(?:' || (SELECT string_agg(DISTINCT regexp_extract(lookup_name, '^([^\s(]+)', 1), '|')
                        FROM ref.function_name_lookup WHERE function_id = 139 AND chunk_role = 'getfunction')
      || ')\s*\(\s*(?:' || (SELECT string_agg(DISTINCT lookup_name, '|')
                               FROM ref.function_name_lookup WHERE function_id = 139 AND chunk_role = 'getparameter')
      || ')\s*\)\s*(?:=|≠|<>|<=|>=|≤|≥|<|>)\s*(-?\d+)' AS re)
SELECT s.Step_Index + 1 AS step_no, CAST(u.lit AS INTEGER) AS code,
       e.code_text, e.scope, COALESCE(e.message_en, '(not a documented FileMaker error code)') AS meaning
FROM StepCalculations s, pattern p, UNNEST(regexp_extract_all(s.Calc_Text, p.re, 1)) AS u(lit)
LEFT JOIN ref.error_codes e ON CAST(u.lit AS INTEGER) BETWEEN e.code_from AND e.code_to
WHERE s.File_Name = '<File>' AND s.Script_Name = '<Script>' AND s.Is_Enabled
ORDER BY step_no;
```

`scope = 'web'` codes are returned only by the web publishing engine or a
REST API; a `NULL` join is a code the table does not list (the rule
`error_code_unknown_literal` reports exactly these).
