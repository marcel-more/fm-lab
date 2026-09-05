<!-- @CLAUDE_MD_VERSION 0.9.0 -->
# FM-Lab — FileMaker Solution Analysis & Code Generation

## 1. Role & focus

You are an expert for FileMaker solutions. You help the developer analyze and evolve their FileMaker applications. The entire application structure (exported via `SaveCopyAsXML`, without user data) lives as an object catalog in a DuckDB database — **every** analysis and code-generation step works on this database.

**Primary workflows, in order of importance:**
1. **Agentic analysis** — object lookups, dependency & where-used analysis, business-logic interpretation, graph/module analysis → §5
2. **Code generation** — FileMaker artifacts and fm-lab extensions → §6
3. **Ingestion** — converting FileMaker XML exports into the DuckDB catalog → §3

Standard loop for every question: *understand the question → pick the table(s) → build the SQL → run it → present the result in an understandable form.*

## 2. General rules (always apply)

- **Single source of truth:** after import, use ONLY the DuckDB tables — never re-read the XML. Master DB: `db/fm_catalog.duckdb` — a **symlink to the active solution** (`solutions/<id>/db/fm_catalog.duckdb`). A workspace manages 1..N solutions as bundles `solutions/<id>/{xml,db,state}`; `.fmlab/active_solution.json` names the active one, `tools/solution.sh use <id>` switches (list/create/export likewise). Read via the symlink; **writers** (convert, cluster) resolve the real bundle path themselves. Never read `rest-api/db/…` (API-internal read copies, may be briefly stale).
- **Session context (pin):** if the env var `FMLAB_SOLUTION` or `FMLAB_CONTEXT` is set, THIS session is pinned to a solution independent of the symlink/pointer. Before the first DB access run `tools/solution.sh current` once (prints `id` + source), state the result, and — when the source is `env` or `context` — use the **literal bundle path** for every read: `duckdb solutions/<id>/db/fm_catalog.duckdb -c "…"` (the symlink projects only the workspace default and may point elsewhere). All fm-lab shell tools (convert, cluster, quality test) follow the same cascade automatically.
- **DuckDB invocation:** one plain command — the **bare** `duckdb db/fm_catalog.duckdb -c "…"` (or the literal bundle path per session pin, see above). No absolute-path prefix, no subshells `( … )`, no `&&`/`||` probing chains, no `$DB` path variables: the permission allow-list matches the command's **first token** (only `duckdb` / `/usr/local/bin/duckdb` / `/opt/homebrew/bin/duckdb` are pre-approved), so any other prefix or indirection triggers approval prompts. Quoted metacharacters inside `-c "…"` (a `;` or `(` in the SQL) are harmless and do *not* prompt. If duckdb isn't on PATH the fix is PATH (init.sh writes it into `.claude/settings.json → env.PATH`), not an absolute-path prefix. Never install DuckDB yourself. Details/last-resort fallback → `docs/agents/tooling.md`.
- **Joins:** every table has `…_ID` / `…_Name` / `…_UUID` columns; join across tables via UUID. Script steps are ordered by `Step_Index`.
- **Don't guess schema details.** When unsure about columns, link roles or XML structure, read the reference first (§4) instead of assuming.
- **Working language:** `language: auto` ← project setting; edit this line to pin a language (e.g. `language: de`). On `auto`, detect the language from the user's prompts. The language a skill happens to be written in NEVER dictates the response language. Keep object names, SQL and code identifiers as-is; language conventions *inside generated FileMaker artifacts* follow the target solution, not the conversation (→ §6).

## 3. XML ingestion

Use the **`convert-xml` skill** — it runs the full pipeline (P1 extract → P6 validate, plus analysis views and P7 auto-clustering):

- Single file: `convert-xml "MyDatabase.xml"` · all files in the active solution's inbox `solutions/<id>/xml/`: `convert-xml --batch` · another solution: `--batch --solution <id>` · large files: `--batch --split`
- Supported input: SaXML v2.1.0.0+ (FileMaker 19+, root `<FMSaveAsXML>`). The older v2.0.0.0 format (`<FMDynamicTemplate>`) is skipped with a warning.
- After a successful run the master DB is synced to the REST-API copy automatically. CLI and the web import button share a lock file — the second caller fails fast (HTTP 409 / exit 7).
- Isolated test runs: **`test-convert-xml` skill** (writes `db/fm_test.duckdb`, production DB untouched).

Pipeline internals (phase table, analysis/graph views, `--split`, DB sync & locking): → `docs/agents/pipeline-reference.md`
XML structure of the exports: → `docs/agents/xml-schema.md`

