# Analytic Workflows — Skills, Patterns & Pitfalls

> Referenced from CLAUDE.md §5. How to run FileMaker solution analyses:
> which skill for which question, canonical SQL patterns, and the traps
> that produce wrong conclusions.

## Supported task classes

You support the developer in typical analysis steps on their FileMaker application:
- Questions about object lists
- Questions about individual objects, their constituents and their links within the application
- Questions about dependencies between same or different objects
- Questions about missing links or orphaned objects
- Questions about the context in which an object is used
- Visualization of relationships as text lists or Mermaid diagrams

## Skill selection

| Question shape | Tool |
|---|---|
| "Describe script/field/layout X" (technical: structure, flow, dependencies) — incl. which fields a script sets/reads, which scripts it calls, which layouts/variables it touches (grouped by Link_Role) | **`fm-summarize`** (`--short` for 1–2 paragraphs) |
| "What is X *for*? What business logic is behind X?" (semantic: call chain, triggers, naming, comments of linked objects) | **`fm-analyze`** (`--short` available) |
| "Which modules does this solution consist of?" / community & hub analysis | **`fm-graph-cluster`** |
| "Describe this solution as a whole" — purpose, architecture, technical build, findings, recommendations (onboarding, takeover, technical-debt review) | **`fm-deep-research`** (report to `output/`; asks to run `fm-graph-cluster` first when no swept partition exists) |
| "Is something wrong with this script/object?" — and symptom entries: *hangs · slow · wrong results · unexpected behavior · escalating calls* | **`fm-test`** (curated Analysis Tests: bundled SCA rules & queries, findings-based result; `--find` for discovery) |
| "How does this hang together?" — call chains, reachability, window lifecycle, platform context | **analysis patterns** → `analysis-patterns.md` (documented procedures with canonical SQL; not executable tests) |
| "Show me X in FileMaker" | **`fm-open`** |
| "Show me X in FM-Lab / the browser" (detail, references, graph) | **`fm-show`** |
| Lists, counts, cross-references, ad-hoc questions | direct SQL on the master DB |

Prefer the skills over ad-hoc SQL for single-object analyses — they encapsulate
resolution (name → UUID across files) and dependency traversal correctly.
When a question matches a test or a pattern, *offer* it — tests deliver
reproducible, curated checks; `fm-analyze`/`fm-summarize` deliver free interpretation.

## Standard analysis loop (ad-hoc SQL)

1. **Analyze the question** — which FileMaker object types are relevant?
2. **Identify the matching table(s)** — start from `ObjectCatalog`/`ObjectLinks` for existence & linkage, drill into the type tables for detail (see `schema-reference.md`)
3. **Build the query** — DuckDB SQL; patterns in `query-cookbook.md`, templates in `docs/agents/sql/sample_queries.sql`
4. **Run it** against `db/fm_catalog.duckdb` (master — never the REST-API copy)
5. **Present the result** — understandable prose/tables; Mermaid for relationship visualizations

## Pitfalls that produce wrong conclusions

