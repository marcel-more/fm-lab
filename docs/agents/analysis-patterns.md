# Analysis Patterns — Registry

> Referenced from CLAUDE.md §5 and `analysis-workflows.md` ("Skill selection").
>
> A **pattern** is a documented procedure for a typical investigation subject —
> prose + canonical SQL building blocks. It is **not** a test (no execution
> semantics, no result model) and **not** a skill (no trigger machinery). Use a
> pattern when the question is a *reconstruction* task ("how does this hang
> together?"), use an Analysis Test (`fm-test`, `GET /api/tests`) when the
> question is a *check* ("is something wrong with this?"). Patterns reference
> the canonical queries in `query-cookbook.md` and the rule bundles instead of
> carrying private SQL copies — one truth per query.
>
> Extending this registry = adding an entry below. No code, no schema object,
> no API. Every entry MUST fill "Related tests" (even if "none yet").

Entry format: `pattern_id` · Question forms · Object types · Procedure ·
SQL building blocks · Traps · Related tests.

---

## `call-chain-resolution`

**Question forms:** "who calls X / what does X call?", "where does this chain
start?", "escalating calls", "does this recurse?", symptom entries like
"hangs" or "runs twice".

**Object types:** Script, Layout, LayoutObject.

**Procedure:**
1. **Entry points are three roles, not one.** Collect callers via
   `ObjectLinks.Link_Role IN ('calls_script', 'trigger_script', 'triggers_script')`
   — script→script calls, scripttrigger sources, and layout-object trigger
   sources. Who only follows `calls_script` misses layout and object triggers.
   (Structural containment `parent_script` is hierarchy, not a call.)
2. **Walk the chain** with a recursive CTE carrying a path array for cycle
   detection (no extension, no `CYCLE` clause needed).
3. **The edge is context-free.** `ObjectLinks` has *no step anchor* and
   `Link_Subrole` is NULL for all three roles — the edge cannot tell you which
   step calls, whether it is `Perform Script` (Step_ID 1), `Perform Script on
   Server` (164) or PSoS-with-callback (210), nor whether the call sits inside
   a loop or under a condition. For execution context use the **step-based
   second path**: `v_script_block_tree WHERE Step_ID IN (1, 164, 210)` (loop/If
   depth per call site), callee resolved separately.
4. Step 164/210 marks a **server boundary** — the callee subtree runs
   server-side (relevant for the `platform-context` pattern).

**SQL building blocks:**

```sql
-- Callers across all three entry roles
SELECT src.Object_Type, src.Object_Name, src.File_Name, ol.Link_Role
FROM ObjectCatalog tgt
JOIN ObjectLinks ol   ON tgt.Object_UUID = ol.Target_UUID
JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
WHERE tgt.Object_Type = 'Script' AND tgt.Object_Name = '<script>'
  AND ol.Link_Role IN ('calls_script', 'trigger_script', 'triggers_script');

-- Downward chain with cycle guard (path array)
WITH RECURSIVE chain AS (
  SELECT ol.Source_UUID, ol.Target_UUID, 1 AS depth,
         [ol.Source_UUID, ol.Target_UUID] AS path
  FROM ObjectLinks ol
  WHERE ol.Link_Role = 'calls_script' AND ol.Source_UUID = '<uuid>'
  UNION ALL
  SELECT c.Source_UUID, ol.Target_UUID, c.depth + 1,
         list_append(c.path, ol.Target_UUID)
  FROM chain c
  JOIN ObjectLinks ol ON ol.Source_UUID = c.Target_UUID
  WHERE ol.Link_Role = 'calls_script'
    AND NOT list_contains(c.path, ol.Target_UUID)
    AND c.depth < 8
)
SELECT * FROM chain;

-- Call sites with execution context (loop/If depth)
SELECT File_Name, Script_Name, Step_Index + 1 AS step_no, Step_ID,
       loop_depth_before, if_depth_before
FROM v_script_block_tree
WHERE Step_ID IN (1, 164, 210)  -- Perform Script / PSoS / PSoS-with-callback
  AND Script_UUID = '<uuid>';
```

**Traps:**
- Following only `calls_script` misses layout/object triggers (entry role split).
- Deriving call context from the edge — impossible, the edge is context-free.
- Unbounded recursion: always guard with a depth cap and the path array.
- `Step_Name` is localized — match call steps via `Step_ID` only.

**Related tests:** `script-error-checks` (self_recursive_script member covers
direct self-recursion); indirect cycles have no test yet — use this pattern.

---

## `control-flow-reachability`

**Question forms:** "is this step ever reached?", "dead code after exit?",
"which exits does this loop have?", "under which condition runs step N?"

**Object types:** Script.

**Procedure:**
1. Use `v_script_block_tree` (materialized: per-step Loop/If nesting depth,
   block depth) for every branch-scope question — never re-derive nesting from
   raw `Step_Index` sequences.
2. Branch membership: a step is inside a loop iff `loop_depth_before >= 1`,
   inside an If branch iff `if_depth_before >= 1`.
3. Dead code: steps following `Exit Script` (103) / `Halt Script` (90) inside
   the same block are unreachable (rule `dead_code_after_exit` implements it).
4. What the catalog CANNOT answer: whether a *condition* ever evaluates true
   (path reachability of values). That stays interpretation work — say so
   explicitly instead of asserting reachability.

**SQL building blocks:** see `v_script_block_tree` examples in
`query-cookbook.md`; the executable checks live in the rule bundles
`dead_code_after_exit`, `loop_without_exit_loop_if`, `unbalanced_if_block`,
`deep_if_nesting`.

**Traps:**
- Hand-reconstructing If/Else nesting from step sequences (slow, wrong on
  500+-step scripts) — the view already carries it.
- Treating `Exit Loop If` presence as proof of loop termination — the
  condition may never fire; the catalog only shows the step exists.
- Step numbering: `Step_Index` is 0-based; user-facing numbers are `+ 1`.

**Related tests:** `script-error-checks` (dead_code_after_exit,
loop_without_exit_loop_if, unbalanced_if_block, deep_if_nesting, empty
branches), `script-performance-checks` (deeply_nested_loop).

---

## `window-lifecycle`

**Question forms:** "does this script leak windows?", "which window does this
close?", "why are there windows left open?", "hangs after printing/looping".

**Object types:** Script.

**Procedure:**
1. Openers via `StepsForScripts.Opens_Window = TRUE` — this includes `New
   Window` (122) AND `Go to Related Record` (74) with its "New window" option;
   counting `New Window` steps alone misses GTRR-opened windows.
2. Window names via `StepCalculations.Slot = 'Name'` (multi-calc steps: the
   name slot, not `Calculation_Text`, which is only the first slot — window
   geometry can occupy it).
3. Producer/consumer matching: producers are New Window @Name, GTRR @Name, Set
   Window Title @Rename; a `Close Window [Name: X]` with no producer anywhere
   in the corpus is a no-op (dead cleanup). Window names are app-global —
   match producers corpus-wide, never file-scoped.
4. Path argument: use `v_script_block_tree` to check whether every exit path
   closes what it opened.

**Traps:**
- **Step counts are not lifecycle proof** — equal open/close counts say
  nothing about paths, and unequal counts may still be correct (a callee may
  close). State the uncertainty.
- Filtering producers by file — window names are global.
- Reading the window name from `Calculation_Text`.

**Related tests:** `script-error-checks` (window_opened_without_close,
close_window_name_never_created, show_dialog_in_loop).

---

## `platform-context`

**Question forms:** "does this run on Server / WebDirect / Go?", "why does
this behave differently when scheduled?", "can OData run this script?" —
and the inverse inventory question: "which scripts were BUILT for iOS /
the server?", "what is the iOS share of this solution?"

**Object types:** Script (steps), solution-wide.

**Two axes — pick the right one first:**
- **a) Compatibility** ("can it run under X?") — a *context* question: the
  user picks a target environment, findings are obstacles (error/warning).
  Procedure below; test sets `platform-<env>` (profile `compat`).
