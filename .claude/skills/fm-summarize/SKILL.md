---
name: fm-summarize
version: 0.8.5
description: Generates a technical summary of a FileMaker object (Script, Field, Layout, CustomFunction, ValueList, BaseTable, TableOccurrence, Relationship, etc.) from the DuckDB database `db/fm_catalog.duckdb`. Uses ObjectCatalog/ObjectLinks for resolution and dependencies and produces a structured Markdown description. Supports two modes — Standard (complete with flow and dependencies) and Short (1-2 paragraphs of prose, via `--short` flag or trigger words). Triggers (English): "describe script X", "summarize field X", "/fm-summarize", "explain layout X technically". Triggers (German): "beschreibe Script X", "fasse das Feld X zusammen", "erkläre mir das Layout X technisch". Triggers (Spanish): "describe el script X", "resume el campo X". Triggers (French): "décris le script X", "résume le champ X". Triggers (Italian): "descrivi lo script X", "riassumi il campo X". Triggers (Dutch): "beschrijf script X", "vat veld X samen". Triggers (Portuguese): "descreva o script X", "resuma o campo X". Triggers (Swedish): "beskriv skript X", "sammanfatta fältet X". Triggers (Japanese): "スクリプトXを説明して", "フィールドXを要約して". Triggers (Korean): "스크립트 X 설명해 줘", "필드 X 요약해 줘". Triggers (Chinese): "描述脚本 X", "总结字段 X".
---

# FileMaker Object Summary

Produce a structured, technical description of a FileMaker object based on the DuckDB database `db/fm_catalog.duckdb`.

## Ground rules

- **Database**: read-only against the master catalog `db/fm_catalog.duckdb` via a plain `duckdb db/fm_catalog.duckdb -c "<SQL>"` (Bash). With an active session pin (`FMLAB_SOLUTION`/`FMLAB_CONTEXT`, CLAUDE.md §2) use the literal bundle path `duckdb solutions/<id>/db/fm_catalog.duckdb` instead (resolve once via `tools/solution.sh current`). Invocation rules, DuckDB-binary resolution and the "never read the `rest-api/db` copy" caveat are in CLAUDE.md §2 (binary not on PATH → `docs/agents/tooling.md`) — don't restate them here, and never install DuckDB.
- **SQL identifiers**: English DDL names — never translate table/column names of the catalog
- **File references**: Markdown links (e.g. `[Script_Name](db/fm_catalog.duckdb)`)
- **Before every DB query**: make sure the object is uniquely identified (see Step 1)
- **Response language**: follows the user's prompt language — see next section

## Response language

Reply in the language of the user's prompt; FileMaker identifiers, `Link_Role` values and
catalog SQL stay original/English. Full policy (what is translated vs. kept, per-language
header examples): [`_shared/response-language.md`](../_shared/response-language.md).

## Output modes

There are two modes that produce outputs of differing scope:

### Standard mode (default)

Detailed Markdown summary with all sections — header, purpose, technical details, flow (numbered for scripts), Uses, Used by, notes. For the exact format see Step 4.

### Short mode (`--short`)

1-2 paragraphs of **prose**, **no** Markdown sections, **no** tables, **no** code blocks. Contains only the essentials: what the object is and what it does, optionally with a rough caller / callee hint.

**Activating short mode** — via the `--short` flag (position-free) or natural-language
trigger words in any of 11 languages: [`_shared/short-mode.md`](../_shared/short-mode.md)
defines both, plus the short-mode output prohibitions.

**Mode differences**:

| Section | Standard | `--short` |
|---------|----------|-----------|
| Header (Name, Type, File, UUID) | ✓ | ✗ (only inline mention in prose) |
| Purpose | ✓ | ✓ (core of the short output) |
| Technical details | ✓ | ✗ |
| Flow (for scripts) | numbered, complete | ✗ (at most a half-sentence: "Calls 4 sub-scripts") |
| Uses | grouped by Link_Role | ✗ |
| Used by | grouped | ✗ (at most "called from 3 places") |
| Notes | ✓ | only critical (e.g. "DDR-Info missing") |

**Query efficiency in short mode**: In short mode only the header query and an aggregation count for callers / callees are executed. The expensive detail queries (all steps with DDR_ScriptSteps, all field usages with comments, all lookup sources) are skipped — this saves runtime and tokens when reading the tool results.

**Identification is the same in both modes** — in short mode too the object must first be unique (Step 1 is indispensable).

## Workflow

### Step 1 — Identify the object (BLOCKING)

