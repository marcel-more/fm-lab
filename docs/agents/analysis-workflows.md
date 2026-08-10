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
| "Show me X in FileMaker" | **`fm-open`** |
| "Show me X in FM-Lab / the browser" (detail, references, graph) | **`fm-show`** |
| Lists, counts, cross-references, ad-hoc questions | direct SQL on the master DB |

Prefer the skills over ad-hoc SQL for single-object analyses — they encapsulate
resolution (name → UUID across files) and dependency traversal correctly.

## Standard analysis loop (ad-hoc SQL)

1. **Analyze the question** — which FileMaker object types are relevant?
2. **Identify the matching table(s)** — start from `ObjectCatalog`/`ObjectLinks` for existence & linkage, drill into the type tables for detail (see `schema-reference.md`)
3. **Build the query** — DuckDB SQL; patterns in `query-cookbook.md`, templates in `sql/sample_queries.sql`
4. **Run it** against `db/fm_catalog.duckdb` (master — never the REST-API copy)
5. **Present the result** — understandable prose/tables; Mermaid for relationship visualizations

## Pitfalls that produce wrong conclusions

- **Never regex a `*_XML` column for what `ObjectLinks` already resolves.** `Step_XML`, `Object_XML`, `Parameters_XML` etc. are raw-import payloads, not the query surface. Which fields a script sets/reads (`sets_field`/`reads_field`), which scripts it calls (`calls_script`), which layouts/TOs/variables it touches — all resolved into `ObjectLinks` edges at import. Query the edge (forward pattern in `query-cookbook.md`), or use `fm-summarize`. Raw-XML regex is the **last resort**, justified only for step-exact position or the concrete written value, and only when DDR-Info is absent — with DDR-Info, use the structured step columns (`StepsForScripts.Calculation_Text`, `DDR_ScriptSteps`) first. Rule of thumb: `ObjectLinks`/`LinkRoleRegistry` → `StepsForScripts`/`DDR_ScriptSteps` → `Step_XML` regex, in that order.
- **`LinkRoleRegistry` has no prose column.** It carries `Link_Role`, `Link_Kind`, `Counts_For_Where_Used` — nothing else. `SELECT Link_Role, Description …` fails with a Binder Error. The human-readable meaning of each role is the "Link roles" list in `schema-reference.md`, not a table column.
- **Restriction links are not usage.** `restricts_field`/`restricts_object` (privilege restrictions) must never make an object appear "used". Authoritative flag: `LinkRoleRegistry.Counts_For_Where_Used` — filter on it in dead-code/unused queries instead of hand-picking roles.
- **`Link_Type='structural'` is containment, not usage.** Where-used questions almost always mean `Link_Type='operational'`.
- **Step names are localized.** `StepsForScripts.Step_Name` / `Step/@name` is written in the exporting client's UI language. Match steps via `Step_ID` (`ScriptStepRoleMap`, `step_metadata`), never via name literals.
- **DDR-Info is optional.** `DDR_ScriptSteps`/`DDR_Calculations` are only populated when `XMLMetadata.Has_DDR_INFO = 'True'` — check before relying on formula-chunk analysis; degrade gracefully (see the CASE pattern in `query-cookbook.md`).
- **Non-obvious usage sources still count.** GTRR target TOs, sort value lists, sub-summary break fields, button-embedded steps and privilege-calc references are linked like any other reference — treat every source in the schema as equal (see `schema-reference.md`). If something still looks unused, check the P6 `v_check_*` views before declaring it dead.
- **Local variables are per-script objects.** A `$var` in two scripts is two distinct catalog objects (scope anchor = script). Global `$$`/superglobal `$$$` variables are file-/corpus-wide.
- **Never hand-reconstruct control-flow nesting from sequential steps.** `v_script_block_tree` (materialized) already carries every step's Loop/If depth and block depth — join it for any branch-scope question (is this step inside a loop, which exits are reachable, dead code after `Exit Script`). Reading raw `Step_Index` sequences to re-derive If/Else nesting is slow and error-prone on 500+-step scripts.
- **Multi-calc steps: `Calculation_Text` is only the first slot.** Steps with several calculation slots (window name + geometry, dialog title + message, URL + cURL options, value + repetition) expose all of them in `StepCalculations` with slot context (`Slot`, `Calc_Position`). Asking "which window name does this step set" against `Calculation_Text` is wrong for nameless windows — filter `StepCalculations.Slot = 'Name'` instead.
- **Step counts are not lifecycle proof.** Comparing counts of opening vs. closing steps (`New Window` vs. `Close Window`, transactions, `Freeze Window`) says nothing about whether every exit path actually closes what it opened — `Go to Related Record` can open a window via its "New window" option (`Opens_Window = TRUE`), and a `Close Window [Name: X]` is a no-op when `X` is never produced. Use `Opens_Window`, `StepCalculations` and `v_script_block_tree` for a real path argument.
- **Platform compatibility is a lookup, not a memory.** Whether a step runs on FileMaker Server/WebDirect/Go: `reference/fm_spec.duckdb → step_compat` (read-only; NULL = "Claris states nothing", not "compatible"). Never assert server behavior of a step without this lookup.
- **God-nodes are filtered only in clustering.** `ClusterEdges` drops cross-cutting god-nodes; `LogicalLinks` and where-used keep them.
- **`New Window`/`Close Window` counts balancing is necessary but not sufficient.** A script can have `n_new = n_close` (or even more closes than opens) and still leak a window on a specific execution path — counting only proves the totals match somewhere, not that every window opener is followed by a `Close Window` *before every reachable `Exit Script`*. This matters most in loop bodies that call a heavy sub-script per iteration (print/export/batch scripts): a leaked window per iteration silently corrupts the caller's own window/found-set state (see below) without ever throwing a script error.
  - **A window can open without a `New Window` step at all.** `Go to Related Record` has its own `New window` checkbox (rendered in `DDR_ScriptSteps.Step_Text`/`Step_XML` as `[ Show only related records; New window ]`, `Step_Name = 'Go to Related Record'`, *not* `'New Window'`). A `Step_Name = 'New Window'` filter alone will silently miss these — search the step **text**, not just the step name, e.g. `d.Step_Text ILIKE '%New window%'` in addition to `s.Step_Name = 'New Window'`. Other steps with the same trap: `Open File`, `Perform Script` variants that can target a new window in some FileMaker versions — when in doubt, grep `Step_XML`/`Step_Text` for `new window`/`newwindow` rather than trusting `Step_Name` alone.
  - **Dead cleanup code after an unconditional `Exit Script` is a distinct, very common bug shape.** A `Close Window`/cleanup step placed *after* an `Exit Script` within the same `If`-branch is unreachable — the branch terminates before it. This is easy to miss on a quick read because the cleanup step is *textually present* (a reviewer skimming for "is there a Close Window here?" sees one and moves on) but never actually executes. Concretely check, for every `Exit Script`, whether any step immediately follows it *inside the same End-If scope* — if so, that step is dead code, full stop, regardless of what it does.
  - **How to check it properly**: for every window-opening step (by name *or* by option text) in a script, list all steps between it and the next `End Script`/end-of-script, and confirm that **every** `Exit Script` reachable from that point (including ones inside nested `If`/`Else If` branches) is preceded, within the *same* `If`-scope, by a `Close Window` that unconditionally executes before reaching it — and verify no such `Close Window` is itself dead code per the point above. Do this by reading the raw sequential step list (`Step_Index`, `Step_Name`, `Is_Enabled`) and manually counting `If`/`Else If`/`Else`/`End If` depth — `StepsForScripts` has no indent/nesting column, so nesting must be reconstructed by reading step order, not assumed from a raw new/close tally.
  - **Why this matters for loops**: window-opening steps that run *inside* a loop over records are the highest-risk spot — a single un-closed window per iteration accumulates one leaked window per record, and (per FileMaker's per-window found-set caching) can silently replace the *caller's own* found set with an unconstrained one once the leaked window becomes the active window — with no error the caller would ever see. Prefer to cross-check against a live log/window count (`Get(WindowNames)` before/after the call) when static reading of a large nested call chain (100+ steps, multiple sub-scripts) is not conclusive — cross-file/deeply-nested control flow is easy to mis-count by hand, and a single missed step-text match (not just step name) is enough to hide the real leak.

## Graph & module analysis

- `LogicalLinks` — cleaned operational graph (Explorer/where-used view)
- `ClusterEdges` — clustering edge set (single source of truth for community detection)
- `fm-graph-cluster` sweeps resolutions, names communities semantically (`CommunityNames.Semantic_Name`), writes a report to `output/` and syncs the partition to the Graph Explorer
- After `convert-xml --force-rebuild` the cluster layer is wiped → re-run `fm-graph-cluster`

## Consistency & quality checks

- P6 check views `v_check_*` surface unresolved references, uncurated step IDs, absorbed duplicates etc. — query them when an analysis result looks implausible.
- The converter quality test suite lives in `tools/tests/quality/` (data-driven E2E check catalog).
