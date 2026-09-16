---
name: fm-analyze
version: 0.8.5
description: Analyzes the business logic and semantic purpose of a FileMaker object (Script, Field, Layout, CustomFunction, ValueList, etc.) from the DuckDB database `db/fm_catalog.duckdb`. Unlike fm-summarize (purely technical description), this analysis considers the context: variable naming, layout labels, upstream and downstream scripts in the call chain, trigger sources, and field comments of linked objects. From these, the presumed business purpose is derived and described. Supports two modes — Standard (full report with call chain and semantic signals) and Short (1-2 paragraphs of prose, via `--short` flag or trigger words). Triggers (English): "/fm-analyze", "analyze script X", "what is the purpose of X", "explain the business intent of X". Triggers (German): "analysiere Script X", "was ist der Zweck von X", "welche Business-Logik steckt hinter X". Triggers (Spanish): "analiza el script X", "¿cuál es el propósito de X?". Triggers (French): "analyse le script X", "quel est l'objectif de X ?". Triggers (Italian): "analizza lo script X", "qual è lo scopo di X?". Triggers (Dutch): "analyseer script X", "wat is het doel van X?". Triggers (Portuguese): "analise o script X", "qual é o propósito de X?". Triggers (Swedish): "analysera skript X", "vad är syftet med X?". Triggers (Japanese): "スクリプトXを分析して", "Xの目的は何ですか". Triggers (Korean): "스크립트 X 분석해 줘", "X의 목적이 무엇인가요". Triggers (Chinese): "分析脚本 X", "X 的目的是什么".
---

# FileMaker Object Analysis (Business Logic)

Analyze a FileMaker object not only technically, but derive its **business purpose** and **business logic** from the context — variable names, connected scripts, layout labels, field comments, trigger sources, and downstream effects.

## Differences from fm-summarize

| Aspect | fm-summarize | fm-analyze |
|--------|-------------|------------|
| Focus | What does the object do technically? | Why does it exist from a business perspective? |
| Depth | Direct object + 1 hop | Multiple hops (call chain, caller-of-caller, ...) |
| Sources | StepsForScripts, FieldsForTables, ObjectLinks | + variable names, layout names, field comments of linked objects, trigger context |
| Result | Structured fact list | Narrative description with conclusions |
| Typical question | "What steps does the script have?" | "What business logic does this script implement?" |

**Rule of thumb**: If the user wants to know what the object **does** → fm-summarize. If they want to know what the object **means** or its **purpose** → fm-analyze.

The two skills are not mutually exclusive: fm-analyze internally uses many of the same queries as fm-summarize, but evaluates the results semantically and extends them with context hops.

## Ground rules