Resolve the input (UUID / name / conversation context) to exactly one object per the
shared contract in [`_shared/resolve-object.md`](../_shared/resolve-object.md); the
queries live in [`_shared/scripts/resolve_object.sql`](../_shared/scripts/resolve_object.sql).
The contract yields a unique `(Object_UUID, Object_Type, Object_Name, File_Name)` — the
**File_Name is mandatory**, because clone/modular files share the same Object_UUID.

Key rules from the contract: never silently take the first row on an ambiguous name or a
clone-shared UUID — present a numbered selection list and wait. A type hint
("describe the *layout* 'Customers'") adds `AND Object_Type = '<Type>'`. Only after unique
identification does the type-specific workflow (Step 2) start.

### Step 2 — Retrieve type-specific data

Based on `Object_Type` pick the matching template. **The SQL lives in
[`_shared/scripts/type_queries.sql`](../_shared/scripts/type_queries.sql)** (query IDs in
brackets below) — substitute the `<UUID>` / `<FILE>` / `<L_ID>` / `<HASH>` tokens and run
each statement as `duckdb db/fm_catalog.duckdb -c "…"`. Every template filters on
`File_Name` AND the type UUID, because names and numeric FM IDs are only unique per file.

- **Script** [S1 header, S2 steps]: the step-by-step flow is the centrepiece of the
  summary — number each step **1-based as `Step_Index + 1`** (the DB column is 0-based;
  FileMaker's Script Workspace and the fm-lab frontend count from 1 — see
  `schema-reference.md` → Common columns), mark disabled steps `(disabled)`, and
  prefer `DDR_ScriptSteps.Step_Text` when present. Then dependencies via Step 3.
- **Field** [F1; D1 for DDR chunks if `DDR_Hash`/`AE_Calc_Hash` present]: evaluate
  `Field_Type` (Normal/Calculated/Summary), `Data_Type`, `Field_Comment`, `Is_Global`;
  for Calculated read `Calculation_Text`; for AutoEnter let `AutoEnter_Type` select the
  detail columns (Looked_up / Calculated / ConstantData / SerialNumber …). Usages via
  ObjectLinks `Target_UUID = Field-UUID` (`displays_field`, `sets_field`, `lookup_source`,
  `left_field`/`right_field`, `source_field`).
- **Layout** [L1 layout, L2 parts, L3 object stats, L4 triggers]: never list hundreds of
  LayoutObjects individually — L3 aggregates. Referenced objects via ObjectLinks
  (`Source_Type = LayoutObject`, `parent_layout`).
- **CustomFunction** [CF1, CF2; D1 for DDR chunks]: callers via ObjectLinks
  `Target_UUID = CF-UUID`.
- **ValueList** [VL1]: users via ObjectLinks `Target_UUID = VL-UUID`, role `uses_valuelist`.
- **BaseTable** [BT1, BT2 fields, BT3 table occurrences].
- **TableOccurrence** [TO1, TO2 relationships].
- **Relationship** [R1]: predicates in `Left_*`/`Right_*`, operator in `Operator`.
- **Calculation** [C1 instance, C2 resolved targets, C3 sibling slots of the owner]:
  a calculation INSTANCE (schema 1.22.0, `CalculationsCatalog`) — identity is
  Owner × `Calc_Role` × `Calc_Index`, the formula text comes from
  `Formula_Text`/`Display_Text` and exists **also without DDR info** (hash/chunk
  columns are enrichment, may be NULL). Owner context via the `has_calculation`
  backlink; usage semantics live on the OWNER's edges (variant A) — C2 is the
  per-slot detail resolution, never a where-used substitute.
- **Any other type** [G0 basics, G1 incoming links, G2 outgoing links].

### Step 3 — Dependencies (for all types)

Standard query for incoming and outgoing links. **Important**: filter only on `Link_Type = 'operational'` to hide structural hierarchy noise (parent_object, parent_layout, parent_script). Include structural links only when they are substantively relevant for the object type.

```sql
-- What this object uses (outgoing)
SELECT
    ol.Link_Role,
    ol.Target_Type,
    oc.Object_Name AS Target_Name,
    ol.Target_File,
    ol.Is_Cross_File
FROM ObjectLinks ol
LEFT JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID
WHERE ol.Source_UUID = '<UUID>'
  AND ol.Link_Type = 'operational'
ORDER BY ol.Link_Role, oc.Object_Name;

-- Who uses this object (incoming)
SELECT
    ol.Link_Role,
    ol.Source_Type,
    oc.Object_Name AS Source_Name,
    ol.Source_File,
    ol.Is_Cross_File
FROM ObjectLinks ol
LEFT JOIN ObjectCatalog oc ON ol.Source_UUID = oc.Object_UUID
WHERE ol.Target_UUID = '<UUID>'
  AND ol.Link_Type = 'operational'
ORDER BY ol.Link_Role, oc.Object_Name;
```

