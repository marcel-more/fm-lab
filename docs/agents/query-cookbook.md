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
- **Dynamic references are invisible** (`GetField`, `Evaluate`, TO names inside
  `ExecuteSQL` strings).
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
can only drift from it.

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