- **b) Platform binding** ("was it built for X?") — an *inventory* question:
  no target choice needed, findings are neutral properties. Signal sources
  exist for **iOS** (exclusive steps from the `step_compat` exclusivity
  predicate + curated dedicated functions), **Server** (Perform Script on
  Server targets) and the **OS sub-axis** (below — since fm_spec 1.13.0 with
  three evidence sources: Claris steps, builtin functions, plug-in
  functions); for the remaining environments none exists and none is
  invented.
  Test profiles `specific` of `platform-ios`/`platform-server`, plus the set
  `platform-os-binding`. The axes explain each other: an iOS-bound script
  produces exactly its exclusive steps as errors under every other
  environment's compat check — "built for another platform", not broken.

**Third signal source — plug-in function calls** (`reference/plugin_spec.duckdb`,
ATTACH alias `plugref`, bundled with every fm-lab release — maintainer-derived
from the MBS docs mirror; members skip when the file is missing):
- **Axis a:** MBS functions with `Server=No` fail wherever scripts run under
  the FileMaker Server script engine — members `platform_compat_plugins_<env>`
  of the server/webdirect/dataapi/cwp sets (curated `plugin_runtime_map`,
  provenance per row). FileMaker Go supports **no plug-ins at all** — generic
  rule, every vendor, member `platform_compat_plugins_ios`. `pro` and `cloud`
  get no plug-in signal (none exists; Claris Cloud plug-in policy unverified).
  **Server × OS cross-refinement (v7):** `Server=Yes` functions whose OS flags
  do not cover every FileMaker Server OS (host matrix `ref.runtime_os_matrix`;
  practically `Linux=No`) surface as `warning` with
  `finding_kind='os_conditional'` — "runs on the server, but not on Linux
  FMS". This is the ONLY place the OS axis refines the runtime axis, and it
  goes through the host matrix, never directly.
- Evidence: `calls_pluginfunction` edges (Script, LayoutObject, Field) plus
  one-level custom-function wrappers (`via_custom_function`); old names
  resolve via `plugin_function_aliases`; unresolved functions of a known
  plugin surface as `info` rows, never silently.