### Step 4 — Produce the Markdown summary

**In short mode** (`--short` or trigger word): jump directly to the "Short-mode output" section at the end of this step. The detailed section structure below only applies in standard mode.

The standard output follows this schema. Omit sections without content.

```markdown
## <Object_Type>: <Name>

**File**: <File_Name>
**UUID**: `<Object_UUID>`
**Internal ID**: <Object_ID> (if relevant)

<!-- Conversation identity = the pair (UUID, File_Name). Always emit BOTH lines:
     clone/modular files share Object_UUID, so downstream skills (fmide-show,
     fm-analyze) must read the File_Name back to resolve the object unambiguously. -->


### Purpose
<From Field_Comment / other comments, or a brief derivation from name + context.
If no comment is present: "No comment stored in the object." and a note
that the purpose was derived from the behaviour.>

### Technical details
<Type-specific — see below>

### Flow  *(scripts only)*
1. **<Step_Name>** — <DDR_Step_Text if present, otherwise Step_Name + Calculation_Text>
2. ...
   *(list numbers = `Step_Index + 1`, 1-based; mark disabled steps with `(disabled)`)*

### Uses
<List of objects this object calls / references, grouped by Link_Role>
- **calls_script**: ScriptA, ScriptB
- **sets_field**: Table::Field
- ...

### Used by
<List of objects that call / reference this object>
- **LayoutObject** (displays_field): Layout "Customers"
- ...

### Notes
<Optional: notable items, e.g. cross-file links, very many usages, missing comments,
disabled steps, unusual constructions>
```

**Format rules (standard mode)**:
- Markdown tables only when they really add value (>5 rows, multiple columns)
- For very long lists (>20 entries): summarise ("12 more fields ...") and provide details on request
- Keep all FileMaker identifiers in the original language of the solution (script/field/table names are not translated)
- **Section headers and prose are produced in the response language** (see the "Response language" section near the top); the English headers in the template above are illustrative
- For scripts: when `DDR_ScriptSteps.Step_Text` is present, ALWAYS prefer the readable text — it contains resolved field names, variable contents and parameters

#### Short-mode output (`--short`)

In short mode the section structure above is dropped entirely. Instead: **1-2 paragraphs of prose** that compactly answer the following questions:

1. **What is the object?** — type, name, file (inline, e.g. "The script **Accounting_PrintInvoice** in the file `Invoices`")
2. **What does it do?** — 1-3 sentences, core function in your own words
3. **(Optional) How is it embedded?** — at most one half-sentence about callers or sub-calls, ONLY if it materially illuminates the context

**Prohibitions**: see [`_shared/short-mode.md`](../_shared/short-mode.md) (no headers,
lists, tables, code blocks or UUID). Additionally for summaries: **no "Flow"** (not even
shortened).

**Reduced query list in short mode**:

| Object_Type | Standard-mode queries | Short-mode queries |
|-------------|------------------------|---------------------|
| Script | ScriptCatalog + StepsForScripts + DDR_ScriptSteps + all ObjectLinks | Only ScriptCatalog + COUNT(*) callers + COUNT(*) sub-calls |
| Field | FieldsForTables + DDR_Calculations + all usages | Only FieldsForTables (Field_Comment + Field_Type + AutoEnter_Type) |
| Layout | Layouts + LayoutParts + LayoutObjects aggregation + triggers | Only Layouts + COUNT(*) of LayoutObjects |
| CustomFunction | CustomFunctionsCatalog + CalcsForCustomFunctions + DDR + callers | Only CustomFunctionsCatalog + COUNT(*) callers |
| Other | Type-specific queries + ObjectLinks bidirectional | Only ObjectCatalog entry + COUNT(*) incoming/outgoing links |

**Example output (short mode, script)**:

> The script **Accounting_PrintInvoice** in the file `Invoices` produces a PDF output of a single invoice at the supplied storage location. It is called from 2 places (manually from invoice editing and from the batch processing) and uses 2 helper scripts.

**Example output (short mode, field)**:

> The field **Email** in the table `Customers` is a text field with AutoEnter Calculated `Lower(Self)`. According to the field comment the normalisation serves unique comparability for email dispatch.

**If short mode delivers too little information**: append a single hint sentence at the end of the prose, such as *"For the full steps and dependencies call `/fm-summarize <Name>` without `--short`."*

### Step 5 — Output

Print the Markdown summary in chat. Do NOT write a file.

## Important notes