- **Database**: read-only against the master catalog `db/fm_catalog.duckdb` via a plain `duckdb db/fm_catalog.duckdb -c "<SQL>"` (Bash). With an active session pin (`FMLAB_SOLUTION`/`FMLAB_CONTEXT`, CLAUDE.md §2) use the literal bundle path `duckdb solutions/<id>/db/fm_catalog.duckdb` instead (resolve once via `tools/solution.sh current`). Invocation rules, DuckDB-binary resolution and the "never read the `rest-api/db` copy" caveat are in CLAUDE.md §2 (binary not on PATH → `docs/agents/tooling.md`) — don't restate them here, and never install DuckDB.
- **SQL identifiers**: English DDL names — never translate table/column names of the catalog
- **Read-only**: Never UPDATE/INSERT/DELETE
- **Before every analysis**: Uniquely identify the object (see Step 1)
- **Mark conclusions**: Clearly separate what is fact (from DB) and what is interpretation (from naming/context). Mark interpretations with hedging vocabulary (see Response language section for per-language equivalents).
- **Step numbers are 1-based in prose**: `StepsForScripts.Step_Index` is 0-based — whenever a specific step is quoted to the user, render `Step_Index + 1` (matches FileMaker's Script Workspace and the fm-lab frontend; see `schema-reference.md` → Common columns).
- **Response language**: follows the user's prompt language — see next section

## Response language

Reply in the language of the user's prompt; FileMaker identifiers, `Link_Role` values and
catalog SQL stay original/English. Full policy and the **per-language hedging vocabulary**
(mandatory for this skill's interpretations): [`_shared/response-language.md`](../_shared/response-language.md).

## Output modes

### Standard mode (default)

Full Markdown report with Presumed Purpose, Business Context, Semantic Signals, Call Chain (incoming + outgoing, recursive), Touched Objects, Noteworthy Observations and Open Questions. See Step 5 for the exact format.

### Short mode (`--short`)

1-2 paragraphs of **prose** with only the core conclusion of the analysis: what the object
does from a business perspective and in which module it operates. Activation (the `--short`
flag or natural-language trigger words in 11 languages) and the output prohibitions:
[`_shared/short-mode.md`](../_shared/short-mode.md).

**Mode differences**:

| Section | Standard | `--short` |
|---------|----------|-----------|
| Header (name, type, file, UUID) | ✓ | ✗ (only inline in prose) |
| Presumed purpose | ✓ detailed | ✓ core (1-2 sentences) |
| Business context (module/role/trigger source) | ✓ as list | ✓ inline in prose (1 half-sentence) |
| Semantic signals | ✓ as list | ✗ |
| Call chain (incoming/outgoing) | ✓ recursive with paths | ✗ (at most "is called from 3 places") |
| Touched objects (table) | ✓ | ✗ |
| Noteworthy observations | ✓ | only critical (e.g. "DDR-Info missing") |
| Open questions | ✓ | ✗ |

**Reduced query list in short mode**: Instead of querying all context hops from Step 3, the following are sufficient:
- Core data of the object (name, comment, type)
- Aggregated caller/callee counts (1 hop, no recursive CTE)
- Top-3 touched tables/layouts as a module hint
- NO recursive call chains, NO per-variable aggregation, NO field-comment joins

**Hedging remains mandatory**: Even in short mode, interpretations must be marked with "presumably" / "indicates" / "suggests". Better to give no module than a wrong one.

**Identification works the same in both modes** — even in short mode, the object must first be unique (Step 1 is indispensable).

## Workflow

### Step 1 — Identify object (BLOCKING)

Resolve the input (UUID / name / conversation context) to exactly one object per the
shared contract in [`_shared/resolve-object.md`](../_shared/resolve-object.md); the queries
live in [`_shared/scripts/resolve_object.sql`](../_shared/scripts/resolve_object.sql). The
contract yields a unique `(Object_UUID, Object_Type, Object_Name, File_Name)` — the
**File_Name is mandatory** (clone/modular files share the same Object_UUID). Never take the
first row silently on an ambiguous name or clone-shared UUID; present a numbered selection
list and wait. When deriving from context, read **both** the UUID and File_Name from the
conversation identity (e.g. the fm-summarize header), since the UUID alone is ambiguous
across clones. Only after unique identification does the analysis proceed.

### Step 2 — Load core data of the object

Depending on Object_Type, fetch the type-specific base data — the shared SQL templates in [`_shared/scripts/type_queries.sql`](../_shared/scripts/type_queries.sql) (query IDs S1/F1/L1…). Usually this is sufficient:

- **Script**: ScriptCatalog + StepsForScripts JOIN DDR_ScriptSteps (Step_Text preferred)
- **Field**: FieldsForTables (incl. Field_Comment, Calculation_Text, AE_Calc_Text)
- **Layout**: Layouts + LayoutParts + LayoutObjects (aggregated)
- **CustomFunction**: CustomFunctionsCatalog + CalcsForCustomFunctions + DDR_Calculations
- **Calculation** (schema 1.22.0): CalculationsCatalog [C1/C2/C3] — one calculation
  INSTANCE (Owner × Calc_Role × Calc_Index). The business context comes from the
  OWNER (owner name/comment, slot role: hide condition vs. validation vs. step
  parameter …) plus the formula (`Formula_Text`/`Display_Text` — present also
  without DDR info). Analyze it as "the owner's <role> slot", never as a
  free-standing formula.

**Important for fm-analyze**: In contrast to fm-summarize, the **Field_Comment** is gold dust here — if present, it is the most direct source for the business purpose. Script comments in the first step (`Step_Type = 'Comment'`) should also be read, since developers often document scripts with a header comment.

### Step 3 — Collect semantic signals (the core)

Beyond Step 2, query the following context sources. Which are relevant depends on the Object_Type.

#### 3a — Variable semantics

Variable names are often meaningful (`$customerID`, `$$Modul`, `$invoiceDate`). Via `VariableUsages` and `VariablesCatalog`, find out which variables the object sets/reads:

```sql
-- Which variables are set/read in this script?
SELECT
    Variable_Name,
    Variable_Scope,
    Usage_Type,
    Source,
    COUNT(*) AS Count
FROM VariableUsages
WHERE Script_UUID = '<Script_UUID>' AND File_Name = '<File>'
GROUP BY ALL
ORDER BY Variable_Name, Usage_Type;
```

```sql
-- Where else is a specific variable used (gives hints about module context)?
SELECT Context_Type, Context_Name, Script_Name, Usage_Type, File_Name
FROM VariableUsages
WHERE Variable_Name = '<$$Modul>'
ORDER BY Context_Type, Context_Name;
```

**Evaluation**: Meaningful names like `$$selectedCustomer`, `$invoiceAmount`, `$$isAdmin` indicate the business purpose. Global variables (`$$`) often indicate module or session context. Superglobals (`$$$` via MBS) suggest system-wide configurations.

#### 3b — Script call chain (backward and forward)

Two recursive queries in [`_shared/scripts/call_chain.sql`](../_shared/scripts/call_chain.sql)
(substitute `<SCRIPT_UUID>`): **CC-FWD** (forward — what this script calls) and **CC-BWD**
(backward — who calls it). Both cap depth at 5 hops and return a ready-to-render `Path`
column (arrow-joined chain).

**Rendering the result** (feeds Step 5 "Call chain"): render the `Path` rows directly —
CC-BWD paths *end* at this script (→ the **Incoming** block), CC-FWD paths *start* at it
(→ the **Outgoing** block). Order by `Depth`; where several paths share a prefix, indent
the continuations under it. On a high branching factor (more than ~15 distinct paths),
show only the Depth-1 immediate neighbours plus a few representative deep paths and note
the truncation — never dump hundreds of rows.

**Evaluation**: The backward chain (callers) reveals the business trigger: "Called by
'Create invoice'" → the script belongs to invoicing. The forward chain shows which further
business building blocks are touched.

#### 3c — Trigger sources (layout triggers, script triggers, LayoutObject triggers)

If the script is started via a trigger rather than a direct call, the trigger context is decisive for its meaning:

```sql
-- Incoming trigger links
SELECT ol.Link_Role, ol.Source_Type,
       oc.Object_Name AS Trigger_Source, oc.File_Name
FROM ObjectLinks ol
JOIN ObjectCatalog oc ON ol.Source_UUID = oc.Object_UUID
WHERE ol.Target_UUID = '<Script_UUID>'
  AND ol.Link_Role IN ('triggers_script', 'trigger_script');
```

If the `ScriptTriggers` table contains a direct link to the Script UUID, additionally:

```sql
SELECT * FROM ScriptTriggers WHERE File_Name = '<File>' LIMIT 5;
-- Check schema before use — columns vary by database version
```

**Evaluation**: Triggers like `OnRecordCommit` on layout "Invoices" indicate a validation or follow-up action before saving. `OnObjectExit` on an input field indicates a calculation after entry.

#### 3d — Touched fields and their comments

Fields the script sets or reads, plus their comments:

```sql
SELECT DISTINCT
    f.Table_Name,
    f.Field_Name,
    f.Field_Type,
    f.Field_Comment,
    ol.Link_Role
FROM ObjectLinks ol
JOIN ObjectCatalog oc ON ol.Target_UUID = oc.Object_UUID
JOIN FieldsForTables f ON oc.Object_UUID = f.Field_UUID
WHERE ol.Source_UUID = '<Script_UUID>'
  AND ol.Target_Type = 'Field'
  AND ol.Link_Role IN ('sets_field', 'navigates_to_field')
ORDER BY f.Table_Name, f.Field_Name;
```

**Evaluation**: The table names (`Customers`, `Invoices`, `ShippingAddresses`) show which business entities are affected. Field_Comments — if present — are first-hand business descriptions.

#### 3e — Touched layouts

Which layouts does the script navigate to? Layout names are often meaningful.

```sql
SELECT DISTINCT
    l.L_Name AS Layout_Name,
    l.L_TO_Name AS Context_TO,
    l.File_Name
FROM ObjectLinks ol
JOIN Layouts l ON ol.Target_UUID = l.L_UUID
WHERE ol.Source_UUID = '<Script_UUID>'
  AND ol.Link_Role = 'navigates_to_layout';
```

**Evaluation**: If a script switches to "Invoice_Print", a print workflow is plausible. The `L_TO_Name` (context table occurrence) reveals the business data basis.

#### 3f — Table context

For fields/TOs/relationships, look at the fields of the associated table — the field names of a table together often reveal the business model:

```sql
SELECT Field_Name, Field_Type, Field_Comment
FROM FieldsForTables
WHERE Table_UUID = '<BT_UUID>' AND File_Name = '<File>'
ORDER BY Field_ID;
```

#### 3g — For CustomFunctions: who calls them?

```sql
SELECT
    oc.Object_Type,
    oc.Object_Name,
    oc.File_Name,
    ol.Link_Role
FROM ObjectLinks ol
JOIN ObjectCatalog oc ON ol.Source_UUID = oc.Object_UUID
WHERE ol.Target_UUID = '<CF_UUID>'
  AND ol.Link_Type = 'operational';
```

The callers give a hint about the business area in which the function operates.

### Step 4 — Semantic evaluation

Derive conclusions from the collected signals. **Procedure**:

1. **Naming heuristic**: Look for recurring terms in object, variable, field, table and layout names. Do "Invoice", "Billing", "Invoice" appear multiple times? → invoicing module. "Customer", "Account"? → master-data management.
2. **Action heuristic**: Which verbs appear in the script name and in the step texts? `Create`, `Generate`, `Print`, `Import`, `Validate`, `Calculate` — they indicate the primary purpose.
3. **Data-flow heuristic**: Does the script read more than it writes → presumably calculation/evaluation. Does it write more than it reads → presumably creation/update. Does it switch layouts → navigation control.
4. **Trigger heuristic**: If the script is called exclusively from a trigger → it is a reaction to an event, not a workflow started by the user.
5. **Module mapping**: From the touched tables and layouts, derive the business module (invoicing, CRM, inventory, accounting, permissions, master data, reporting, ...).
6. **Recognize reuse**: If a script is called by many different callers in different modules → it is a utility/helper function. If it is called from only one place → it is a specific workflow step.
7. **Flag inconsistencies**: If the name suggests something that the implementation does not reflect (e.g. script "Create Customer" that only switches a layout), report this as a hint.

**Separation of facts and interpretation**:
- Facts: "The script calls 4 sub-scripts and writes to the fields Invoices::Status and Invoices::Paid_on."
- Interpretation: "This combination suggests that the script books the payment receipt of an invoice."

### Step 5 — Generate Markdown report

**In short mode** (`--short` or trigger word): Jump directly to the "Short-mode output" section at the end of this step. The detailed section structure below applies only to standard mode.

Standard format:

```markdown
## Analysis: <Object_Type> "<Name>"

**File**: <File_Name>
**UUID**: `<Object_UUID>`

<!-- Conversation identity = the pair (UUID, File_Name). Always emit BOTH lines so
     downstream skills (fmide-show, fm-summarize) can resolve clone-shared UUIDs. -->

### Presumed purpose
<2-4 sentences in your own words on what the object does from a business perspective. Use hedging
("presumably", "indicates") if the conclusion is not 100% certain.>

### Business context
- **Module / domain**: <e.g. invoicing, CRM, permissions — derived from touched tables/layouts/variables>
- **Role**: <e.g. main workflow script, utility function, validation, trigger reaction, print preparation>
- **Trigger source**: <How is the object typically started? Direct call, trigger, button, menu>

### Semantic signals
- **Meaningful variables**: $$SelectedCustomer, $invoiceAmount → indicate customer/invoice context
- **Touched tables**: Customers, Invoices, InvoiceItems → invoicing
- **Layouts**: "Invoice_Edit", "Invoice_Print" → print workflow plausible
- **Callers**: Called exclusively from "Start Invoice" → step in invoicing workflow
- **Called sub-scripts**: "Assign Invoice Number", "Calculate Taxes" → structured creation workflow

### Call chain
**Incoming** (who calls this object):
\`\`\`
Start Invoice → Create Invoice (this script)
Batch Processing → Create Invoice
\`\`\`

**Outgoing** (what does this object call):
\`\`\`
Create Invoice → Assign Invoice Number
                → Calculate Taxes → Load VAT Table
                → Switch Layout to "Invoice_Edit"
\`\`\`

### Touched objects (selection)
| Table | Field | Action | Field comment |
|-------|-------|--------|---------------|
| Invoices | Status | sets_field | Workflow status of the invoice |
| Invoices | Paid_on | sets_field | Date when the invoice was paid |
| ... | ... | ... | ... |

### Noteworthy observations / hints
<Optional: inconsistencies, missing comments, unusual constructs, very wide
reuse, disabled steps, dead code, cross-file dependencies>

### Open questions
<Optional: If the analysis leaves gaps that only the developer can answer —
formulate concrete follow-up questions instead of speculating.>
```

**Format rules (standard mode)**:
- Maximum 1-2 Markdown tables per report (only where they really add value)
- Lists with >15 entries: truncate with "(further X)"
- Code blocks only for call chain paths
- Consistent hedging in the response language (see Response language section for per-language vocabulary) — never assert as fact what is only an interpretation
- **Section headers and prose are produced in the response language** (see the "Response language" section near the top); the English headers in the template above are illustrative — FileMaker identifiers stay original
- For scripts without DDR-Info (Step_Text NULL), explicitly mention that the analysis is limited by missing plain-text descriptions

#### Short-mode output (`--short`)

In short mode, the section structure above is completely omitted. Instead: **1-2 paragraphs of prose** that compactly answer the following questions:

1. **What is the object from a business perspective?** — type, name, file (inline) + 1-2 sentences on the presumed purpose
2. **In which module / domain?** — at most one half-sentence (e.g. "in the invoicing module")
3. **(Optional) How is it integrated?** — at most one half-sentence on the caller class, ONLY if it substantially explains the business purpose

**Prohibitions**: see [`_shared/short-mode.md`](../_shared/short-mode.md) (no headers,
lists, tables, code blocks or UUID). Additionally for analyses: **no call-chain paths**,
**no enumeration of semantic signals**, and **no separate "Open questions" section** (open
questions, if any, as a final half-sentence in the prose).

**Hedging remains mandatory**: "Presumably", "suggests", "indicates" — interpretations must also be marked as such in short mode.

**Example output (short mode, script)**:

> **Accounting_PrintInvoice** (file `Invoices`) is presumably the print / PDF workflow for a single invoice in the invoicing module. The touched tables (`Invoices`, `InvoiceItems`) and the layout names ("Invoice_Print", "Invoice_PDF") suggest this. It is called both manually from invoice editing and from a batch workflow.

**Example output (short mode, field)**:

> The field **Email** in `Customers` presumably stores a normalized (lower-cased) form of the email address for unambiguous comparison — the field comment confirms this. The AutoEnter calculation `Lower(Self)` and its use in the email-dispatch workflow indicate the master-data / communication context.

**If short mode does not provide enough information**: Append ONE hint sentence at the end of the prose such as *"For the full call chain and semantic signals, run `/fm-analyze <Name>` without `--short`."*

### Step 6 — Output

Output the report in the chat. Do not write to files.

## Important notes

- **DDR availability**: Without DDR-Info (`XMLMetadata.Has_DDR_INFO = 'False'`), `DDR_ScriptSteps.Step_Text` and `DDR_Calculations.Chunk_Content` are empty. In that case the semantic analysis becomes significantly weaker because resolved field/variable references are missing. Mention this limitation explicitly in the report.
- **Depth limit**: Always guard recursive CTEs with `c.Depth < 5` (or smaller) to avoid cycles and explosion.
- **Performance**: For scripts with hundreds of touched fields, aggregate instead of listing individually.
- **Hedging is mandatory**: This skill delivers interpretations. Mark as interpretation what is interpretation. False certainty is worse than honest uncertainty.
- **Generic fallback**: For Object_Types without a specific workflow (Theme, CustomMenu, Account, etc.), the ObjectLinks hop-out and the evaluation of callers/users is often sufficient to classify the purpose.
- **Skill composition**: If the user wants ONLY to see the steps instead of an analysis — use fm-summarize, not both.
- **Error-code literals**: when a script compares `Get(LastError)` with numeric literals, resolve them to plain text via `reference/fm_spec.duckdb` → `error_codes` (`WHERE n BETWEEN code_from AND code_to`; fm_spec ≥ 2.8.0, skip silently if the table is missing) — "101 = Record is missing" says more about the intent than the number; a code the table does not list is worth a hint (test `error_code_unknown_literal`).
- **Analysis Tests & patterns**: When the entry is a *symptom* ("hangs", "slow", "wrong results", "escalating calls") or a "is something wrong with X?" question, check for matching Analysis Tests (`fm-test` skill, `GET /api/tests?objectType=…`) and analysis patterns (`docs/agents/analysis-patterns.md`) and offer them alongside the free-form analysis — tests deliver reproducible, curated findings that this skill can then interpret.

## Examples

### Example 1: Script with clear module context

**User (English, primary)**: "What is the business purpose of 'Accounting_PrintInvoice'?"
**User (German, equivalent)**: "Was ist der fachliche Zweck von 'Accounting_PrintInvoice'?"
**User (French, equivalent)**: "Quel est l'objectif métier de 'Accounting_PrintInvoice' ?"

Note: the object name `Accounting_PrintInvoice` stays as-is in any language — it is the FileMaker source identifier. The analysis report (Presumed purpose, Business context, etc.) is produced in the prompt's language.

1. ObjectCatalog → 1 hit (Script in `Invoices.fmp12`)
2. Load steps, variables, touched fields, layouts, callers
3. Findings:
   - Touched tables: only `Invoices`, `InvoiceItems`
   - Variables: `$invoiceID`, `$output_pdf_path`
   - Layouts: "Invoice_Print", "Invoice_PDF"
   - Called sub-scripts: "Save PDF", "Print"
   - Callers: Button on "Invoice_Edit", "Batch Print Invoices"
4. Conclusion: "Print / PDF output of a single invoice. Called both manually from invoice editing and from a batch-processing workflow."

### Example 2: Script without meaningful names

**User (flag form)**: "/fm-analyze ScriptXYZ_Util_v2"
**User (English, natural)**: "Analyze ScriptXYZ_Util_v2 briefly"
**User (German, natural)**: "Analysiere ScriptXYZ_Util_v2 kurz"
**User (French, natural)**: "Analyse brièvement ScriptXYZ_Util_v2"

The natural-language variants additionally trigger short mode through the keyword "briefly / kurz / brièvement".

1. Identification OK
2. Steps mainly show `Set Variable`, `Loop`, `Get(...)` expressions
3. Touched fields: none
4. Callers: 23 different scripts in 4 different files
5. Conclusion: "Presumably a utility function without business affiliation — the high and broad reuse indicates a helper (e.g. string processing, date calculation, plausibility check). Without meaningful variables or contact with data fields, the exact purpose cannot be determined from the context. Recommendation: review the step-by-step code via `/fm-summarize`."

### Example 3: Trigger reaction on a field

**User**: "Analyze the field 'Customers::Email'"

1. FieldsForTables returns: AutoEnter Calculated with `AE_Calc_Text = "Lower(Self)"`, Field_Comment = "Email must be lower-cased for unambiguous comparison"
2. ObjectLinks: Displayed on layouts "Customers_Edit" and "Customers_List", read by script "Email_Dispatch"
3. Conclusion: "Stores the customer's email address in normalized (lower-cased) form. The field comment confirms: this serves unambiguous comparison. Actively used in the dispatch workflow."

### Example 4: Ambiguous name

**User**: "Analyze 'Init'"

1. ObjectCatalog → 7 scripts named "Init" in 7 different files
2. **Output**: Offer list, ask which one is meant. Proceed only after the answer.