**OS sub-axis (axis b) — since fm_spec 1.13.0 with THREE evidence sources,**
one set `platform-os-binding`, shared `os_profile` vocabulary (macos-only,
windows-only, linux-only, ios-only, desktop-only, apple-only, mixed; plus
`desktop-variant` for Send Event), severity always `info`. OS vocabulary is
strictly `macos|windows|linux|ios` — `ios` is the OPERATING SYSTEM (hosting
FileMaker Go AND Claris iOS SDK apps); runtime terms (`go`, `ios_sdk`, `pro`)
never appear on the OS axis:
- **Claris steps** (`ref.step_os_affinity`, curated from help prose — no
  structured Claris OS table exists; absence of a row = "no statement", never
  "runs everywhere"): `exclusive` (Perform AppleScript → macOS, Send DDE
  Execute → Windows, Speak → macOS, Configure ML Model → macOS+iOS),
  source-true inverse `unsupported` rows (Dial Phone "not supported in
  macOS"), and the Send Event dual-variant (one step id, two OS-exclusive
  option sets). Member `platform_os_steps`.
- **Claris builtin functions** (`ref.function_os_affinity`): Core ML trio
  (ComputeModel/GetModelAttributes/GetLiveText → macOS+iOS),
  Get(TouchKeyboardState)/Get(TriggerGestureInfo) → Windows+iOS, incl.
  transitive custom-function wrappers. Member `platform_os_functions`.
  `variant` rows (path formats, window geometry, modifier keys, …) are
  documentation knowledge → fm-spec badges only, no findings.
- **Plug-in functions**: verbatim MBS flags folded through the curated
  `plugref.plugin_os_map` (macos/windows/linux 1:1; `ios_sdk` → OS `ios`
  with qualifier `sdk-only`; the `server` flag is a runtime statement and
  stays out of the OS profile). Member `platform_specific_os`.

**Guard idiom (context evidence, not a binding):** `os_probe` functions —
Get(SystemPlatform), Get(Device), Get(SystemVersion),
Get(ApplicationArchitecture) (`ref.function_os_affinity`,
`affinity='os_probe'`, `os IS NULL`) — return the OS at runtime; developers
wrap OS-bound steps in `If [Get(SystemPlatform) = 1]` guards. When a user
asks "is this AppleScript call safe cross-platform?", check whether the
OS-bound step sits inside such a guard (`v_script_block_tree` ×
`StepCalculations`) before reporting an unguarded binding.

**`unsupported` resolution:** resolve against the HOST OS of the object's
runtimes (`ref.step_compat` × `ref.runtime_os_matrix`, Partial/NULL counts as
potentially running) — never against all four OS. Dial Phone (¬macOS) ⇒
windows+ios, NOT linux (FileMaker Pro has no Linux build). The host matrix is
the only sanctioned translator between the runtime and OS axes; `cloud` has
no matrix rows until its host OS is documented with a Claris source.

**Procedure (axis a):**
1. **Derive or ask for the target environment** — in three groups, not seven
   questions: (a) does it also run server-side (Server/Cloud)? (b) are there
   web/mobile clients (WebDirect/Go)? (c) is the solution used as an API
   backend (Data API/CWP/OData)? Server is *derivable* — since schema 1.20.0
   as a one-edge query: `calls_script` links with `Link_Subrole IN
   ('on_server','on_server_callback')` mark the callee (subtree) as
   server-side executed — confirm, don't assume. Counter-check: step 210
   itself (PSoS-with-callback) is client-only (`server = false`).
2. Look up `reference/fm_spec.duckdb → step_compat` (read-only) for the
   script's step set. Columns: `pro`, `server`, `go`, `webdirect`, `cloud`,
   `dataapi`, `cwp`.
3. **Tri-state semantics:** `false` = No (error: step does not run there);
   `NULL` = **Partial** — conditionally supported, deep-link the step's help
   page (`script_steps.url_slug`); `true` = Yes. A **missing row** (only 6×
   dataapi/cwp) is the genuine "Claris states nothing" case.
4. **OData has no step axis.** Claris publishes no per-step OData column —
   derive instead: OData runs scripts **server-side** (borrow the `server`
   base and say so), plus the OData-specific rules: no user interaction, no
   server-filesystem access, script name without special characters and not
   starting with a digit, and `Commit Records/Requests` at the end of
   data-changing scripts.

**Traps:**
- Answering platform questions from memory — always the lookup.
- Reporting NULL as "not documented" — it means *Partial* (this was the
  documented-wrong semantics until 2026-08; see CLAUDE.md §7).
- Inventing an `odata` column or heuristically filling one — where Claris
  publishes nothing, derive and show the derivation.

**Related tests:** the `platform-*` context test sets (one per target
environment; `platform-odata` uses the borrowed `server` base + the four
derivable OData rules). `platform-ios`/`platform-server` additionally carry
the binding aspect as a second member (`platform_specific_<env>`, profiles
`compat`/`specific`).