- **Check DDR availability**: `SELECT Has_DDR_INFO FROM XMLMetadata WHERE Filename = '<File>';` If `False`, `DDR_ScriptSteps` and `DDR_Calculations` are empty and deliver no plain-text texts. In that case fall back to `Step_Name`, `Calculation_Text` and `Variable_Name`.
- **Multi-file**: If the object has cross-file dependencies (`Is_Cross_File = TRUE`), call them out explicitly.
- **Performance**: For layouts with hundreds of objects do NOT list all LayoutObjects individually — always aggregate.
- **No speculation**: If the data is incomplete, note that honestly instead of guessing.
- **Read vs. write**: This skill only reads. Never execute UPDATE/INSERT/DELETE on the database.
- **Order of actions**: identification → confirmation (if ambiguous) → type-specific queries → dependencies → output. Do not cut corners.
- **Error-code literals**: in the flow of a script, resolve numeric literals compared with `Get(LastError)` to their documented meaning via `reference/fm_spec.duckdb` → `error_codes` (`WHERE n BETWEEN code_from AND code_to`; fm_spec ≥ 2.8.0 — leave the number alone if the table is missing).
- **Analysis Tests & patterns**: If the user's real question is "is something wrong with this object?" (or a symptom like "hangs"/"slow"), a curated Analysis Test may serve them better than a description — mention `fm-test` (and the patterns in `docs/agents/analysis-patterns.md`) as a follow-up option after the summary.

## Examples

### Example 1: Unambiguous script name

**User (English, primary)**: "Describe the script 'Kunde anlegen'"
**User (German, equivalent)**: "Beschreibe das Script 'Kunde anlegen'"
**User (French, equivalent)**: "Décris le script 'Kunde anlegen'"

Note: the object name `Kunde anlegen` stays as-is in any language — it is the FileMaker source identifier.

1. Search in ObjectCatalog → 1 match (Object_Type = `Script`, File_Name = `KundenDB`)
2. Query ScriptCatalog + StepsForScripts + DDR_ScriptSteps
3. Query ObjectLinks for incoming/outgoing links
4. Produce the Markdown summary with numbered flow, headers and prose in the response language (English/German/French depending on the prompt)

### Example 2: Ambiguous name

**User**: "What does 'Suchen' do?"

1. Search in ObjectCatalog → 4 matches (1× Script in `KundenDB`, 1× Script in `RechnungenDB`, 1× CustomFunction in `KundenDB`, 1× Layout in `KundenDB`)
2. **Output to the user**:
   ```
   There are several objects named 'Suchen'. Which one do you mean?
   1. Script "Suchen" in KundenDB
   2. Script "Suchen" in RechnungenDB
   3. CustomFunction "Suchen" in KundenDB
   4. Layout "Suchen" in KundenDB
   ```
3. Only continue with Step 2 after the user's answer.

### Example 3: Context derivation

**Conversation context**: a previous query listed five fields; the last one was `Kunden::Telefon` (UUID `abc-123`).

**User**: "Describe the last of those fields"

1. Derive UUID `abc-123` from the context
2. Start directly with the FieldsForTables query (no follow-up needed)
3. Evaluate AutoEnter columns, include DDR_Calculations if applicable
4. Usages via ObjectLinks
5. Print summary

### Example 4: Short mode

**User (flag form)**: "/fm-summarize Accounting_PrintInvoice --short"
**User (English, natural)**: "Describe Accounting_PrintInvoice briefly"
**User (German, natural)**: "Beschreibe Accounting_PrintInvoice kurz"
**User (French, natural)**: "Décris brièvement Accounting_PrintInvoice"

All four prompts activate short mode; the response is produced in the prompt's language.

1. Identification as usual → 1 match (Script in `Invoices`)
2. **Reduced queries**: only ScriptCatalog header + two COUNT(*) aggregations over ObjectLinks (callers / sub-calls). NO steps, NO DDR_ScriptSteps, NO field usages.
3. **Output** (1-2 paragraphs of prose, no sections):

   > The script **Accounting_PrintInvoice** in the file `Invoices` produces a PDF output of a single invoice. It is called from 2 places and calls 2 helper scripts.
   >
   > For the full steps and dependencies call `/fm-summarize Accounting_PrintInvoice` without `--short`.

### Example 5: Not found

**User**: "Describe the script 'KundeAnlegenV2'"

1. Search in ObjectCatalog → 0 matches
2. LIKE fallback `%Kunde%anlegen%` → 1 match: "KundeAnlegen"
3. **Output**: "A script named 'KundeAnlegenV2' does not exist. Did you perhaps mean 'KundeAnlegen'? Should I describe that one?"