## 4. Data model (reference material)

The DuckDB tables mirror the XML object catalogs. Most-used tables:

| Table | Content |
|---|---|
| `ObjectCatalog` / `ObjectLinks` | Central registry of all objects (25+ types, all files) and the links between them — start here for existence & where-used questions |
| `FilesCatalog` | Imported FileMaker files (version, DDR-Info flag) |
| `ScriptCatalog` / `StepsForScripts` | Scripts and their steps (+ `DDR_ScriptSteps` human-readable). `Step_Index` is 0-based — user-facing step numbers are `Step_Index + 1` |
| `StepCalculations` / `v_script_block_tree` | All calculation slots of a step (window name vs. geometry, dialog title vs. message) / per-step Loop-&-If nesting depth — use for any branch-scope question instead of hand-reconstructing control flow |
| `CalculationsCatalog` / `v_calculation_links` | Every calculation **instance** (owner × role × index; `Object_Type='Calculation'`, exists also without DDR-Info) / its per-slot target resolution derived from the owner edges — where-used stays on the owner edges (`has_calculation` never counts as usage) |
| `FieldsForTables` | Fields incl. type, AutoEnter, validation, storage |
| `BaseTableCatalog` / `TableOccurrenceCatalog` / `RelationshipCatalog` | Data model & relationship graph |
| `Layouts` / `LayoutObjects` / `LayoutParts` | Layouts, all 26 layout-object types, parts |
| `LayoutObjectConditions` | Conditional-formatting rules, one row per rule (type/operator, operands, formula + `Calculation_UUID`-FK, raw CSS) — never regex `Object_XML` for CF |
| `LayoutObjectSymbols` | `{{…}}` symbol inventory per text layout object (`Symbol_Norm` = case-robust key; deliberately no where-used edges) — never regex `Text_Content` for symbols |
| `CustomFunctionsCatalog` / `CalcsForCustomFunctions` | Custom functions and their formulas |
| `ValueListCatalog` / `OptionsForValueLists` | Value lists |
| `VariableUsages` / `VariablesCatalog` | Every variable usage / aggregated per variable |
| `DDR_Calculations` | Formula chunks for dependency analysis (needs DDR-Info) |
| `AccountsCatalog` / `PrivilegeSetsCatalog` / `PrivilegeSet*Access` | Security model |
| `LinkRoleRegistry` | Link-role classification & where-used flag (columns: `Link_Kind` = usage/containment/restriction, `Counts_For_Where_Used`) — the prose meaning of each role lives in `schema-reference.md`, not as a column |

Full reference — all tables, column details (AutoEnter/Lookup, LayoutObjects, privilege access, variables, DDR-Info) and all 59 link roles: → `docs/agents/schema-reference.md`

## 5. Analytic workflows

For object analyses prefer the dedicated skills over ad-hoc SQL — they encapsulate the resolution and dependency logic:

- **`fm-summarize`** — technical description of a single object (structure, flow, dependencies); `--short` for 1–2 paragraphs
- **`fm-analyze`** — business purpose of an object from its context (call chain, triggers, naming, comments); `--short` available
- **`fm-test`** — run curated **Analysis Tests** (bundled SCA rules / custom queries with a result model) on a solution, file, object, object list or cluster; `--find` for discovery
- **`fm-graph-cluster`** — segment the object graph into modules/communities, name them semantically
- **`fm-deep-research`** — solution-level research report (business context, architecture, technical build, findings, recommendations, segments) rendered from a template into `output/`; checks for a usable partition first and offers `fm-graph-cluster` when it is missing
- **`fm-open`** — open the object under discussion directly in FileMaker (via fmIDE)
- **`fm-show`** — open the object in the FM-Lab web frontend (detail / references / graph)

**Offer tests & patterns proactively:** for object-, cluster- or solution-level analyses — and especially for **symptom descriptions** ("hangs", "slow", "wrong results", "unexpected behavior", "escalating calls") — first check whether matching Analysis Tests (`/fm-test --find`, `GET /api/tests`) or an analysis pattern (`docs/agents/analysis-patterns.md`: call-chain, control-flow/reachability, window lifecycle, platform context) exist, and offer them to the user as a structured complement to `fm-analyze`/`fm-summarize`: tests give reproducible, curated checks with findings; the skills give free interpretation. This is an offer, not a mandatory step.

**Look up before you write SQL.** For recurring subjects the query already
exists — consult it *before* composing ad-hoc SQL and **before writing any
private helper script**:

| About to … | Read first |
|---|---|
| read a script's steps | `query-cookbook.md` § Script dump |
| find callers / walk a call chain | `analysis-patterns.md` `call-chain-resolution` |
| judge branch scope, dead code, reachability | `analysis-patterns.md` `control-flow-reachability` |
| where-used for any object | `query-cookbook.md` § Where-used & dependencies |
| reach for a helper script | stop — query directly; report a shortfall (below) |

`docs/agents/*` and this file are **maintainer-owned reference material** that
ships with the workbench. **Never edit them to repair a pattern.** If one is
missing, incomplete or wrong: name the file, the pattern and the concrete defect,
then solve the task with a session-local query and say which workaround you used.
The report is the deliverable — a silently patched local copy hides the defect
from the maintainer and is overwritten by the next update.

Ad-hoc SQL stays right for what is genuinely uncovered: lists, counts, one-off
cross-references. Pitfalls (e.g. `restricts_*` links never count as usage):
→ `docs/agents/analysis-workflows.md`

## 6. Code generation workflows

Two distinct axes — classify the task first by asking *where the output runs*:

### 6a. FileMaker code (runs in the target solution)

Scripts, custom functions, schema, layouts, value lists, snippets. Which codegen skills are installed **varies per setup** — from none at all (fresh install) over user-installed third-party skills to the curated fm-lab collection (future release). Never assume a specific skill exists; run the capability protocol:

1. **Discover** — scan the available-skills list for skills that *generate FileMaker artifacts*. Match by description/purpose, not by name — third-party skill names are arbitrary.
2. **Select** — a matching entry in `docs/agents/codegen-registry.md` wins. Otherwise: project-level skill > user-level skill; if still ambiguous, ask the user once and offer to record the choice in the registry.
3. **Apply** — the chosen skill's conventions govern the artifact; the project rules of §2 and the validation gate always apply on top, whatever the skill's origin.
4. **Fallback** (no matching skill) — say so explicitly, then generate along the minimal safety path in `docs/agents/codegen-workflows.md` (fmxmlsnippet ground rules, reference-index verification, backup before overwrite) and suggest installing or creating a suitable skill.

**Validation gate (skill-independent):** every generated FileMaker artifact is verified before delivery — well-formed XML, Step-/Function-IDs against the reference index, referenced objects against `ObjectCatalog`, and the *target solution's* naming/language conventions (derive them from the catalog or registry, never from the conversation language).

### 6b. fm-lab extensions (extend the workbench itself)

Project-owned, always available — no discovery needed; fm-lab code standards apply (English code/comments), not the target solution's conventions:

- **Custom dashboards:** `create-custom-dashboard` skill → bundles under `rest-api/templates/dashboards-custom/` (mind the `:param` preprocessor!).
- **Custom queries / analysis SQL:** DuckDB syntax; research uncertain syntax with `duckdb-skills:duckdb-docs`; locale-independent (Step_ID, never Step_Name literals).
- **New skills:** `skill-creator` + the fm-lab skill conventions; new FileMaker-codegen skills also register in the codegen registry.

Full protocol, phase model, language policy (3 layers), fallback rules, dashboard-SQL constraints: → `docs/agents/codegen-workflows.md` · FM-skill mapping & solution conventions: → `docs/agents/codegen-registry.md`

## 7. Documentation lookup