- **Never regex a `*_XML` column for what `ObjectLinks` already resolves.** `Step_XML`, `Object_XML`, `Parameters_XML` etc. are raw-import payloads, not the query surface. Which fields a script sets/reads (`sets_field`/`reads_field`), which scripts it calls (`calls_script`), which layouts/TOs/variables it touches — all resolved into `ObjectLinks` edges at import. Query the edge (forward pattern in `query-cookbook.md`), or use `fm-summarize`. Raw-XML regex is the **last resort**, justified only for step-exact position or the concrete written value, and only when DDR-Info is absent — with DDR-Info, use the structured step columns (`StepsForScripts.Calculation_Text`, `DDR_ScriptSteps`) first. Rule of thumb: `ObjectLinks`/`LinkRoleRegistry` → `StepsForScripts`/`DDR_ScriptSteps` → `Step_XML` regex, in that order.
- **`LinkRoleRegistry` has no prose column.** It carries `Link_Role`, `Link_Kind`, `Counts_For_Where_Used` — nothing else. `SELECT Link_Role, Description …` fails with a Binder Error. The human-readable meaning of each role is the "Link roles" list in `schema-reference.md`, not a table column.
- **Restriction links are not usage.** `restricts_field`/`restricts_object` (privilege restrictions) must never make an object appear "used". Authoritative flag: `LinkRoleRegistry.Counts_For_Where_Used` — filter on it in dead-code/unused queries instead of hand-picking roles.
- **Script triggers count once — via the owner mirror.** A script trigger is represented twice in `ObjectLinks`: the counting owner mirror `triggers_script·<event>` (LayoutObject/Layout/File → Script; all three owner levels since converter 2.17.0) and the granular `trigger_script` edge of the ScriptTrigger node (`Counts_For_Where_Used=FALSE` since 2.17.0 — navigation/detail only). Counting both roles double-counts every trigger; "which scripts does layout/file X trigger?" is now a direct `triggers_script` query on the owner, no hop over the trigger node needed. On pre-2.17.0 catalogs the mirror exists only on the object level and `trigger_script` still counts — check `LinkRoleRegistry` instead of assuming.
- **`Link_Type='structural'` is containment, not usage.** Where-used questions almost always mean `Link_Type='operational'`.
- **Step names are localized.** `StepsForScripts.Step_Name` / `Step/@name` is written in the exporting client's UI language. Match steps via `Step_ID` (`ScriptStepRoleMap`, `step_metadata`), never via name literals.
- **DDR-Info is optional.** `DDR_ScriptSteps`/`DDR_Calculations` are only populated when `XMLMetadata.Has_DDR_INFO = 'True'` — check before relying on formula-chunk analysis; degrade gracefully (see the CASE pattern in `query-cookbook.md`).
- **Non-obvious usage sources still count.** GTRR target TOs, sort value lists, sub-summary break fields, button-embedded steps and privilege-calc references are linked like any other reference — treat every source in the schema as equal (see `schema-reference.md`). If something still looks unused, check the P6 `v_check_*` views before declaring it dead.
- **Local variables are per-script objects.** A `$var` in two scripts is two distinct catalog objects (scope anchor = script). Global `$$`/superglobal `$$$` variables are file-/corpus-wide.
- **Never hand-reconstruct control-flow nesting from sequential steps.** `v_script_block_tree` (materialized) already carries every step's Loop/If depth and block depth — join it for any branch-scope question (is this step inside a loop, which exits are reachable, dead code after `Exit Script`). Reading raw `Step_Index` sequences to re-derive If/Else nesting is slow and error-prone on 500+-step scripts.
- **Multi-calc steps: `Calculation_Text` is only the first slot.** Steps with several calculation slots (window name + geometry, dialog title + message, URL + cURL options, value + repetition) expose all of them in `StepCalculations` with slot context (`Slot`, `Calc_Position`). Asking "which window name does this step set" against `Calculation_Text` is wrong for nameless windows — filter `StepCalculations.Slot = 'Name'` instead.
- **Step counts are not lifecycle proof.** Comparing counts of opening vs. closing steps (`New Window` vs. `Close Window`, transactions, `Freeze Window`) says nothing about whether every exit path actually closes what it opened — `Go to Related Record` can open a window via its "New window" option (`Opens_Window = TRUE`), and a `Close Window [Name: X]` is a no-op when `X` is never produced. Use `Opens_Window`, `StepCalculations` and `v_script_block_tree` for a real path argument.
- **Platform compatibility is a lookup, not a memory.** Whether a step runs on FileMaker Server/WebDirect/Go: `reference/fm_spec.duckdb → step_compat` (read-only). The Claris table is tri-state — `Yes`/`No`/`Partial` — and the BOOLEAN columns lose the third value: **NULL = "Partial — conditionally supported, see the step's help page", never "undocumented" and never "compatible"**. Report NULL as "partially supported (see Claris notes)" and deep-link the step's doc (`script_steps.url_slug`); a genuinely missing row (only 6× `dataapi`/`cwp`) is the "no statement" case. Never assert platform behavior of a step without this lookup.
- **Platform-specific ≠ incompatible.** Two orthogonal platform axes: *compatibility* ("can this run under X?" — findings are obstacles: error/warning) and *platform binding* ("was this built for X?" — a neutral inventory: iOS-exclusive steps, iOS-dedicated functions, PSoS execution context, OS-bound plug-in functions; severity always `info`). An iOS-bound script failing the Server compatibility check is not broken — it was built for another platform; say so instead of reporting a defect. Binding evidence exists for iOS (features — incl. dedicated functions reached through custom functions), Server (context) and the OS sub-axis (plug-in platform map) — for the remaining environments no signal source exists, and none is invented. Since schema 1.20.0 the PSoS distinction is ON the edge: `calls_script` with `Link_Subrole IN ('on_server','on_server_callback')` marks server-side executed targets — query the edge, no `Step_XML` regex needed. "By name" PSoS callsites (runtime-computed target) have no edge; their expression is in `StepCalculations` (Slot `List` on steps 164/210). Pre-1.20.0 catalogs lack the subrole — rebuild before relying on it.
- **OS axis (fm_spec ≥ 1.13.0) — four traps.** (1) **"Windows" ≠ windows:**
  in Claris prose, capitalized "Windows" is usually *window objects* ("Arrange
  All Windows", "closes all windows") — the OS affinity is CURATED
  (`step_os_affinity`/`function_os_affinity`, quote per row); never grep doc
  prose or step names for OS words. (2) **`unsupported` resolves against the
  host-OS set of the object's runtimes** (`step_compat` × `runtime_os_matrix`,
  Partial/NULL = potentially running), never against all four OS: Dial Phone
  "not supported in macOS" ⇒ windows+ios, NOT linux. (3) **Send Event is
  `variant`, not `exclusive`:** one step id with two OS-exclusive option sets
  (macOS: Apple events, Windows: DDE/application actions) — it exists on both
  desktop OS, but a configuration made for one does nothing useful on the
  other (`os_profile='desktop-variant'`). (4) **`ios` is the operating
  system**, hosting FileMaker Go AND Claris iOS SDK apps — runtime terms
  (`go`, `ios_sdk`) never appear in an OS column; the plug-in map folds
  `ios_sdk` → `ios` with qualifier `sdk-only` (Go supports no plug-ins, so
  ios-via-plugin is always the SDK). Absence of an affinity row = "Claris
  states nothing", never "runs everywhere".
