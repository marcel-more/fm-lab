# Query Cookbook — SQL Patterns & DuckDB Idioms

> Referenced from CLAUDE.md §8. Canonical query patterns for the object catalog
> plus DuckDB-specific syntax hints. More prepared queries: `docs/agents/sql/sample_queries.sql`.

## DuckDB commands for this project

```bash
# Execute a query
duckdb db/fm_catalog.duckdb -c "SELECT * FROM ScriptCatalog"

# Execute a prepared query file
duckdb db/fm_catalog.duckdb < docs/agents/sql/sample_queries.sql
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

## Statistics

**Object count per type and file:**
```sql
SELECT Object_Type, File_Name, COUNT(*) as Count
FROM ObjectCatalog
GROUP BY Object_Type, File_Name
ORDER BY Object_Type, File_Name;
```

## Script dump

**Read a script's steps — ordered, human-readable, with nesting and disabled flag.**
This is the canonical way to look at a script; do not hand-roll a variant.

```sql
SELECT lpad(CAST(s.Step_Index + 1 AS VARCHAR), 3, ' ')            -- user-facing numbering
       || ' ' || repeat('   ', CAST(coalesce(t.block_depth_before, 0) AS INT))
       || coalesce(d.Step_Text, s.Step_Name)                       -- DDR text, else locale name
       || CASE WHEN s.Is_Enabled = false THEN '   <<disabled>>' ELSE '' END AS step
FROM StepsForScripts s
LEFT JOIN DDR_ScriptSteps     d ON d.Step_UUID = s.Step_UUID
LEFT JOIN v_script_block_tree t ON t.Step_UUID = s.Step_UUID
WHERE s.File_Name = '<File>' AND s.Script_Name = '<Script>'
ORDER BY s.Step_Index;
```

The `coalesce` replaces the old DDR case distinction: without DDR-Info
`Step_Text` is NULL and the query falls back to the (localized) `Step_Name` by
itself — no unscoped `XMLMetadata` lookup, correct in multi-file catalogs.
Nesting comes from `v_script_block_tree`, never from re-reading `Step_Index`
sequences (`analysis-patterns.md` → `control-flow-reachability`).

⚠️ **Locale caveat:** `Step_Name` is written in the exporting client's UI language.
Never gate logic on `Step_Name` literals — use `Step_ID` (via `ScriptStepRoleMap` /
`step_metadata`) for locale-independent step matching.