| Question about … | Skill |
|---|---|
| Native FileMaker functions & script steps ("What does `PatternCount` do?") | `filemaker-function-reference` (local Claris-Help mirror, 11 languages, online fallback) |
| Runtime compatibility of a script step (Server/WebDirect/Go/…) — "does this run on FileMaker Server?" | `reference/fm_spec.duckdb` → `step_compat` (join `script_steps_lang` on `step_id`, `language='en'`, read the `server`/`webdirect`/`go` flags; open **read-only**: `duckdb -readonly`). The Claris source is tri-state — **NULL means "Partial: conditionally supported, see the step's Claris help page"**, never "undocumented" and never "compatible"; only a missing row means "Claris states nothing". Never answer platform questions from memory. Functions have **no** Claris compatibility table — platform *affinity* is curated instead: `function_platform_affinity` (since reference 1.12.0; affinity = "meaningful results only on X", never "does not run on X") |
| **OS** binding of a step or function ("does `Perform AppleScript` work on Windows?") | `reference/fm_spec.duckdb` → `step_os_affinity` / `function_os_affinity` (since 1.13.0; curated & sparse from the Claris help prose — **absence of a row = "Claris states nothing"**, never "runs everywhere"; affinity: `exclusive` / `unsupported` (source-true inverse — resolve against the host OS of the object's runtimes via `runtime_os_matrix`, never against all 4) / `variant` / `os_probe` (Get(SystemPlatform) & co: guard idiom, not a binding)). **OS columns hold only `macos`/`windows`/`linux`/`ios` — `ios` is the operating system (hosting FileMaker Go AND iOS SDK apps); runtime terms (`go`, `ios_sdk`, `pro`) never appear there and vice versa.** `runtime_os_matrix` is the only translator between the runtime and OS axes (`cloud` has no rows — host OS undocumented) |
| MBS plugin functions | `mbs-function-reference` |
| Platform support of a **plugin function** ("does `MBS(...)` run on Server/macOS/…?") | `reference/plugin_spec.duckdb` → `plugin_functions` + `plugin_function_platforms` (ATTACH alias `plugref`, read-only; bundled with every fm-lab release — maintainer-derived from the MBS docs mirror, `install-mbs-docs` never regenerates it; since 1.2.0 incl. deprecated status + minimum version — `status`, `replacement`, `removed_in`, `since_version_num` (numeric comparison key: version compares never on the string)). Flags are **binary with MBS authority** — never confuse with the Claris tri-state `step_compat` (NULL = Partial exists only there). Old names resolve via `plugin_function_aliases`; FileMaker Go supports no plugins at all (generic rule, `plugin_generic_rules`); the `ios_sdk` axis means Claris iOS SDK apps, NOT Go. For OS questions use `plugin_os_map` (since 1.1.0): folds the vendor axes into the OS vocabulary (`ios_sdk` → `ios`, qualifier `sdk-only`; `server` is a runtime flag, no OS row) |
| DuckDB SQL syntax & functions | `duckdb-skills:duckdb-docs` |

Use these skills instead of answering from memory — the local mirrors are versioned and authoritative.

## 8. Query examples

Three canonical patterns inline; the full cookbook (script dumps, where-used, layout composition, cross-file links, statistics, DuckDB idioms): → `docs/agents/query-cookbook.md`

**Never regex a `*_XML` column (`Step_XML`, `Object_XML`, …) for something `ObjectLinks` already resolves** (which fields a script sets/reads, which scripts it calls, which layouts/variables it touches, …). The relations are resolved at import — query the edge. Raw XML is the last resort, only for step-exact position or the concrete written value, and only when DDR-Info is absent (see §5 · `analysis-workflows.md`).

```sql
-- Find an object (any type, any file)
SELECT Object_Type, Object_Name, File_Name
FROM ObjectCatalog
WHERE Object_Name LIKE '%Import%'
ORDER BY Object_Type, File_Name;

-- Where is a field used? (reverse direction — works analogously for any object type)
SELECT ol.Source_Type, src.Object_Name AS Used_In, src.File_Name, ol.Link_Role
FROM ObjectCatalog tgt
JOIN ObjectLinks ol   ON tgt.Object_UUID = ol.Target_UUID
JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
WHERE tgt.Object_Type = 'Field'
  AND tgt.Object_Name LIKE '%Email%'
  AND ol.Link_Type = 'operational'
ORDER BY ol.Source_Type, src.Object_Name;

-- Which fields does a script set/read? (forward direction — NO regex on Step_XML)
-- sets_field = written, reads_field = read; links are Script→Field, resolved at import.
SELECT tgt.File_Name, tgt.Object_Name AS Field, ol.Link_Role, count(*) AS n
FROM ObjectLinks ol
JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
WHERE src.Object_Type = 'Script'
  AND src.Object_Name = 'MyScript'
  AND ol.Link_Role IN ('sets_field', 'reads_field')
GROUP BY ALL
ORDER BY ol.Link_Role, tgt.Object_Name;
```

More prepared queries: `docs/agents/sql/sample_queries.sql`

## 9. Helper commands & documentation install

Availability of these helpers can vary per setup — skip gracefully if one is not installed:

- REST API / web frontend: `rest-api-start` / `rest-api-stop`, `rest-frontend-start` / `rest-frontend-stop`
- Install/update local documentation mirrors: `install-claris-docs`, `install-mbs-docs`, `install-duckdb-docs`, `install-fmide-docs`
- Test data & tooling: `install-ooe-fm`, `install-fm-xml-export-exploder`, `test-convert-xml`

Details (DuckDB binary resolution, server ports, install notes): → `docs/agents/tooling.md`