- **Plug-in platform evidence — four traps.** (1) **iOS SDK ≠ Go:** the MBS `ios_sdk` axis covers Claris iOS SDK apps; FileMaker Go supports *no* plug-ins at all (generic rule) — never feed the `ios_sdk` flag into a Go statement. (2) **Resolve old names first:** MBS renames functions and old names stay callable — match catalog names against `plugref.plugin_functions` *and* `plugref.plugin_function_aliases` (case-insensitive); a known plugin without a doc hit is an explicit "unresolved" finding, never a silent drop. (3) **Misclassified PluginFunction rows:** a handful of catalog `PluginFunction` rows are German design functions without `::` in the name — filter every plug-in analysis with `Object_Name LIKE '%::%'`. (4) **Version comparisons never run on the version string** — `max(since_version)` returns "9.5" over "11.5" ("9" > "1" lexically); always compare/aggregate on `since_version_num` (major\*1000+minor, since plugin_spec 1.2.0) and display the string via `arg_max(since_version, since_version_num)`. Semantics reminder: MBS flags are **binary with MBS authority**; they never share the Claris tri-state `step_compat` semantics (NULL = Partial exists only there).
- **God-nodes are filtered only in clustering.** `ClusterEdges` drops cross-cutting god-nodes; `LogicalLinks` and where-used keep them.
- **Clone corpora: cross-file targets follow a resolution doctrine, not UUID luck.** In cloned/modular solutions (`Save a Copy as…`) the same `Object_UUID` exists in several files; object identity is the pair `(Object_UUID, File_Name)`. P4 resolves each operational edge's target file in a fixed ladder: declared data source (`DataSourceFileMap` — per-TO for `base_table`, per source file for the generic prefer-declared-source pass) → prefer-local → keep-cross-file (canonical order documented at the prefer-local DELETE in `convert_xml_04_catalog.sql`). Edges that fan over multiple target files after import are the honest residue — the source file declares none or several of the candidate files as a data source. They are listed in `v_check_phantom_links` (`undeclared_groups`/`multi_declared_groups`); a non-zero `declared_one_groups` is a converter defect. Don't "fix" such fans in analysis queries by picking a file yourself — report the ambiguity.

## Graph & module analysis

- `LogicalLinks` — cleaned operational graph (Explorer/where-used view)
- `ClusterEdges` — clustering edge set (single source of truth for community detection)
- `fm-graph-cluster` sweeps resolutions, names communities semantically (`CommunityNames.Semantic_Name`), writes a run protocol to `output/`, persists the granularity (`solutions/<id>/state/cluster.json`) and syncs the partition to the Graph Explorer
- `fm-deep-research` reads the members of the largest communities and writes the solution report (`Semantic_Description` for scanned segments); it needs a partition at the sweep granularity — the shared `.claude/skills/_shared/scripts/cluster_state.sh` reports the readiness level (L0 none / L1 raw or drifted / L2 swept)
- After `convert-xml --force-rebuild` the cluster layer is wiped → re-run `fm-graph-cluster`; a bare `cluster.sh` run now re-uses `cluster.json`, so the granularity survives

## Consistency & quality checks

- P6 check views `v_check_*` surface unresolved references, uncurated step IDs, absorbed duplicates etc. — query them when an analysis result looks implausible.
- The converter quality test suite lives in `tools/tests/quality/` (data-driven E2E check catalog) — it tests the import pipeline, **not** the solution; solution checks are the Analysis Tests (`fm-test`, format & API → `analysis-tests.md`).
