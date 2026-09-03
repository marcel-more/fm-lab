# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows [SemVer](https://semver.org/).

---

## [Unreleased]

*(Upcoming changes go here)*

---

## [0.9.10] — 2026-09-03

A new **Trace** view for following a script or layout's actual flow, plus a round of fixes.

- **Trace — selective flow graph** — follow what a script or layout actually does, not just its immediate neighbors
  - **Trace mode in the Graph Explorer** and a new **`fm-trace` skill** — starting from a Script or Layout, see the call chain up and down, the objects the flow actually touches, and the script triggers of the layouts it enters
  - **Exclude from trace** — prune noise nodes from a trace, with a suggestion list of good candidates to hide
- **New object type: Chart** — FileMaker chart objects are now imported into the catalog and surface in the layout views and type filter
- **Fixes** — a trace redraw glitch in the Graph Explorer, and a publish / version-manifest fix

---

## [0.9.9] — 2026-09-02

A large release on two fronts: script triggers and layout-object formulas become a fully catalogued, navigable analysis surface, and the pipeline gets more correct and robust — more precise script generation, a hardened XML import, and a performance fix.

- **Script triggers & layout-object formulas** — a major new analysis surface
  - **Calculations as first-class catalog objects** — every calculation instance (conditional formatting, hide condition, tooltip, auto-enter, script-trigger parameter, …) is now catalogued, so the frontend detail views read from the catalog and where-used / dependency analysis sharpens accordingly
  - **Script triggers fully catalogued** — activation modes (Browse / Find / Preview), parameter formulas extracted even from exports without DDR-Info, and their file-, layout-, and object-level owners; a dedicated script-trigger detail page with navigation, event names localized to the interface language, and Browse/Find/Preview badges in the layout panel
  - **Layout formulas & merge content** — conditional formatting, hide conditions, tooltips, merge fields, and layout variables/calculations are captured, with new inventory queries and richer layout-object detail views (object groups and button bars included)
  - **Graph & references** — trigger edges and structural-containment direction corrected, reference subroles surfaced, and variable-reference highlighting in the detail views
- **Code generation & the FileMaker reference** (`fm-generate-script`, fm-spec 1.17.1)
  - **Data-driven step model** — script-step specifics (parameter groups, repetition groups, fixed-slot groups, boolean slots) are now encoded in the fm-spec schema and checked during generation, replacing hardcoded hints; malformed step parameters that previously slipped through are caught
  - **fm-spec schema browser** extended in the web client, with refreshed schema documentation
- **XML import — robustness, correctness & performance** (converter 2.12.0)
  - **Single-file mode fails loudly** — a reference-resolution failure now aborts before the dependent catalog phases (non-zero exit, clear banner) instead of publishing a stale catalog, the served copies keep their last consistent state, and a heal run after a mid-run abort now actually publishes its rebuilt catalog
  - **64-bit numeric slots** — values that overflowed a 32-bit `INTEGER` are widened to `BIGINT` and the "unlimited" sentinel is stored as "no limit", each with a drift guard and regression test
  - **Faster catalog build** — a performance-critical join in the catalog phase optimized
  - **More fixes** — single-file binder error, a clear-before-rebuild restoring missing layout-object steps, content-hash stability after an out-of-memory re-split, unified temp-directory handling, and a cleaner, fully localized import log
- **New tests & inventory queries** — a new SQL performance test set flags `ExecuteSQL` range searches that avoid `BETWEEN`, and new custom queries surface solution-wide inventories of script triggers, conditional formatting, hide conditions, tooltips, merge fields, and layout calculations
- **Docs & setup** — the doc-set search now matches inside entries and a function can belong to several categories; documentation and schema references updated; dev-container and stop-servers setup fixes

---

## [0.9.8] — 2026-08-18

A big expansion of the analysis rule library — layout-quality and community-sourced checks — and a reworked tests-and-dashboards surface built around a traffic-light health overview.

- **Layout quality checks** — a large new rule family (inspired by fmCheckMate) that flags layout-object issues
  - Degenerate / zero-size objects, copied or duplicated object names, commented-out layout calculations, and more — each finding carries the object name and its context, with a language-independent reference message addressable by URL parameter
  - **Layout Geometry Explorer** — inspect object position and size across a layout, with a Classic-Theme detection fix
- **More analysis rules** — the catalog of checks keeps growing
  - **Community-sourced rules** — performance and best-practice patterns collected from the FileMaker community, with source attribution per rule
  - **New "Developer Workflow" category** — surfaces unfinished-work markers (TODO / FIXME and similar) across scripts, layouts, and calculations
- **Tests & dashboards** — the surface reworked around a traffic-light health overview
  - **Healthchecks landing page** with a one-click "run all" start button and a red / amber / green status at a glance
  - **Folder-hierarchy breadcrumbs** for tests and custom queries, **result filter chips**, and **direct navigation** from the test panel to the affected object (or several)
  - Filter the test panel by object type; `AutoTable` now reports correct totals even when the result is truncated by a row limit
- **Documentation** — a **Static Code Analysis Rules Catalog** documenting the available rules and what each one flags
- **Code generation** (`fm-generate-script`) — resolver improvements for file-scoped object resolution, backed by the fm-spec reference update (1.14.0)
- **Fixes & setup** — a frontend HTTP keep-alive race and a dashboard slider-refresh glitch resolved; dashboards degrade gracefully when a bundled reference (e.g. the plugin spec) is absent

---

## [0.9.7] — 2026-08-12

The analysis layer gains two major capabilities: **Analysis Tests** — curated, repeatable checks with a traffic-light overview — and a **platform compatibility** model that answers "Will this run on FileMaker Server / WebDirect / Go / this operating system?". On the ingestion side, the XML import preserves more of the original information: intra-file UUID healing and reliable MBS plugin-call resolution.

- **Analysis Tests** — run curated checks over the catalog and see where a solution stands
  - **New `fm-test` skill and Tests dashboard** in the web client — run declared collections of rules (curated static-analysis dashboards and custom queries) in solution, file, object, object-list, or cluster scope; each test returns a default result plus severity-sorted findings, and a discovery mode lists which tests apply to a given object
  - **Test profiles, a traffic-light overview, and cached results** — group checks into profiles, get a red / amber / green summary across a solution with drill-down into findings and local selection filters, and re-open cached results without re-running
  - New **analysis-pattern** documentation (call-chain, control-flow / reachability, window lifecycle, platform context) supports symptom-driven investigation ("hangs", "slow", "wrong results") and test-discovery for agents
- **Platform compatibility & plug-in maintenance** — a new analysis dimension: does an object run on a given runtime and operating system, and is its plug-in usage still current?
  - **Compatibility metadata** for steps, function, and plugins across FileMaker runtimes (Server / WebDirect / Go / …) and the four operating systems — curated in the bundled reference (`fm_spec`) and a new plugin reference (`plugin_spec.duckdb`, starting with MBS), preserving conditionally supported ("partial") cases rather than a naive yes/no
  - **Platform-Profile dashboard** and an expanded fm-spec browser with per-step and per-function runtime/OS badges; incompatibilities are traced transitively through custom functions and new server-side-script call roles (on-server / on-server-callback), so a problem deep in a call chain still surfaces
  - **Plug-in maintenance checks** — a Plug-in Maintenance test set flags calls to *deprecated* functions as warnings (naming the documented successor) and to *removed* functions as errors (naming the removal release); an MBS plugin-version dashboard determines the minimum plugin version a solution requires from the introduction versions of the functions in use — with the driver functions and per-file spread — and can validate against a chosen installed version
- **XML import integrity** — the import keeps objects it used to lose (a full rebuild runs on the next import)
  - **UUID healing for intra-file duplicates** (schema 1.19.0) — objects that shared a UUID inside a file were previously collapsed ("last write wins" behavior); every twin is now kept with a deterministic, re-import-stable replacement UUID, and incoming references are mapped to the correct twin via the internal id/name/UUID triple the SaXML already carries — so shared script UUIDs no longer merge unrelated steps or local variables, a silent analysis falsification until now. The UUID-duplicates dashboard shows healed, navigable objects instead of lost ones.
  - **Reliable MBS plugin-call resolution** (converter 2.10.0) — a string- and comment-aware plain-text recovery pass restores plugin-function names that FileMaker's DDR export omits in certain constellations (a comment beside the call, nested calls), raising MBS resolution from 90.4 % to 99.3 %; genuinely dynamic calls (`MBS($var; …)`) render unlinked instead of as dead links, and a drift guard watches the rate
- **Dashboards** — a consistent traffic-light status across all dashboards, a real folder hierarchy with per-hierarchy "run all" and consolidated, cached results, and a more compact presentation
- **Robustness & fixes** — single-file import now runs the complete pipeline; assorted import-abort, repo-root, safe-directory, and path-with-spaces fixes
- **Docs** - refined FM-Lab documentation with clearer navigation, expanded content, and the new **Core Design Principles** section

---

## [0.9.6] — 2026-08-01

A bugfix and refinement release: switching solutions in the web UI is fixed, script generation gets more precise, and the XML import sharpens its script-step and platform-compatibility data.

- **Multi-solution switch in the web UI** — switching the active solution no longer breaks the app
  - The API did not allow the request header that carries the per-request solution context, so browsers refused every call after a switch whenever the frontend talked to the API on a different origin
  - Installations set up before v0.9.0 kept an absolute API URL in `apps/web/.env` and therefore ran cross-origin; setup now resets that legacy value to same-origin proxy mode, while a deliberately configured remote API host is left untouched
  - The web UI now names the solution context when a request fails at transport level and offers a one-click reset to the server default, instead of only reporting a lost connection
- **Documentation language fallback shown again** — when the help mirror is not installed for the selected language, the docs view again states which language it is actually showing
- **Script generation** (`fm-generate-script`) — more precise and more robust
  - **Fewer false positives** — an operator adjacent to a function name is no longer misread as a call, and bracket-group parsing of step parameters is hardened
  - **Custom-function folders & link roles** — custom-function folders are captured in the catalog and additional link roles are resolved, closing where-used gaps
- **XML import & static analysis** — sharper script and compatibility data
  - **1-based script-step numbering** — step counts now match what FileMaker shows, multi-calculation steps are captured in full, and control-flow nesting depth is recorded
  - **Window-logic and platform-compatibility** refinements feed the static-analysis dashboards more accurately

---

## [0.9.5] — 2026-07-27

A documentation release: the project docs grow from the getting-started manual into a full **reference** — the data model, the REST API, the SQL template library, and the SaXML source format are now documented end to end.

- **Data-model reference** — the DuckDB catalog is documented table by table
  - **Schema overview and version history** — the catalog schema explained as a whole, with a version history tracking how it evolved
  - **Catalog tables** — all 35 catalog tables (`ObjectCatalog`, `ObjectLinks`, `ScriptCatalog`, `FieldsForTables`, …) with their columns, keys, and role in analysis
  - **FileMaker object types** — a page per object type (30) describing what it represents and how it links into the graph, plus the object-catalog model itself
  - **fm-spec reference tables** — the 24 tables of the bundled FileMaker language reference documented for direct querying
- **SaXML source format** — the FileMaker `SaveAsXML` export explained, with a page for each of the 24 source catalogs, showing how the raw XML maps into the DuckDB tables
- **REST API reference** — overview, conventions, and output formats, plus per-endpoint documentation for every group: Search, Objects, References, Graph, Query & Report, Solutions, System, Reference Database, XML Import, and Codegen
- **SQL templates & pipeline** — the template library documented: built-in and custom query templates, dashboard datasets, detail-view templates, CLI analysis scripts, and the XML ingestion pipeline
- **Doc sets** — an overview of every installable documentation set (Claris Help, MBS, DuckDB, fmIDE, agents, ooe-fm, …)

---

## [0.9.4] — 2026-07-18

A bugfix and optimization release, focused on catalog correctness in the XML import, fewer permission prompts, and a refactored dashboard-authoring skill.

- **XML import & catalog correctness** — three resolution fixes; they ship with a schema-version bump, so the next import rebuilds the affected catalog automatically
  - **Portal → relationship references** — a portal on a layout now resolves to the relationship it is based on, closing a gap in where-used analysis
  - **Button-embedded script steps** — a script step attached directly to a layout button contributes its object references correctly and renders with the right step-type detail
  - **Multi-solution isolation** — the graph and re-clustering paths no longer resolve against the wrong solution when several are present; the active-solution scope is threaded through end to end
- **Setup & permissions**
  - **Fewer DuckDB permission prompts** — the shipped Claude Code settings seed now matches the documented DuckDB invocation, so catalog queries run without repeated approval prompts
- **`create-custom-dashboard` skill** — refactored and hardened
  - The monolithic skill instructions are split into focused reference docs (patterns, primitives, SQL rules, localization, validation), making dashboard authoring more reliable
  - Dashboard runtime improvements (host, actions, schema) and updated health-check / static-analysis dashboard queries
- **Project hardening** — a bug-and-blind-spot sweep across the object catalog, frontend mapping, publish/Docker path, skills, and test gates

---

## [0.9.3] — 2026-07-16

A documentation and bugfix release: the project documentation grows from a conceptual set into a usable manual — installation, quickstart, troubleshooting — and a round of fixes reported from the field.

- **Documentation** — reorganized into a navigable structure (Background · Using FM-Lab · AI Agents · Integrations · Specs)
  - **New pages** — `Installation`, `Quickstart`, and `Troubleshooting` for getting set up and unstuck; `4 Code Analysis Approaches`, explaining how interactive, static, graph, and agentic analysis interlock and when to reach for which; `fm-spec`, describing the FileMaker language reference; `Folder structure` as a repository tour
  - **Reworked** — `Architecture`, `Components`, `How it works`, and `Workflow` brought up to the multi-solution and code-generation state
  - **README** — clarifications and references to more detailed documents
- **Setup & install fixes**
  - **Docker build on the published bundle** — a file referenced by the Dockerfile was missing from the public release, so `docker build` failed for every fresh public clone of v0.9.2
  - **Fresh-clone init** — `init.sh` aborted before reaching its empty-state branch when the default solution's XML inbox did not exist yet (git does not track empty directories); the inbox is now created up front and only existing paths are scanned
  - **Fewer DuckDB permission prompts** — the shipped Claude Code settings seed now covers the documented DuckDB invocation, so catalog queries stop prompting for approval; also covered in the new troubleshooting page
- **Code-generation fixes** (`fm-generate-script`)
  - **Missing custom functions are caught** — a draft calling a custom function that does not exist in the target solution is now reported during resolution, instead of producing a snippet that fails silently on paste
  - **`Open Data File` parameter** — the step's target parameter is emitted correctly, backed by a new target-slot kind in the fm-spec reference
- **Publish-pipeline hardening** — a hard gate verifies that every file the Dockerfile copies actually lands in the published bundle; a missing whitelist entry now fails the publish instead of shipping a broken build context

---

## [0.9.2] — 2026-07-15

fm-lab becomes multi-user — several people can work against one instance at the same time, each on their own solution — and the object detail views for fields, layouts, and themes are completed down to every FileMaker option.

- **Multi-user & multi-session** — one running instance now serves several concurrent users, each viewing a different solution
  - **Per-session solution context** — a session (browser tab, agent, or API client) selects its own active solution independently of the workspace default, so two browser tabs can explore two different solutions side by side; the REST API backs this with a bounded connection pool over the per-solution databases
  - **Session-pinned agent context** — a Claude Code session can be pinned to a solution (`FMLAB_SOLUTION` / `FMLAB_CONTEXT`) so all reads and fm-lab tools resolve to that solution regardless of the workspace default
- **Complete field, layout & theme detail views** — every FileMaker option now surfaces in the web client (catalog schema extended for the new values)
  - **Field detail view** — the full option set: validation (strict / range / by-calculation / message), auto-enter and lookup, storage and indexing incl. index language, and summary modifiers
  - **Layout detail view** — all layout options, with the layout's theme linked through to its detail view
  - **Theme detail view** — themes as first-class catalog objects with their human-readable name
- **New static-analysis checks** — fields with automatic indexing, unstored calculation fields, and layouts that display unstored calculation fields; the overview gains a KPI breakdown by layout type
- **New `select-solution` skill** — switch the active workspace solution from Claude Code (list, confirm a near-miss, or pick interactively)
- **Web client & navigation polish**
  - Settings and the solution picker are reachable from the XML-import page too, and the import page can switch the target solution
  - Popover panels are no longer clipped when space is tight
- **Reference & setup** — fm-spec reference raised to schema 1.10.0 (emission-name refinements that feed code generation); the Docker firewall allow-list is extended for the documentation-install helpers (tolerant of CDN IP rotation)

---

## [0.9.1] — 2026-07-15

A robustness release: the catalog now recognizes when it was built by an older fm-lab and asks for a rebuild instead of failing with cryptic errors — plus a batch of fixes surfaced during testing.

- **Schema-drift detection** — the REST API compares the catalog's schema version against what the running server expects and, on a mismatch, shows a clear "re-run the XML import" notice in the web client instead of letting queries fail deep in DuckDB
- **XML import correctness**
  - **Calculated-repetition fix** — a Set Field step whose repetition is itself a calculation stored the repetition expression instead of the actual calculation in `StepsForScripts.Calculation_Text`; corrected, with a schema-version bump that triggers an automatic rebuild on the next import
- **Multi-solution packaging & tooling**
  - **CLI tools ship with the release** — `tools/solution.sh` (list / use / create / export) and the one-time `tools/migrate-multisolution.sh`, referenced throughout the docs and console output, are now included in the published bundle
  - **Workspace read-path created on first start** — the `db/fm_catalog.duckdb` symlink that projects the active solution for CLI readers is now materialized idempotently on every API start; an existing real file at that location is left untouched
  - **Migration script fix** and **fm-spec build self-healing** — a stale dirty-flag no longer blocks the reference build
- Assorted fixes from tester feedback and CLAUDE.md refinements

---

## [0.9.0] — 2026-07-14

Two headline steps: multiple FileMaker solutions in one workspace, each in its own self-contained bundle — and the first concrete delivery of reference-driven code generation, where a generated script is validated against the FileMaker spec and the actual object catalog before you ever paste it. Plus a memory-aware XML import, install auto-healing, and a refactored skill layer.

- **Multi-Solution** — manage several FileMaker solutions side by side in a single fm-lab workspace
  - **One bundle per solution** — each solution is a self-contained directory `solutions/<id>/` with its own `xml/` inbox, DuckDB catalog, and state; backup, hand-off, and archival are a `cp -r` or zip of a single unit. Separate databases mean a query can never silently mix solutions
  - **Explicit switcher** — a single active-solution toggle in both the CLI (`tools/solution.sh`) and the web client; the REST API resolves every request against the active solution
  - **`default` solution as the entry point** — a fresh instance always has a `default` solution with a self-healing gate, so an empty workspace and a first import just work; a migration step moves an existing flat workspace into the bundle layout without reconversion
  - **Solution-aware web client** — a solution picker in the header and a solutions panel in settings (rename, per-solution duration, activate), a dynamic Home tile reflecting the active solution
  - **Per-solution XML import** — the import is routed by solution id end to end, with parallel per-solution import status; the shared reference (`fm_spec.duckdb`) stays global and solution-independent
- **Reference-driven script generation** (`fm-generate-script`) — one of the project's core goals, hinted at in earlier releases and now concretely delivered: a generated FileMaker script is verified against the spec and the real object model *before* it leaves the tool
  - **Seven-stage, reference-driven pipeline** — from a canonical text draft (one step per line, any of the 11 locales) through normalize → lint → resolve → emit → gate to a paste-ready `fmxmlsnippet`; a failure in any check loops back to the draft with findings instead of "continuing with a warning"
  - **Nothing is hand-written from memory** — the step XML shape is emitted table-driven from `fm_spec.duckdb`, and every object id (fields, layouts, scripts, value lists) is *resolved* against the solution's own `fm_catalog.duckdb` object catalog — real ids, not guesses — with a machine-readable resolution report
  - **Three-layer validation gate** — every artifact is checked before delivery: well-formed XML, Step- and Function-IDs against the fm-spec reference index, referenced objects against `ObjectCatalog`, and the target solution's naming/language conventions
  - **fmIDE ActionScript / fmJAML** as a second delivery path alongside the snippet, from the same validated pipeline
- **Memory-aware XML import** — the conversion adapts to the available RAM instead of crashing
  - **Memory-limit detection with graceful fallback** — the import detects the memory ceiling (container/cgroup-aware) and scales down rather than aborting; an explicit error trap turns an out-of-memory situation into a clear, actionable message
  - Frontend surfaces the memory state during a run
- **Install & onboarding hardening**
  - **Doc-set install auto-heal** — the Claris / DuckDB / MBS / fmIDE installers recover automatically from an interrupted or drifted install instead of leaving a half-installed set
  - **`fm_spec` install auto-heal & drift-guard** — the reference install repairs itself and guards against a version/schema drift after a `git pull`
  - **`.env.example` drift-guard** — a check that keeps the shipped example environment in sync with what the code actually reads, plus a `bootstrap.sh` first-run step
  - **Docker filesystem preflight** — diagnoses a slow VirtioFS mount and steers the dev container to the faster gRPC FUSE backend
- **Skills refactoring**
  - **Shared skill layer** — `fm-summarize` and `fm-analyze` slimmed down onto a common `_shared/` helper set (response-language and short-mode conventions, reusable call-chain and type-query SQL), parity tested against the old versions
- **Reference viewer fix** — the fm-spec step/function lookup now normalizes a region-qualified or unsupported UI locale (e.g. `pt-BR`, `zh-Hans`) to a supported reference language, falling back to the default, instead of failing with an "unsupported language" error

---

## [0.8.11] — 2026-07-13

The bundled FileMaker reference gets a clean, self-describing home: one canonical `reference/fm_spec.duckdb`, read by both the API and every agent skill — plus an ActionScript delivery path for generated code and a round of minor bugfixes.

- **Standard reference relocated & renamed** — the reference database becomes a single, brand-aligned artifact
  - **One canonical file** — `reference/fm_spec.duckdb` (with a `fm_spec.meta.json` sidecar) is now the only copy, read directly by the REST API **and** all agent-facing skills
  - **Renamed from `fm_reference` to `fm_spec`** — file, version-manifest component, and the `fm-spec` project name now line up
  - **`install-claris-docs` decoupled** — the docs installer no longer ships a copy of the reference DB; the Claris Help mirror and the reference spec are now independent concerns
- **fm-spec reference expanded — fmIDE ActionScript / fmJAML** — a second delivery path for generated FileMaker code
  - **`actionscript` subcommand** in the `fm-generate-script` skill — emits generated steps as fmIDE ActionScript in JSON and fmJAML form, alongside the existing paste-ready fmxmlsnippet path
  - **Action catalog in the spec** — a machine-readable action/step mapping drives the ActionScript emission from the same reference, with its own validation gate
- **XML pipeline & converter bugfixes**
  - **webbed capability probe** no longer aborts (exit 8) when a `.duckdbrc` is present — the probe is isolated from user DuckDB config
  - **Binary-data split fix** — the streaming split no longer produces an invalid chunk on embedded binary payloads, strips large binary payloads

---

## [0.8.10] — 2026-07-11

The bundled FileMaker reference grows from a localized help cache into a full, browsable standard specification — and becomes the foundation for a new, reference-driven script-generation skill.

- **FileMaker standard reference** — the bundled reference database (`fm_spec.duckdb`) is rebuilt from a full FileMaker specification, no longer just a localized help cache
  - **Complete step & function surface** — all 206 script steps and 373 functions with their SaXML signatures, per-step platform compatibility, and the FileMaker version each was introduced in
  - **Machine-readable step grammar** — every step's option/parameter structure captured with enumerated option values, so a generator can emit valid step XML from the spec instead of hand-maintained templates
  - **Normalization passes** — boolean option polarity canonicalized and a compact text-form spec, so equivalent steps compare identically regardless of how the export phrased them
- **fm-spec Schema Viewer in the web client** — the reference becomes browsable, not just queryable
  - **Step and function detail views** — signature, parameters, compatibility, origin version, grammar, and a language selector
  - **New reference endpoints** — `/api/reference/meta`, `/reference/steps/:id/grammar`, `/reference/steps/:id/langs`, extending the existing help / lookup layer
- **Server lifecycle & onboarding hardening**
  - **Unified `start-servers.sh` / `stop-servers.sh`** — the four start/stop helper commands become thin delegators with a target argument (`api` | `frontend` | `all`) and a robust port-detection cascade
  - **Fail-fast on double start** — a pre-flight probe plus error handler in the REST-API entry point stops a second server instance cleanly
  - **Docker path fixes** — preflight warning, port binding, and the background → agent process handoff corrected for the containerized Quickstart
  - **`package-lock.json` committed** so a native (non-Docker) start on macOS / Windows installs a consistent dependency tree; a `marked` ESM-loading fix keeps the docs layer working on Node 20
- **Web client refinements**
  - **Empty-state components** — clearer chrome and guidance when the catalog holds no data yet
  - **Sorting & search** — corrected sort order and search-parameter handling in object lists
  - **Graceful DDR-Info fallback** — views degrade cleanly when a file was exported without DDR information

---

## [0.8.9] — 2026-07-10

Getting into fm-lab: a single onboarding command for shell users, a slimmed-down CLAUDE.md backed by a reference-doc layer, and two new skills for jumping from an object straight into FileMaker or the web client — plus catalog and frontend refinements.

- **Onboarding & the `fmlab` command** — one entry point after a clone, for both shell paths
  - **`tools/fmlab.sh`** — a single wrapper that asks two questions (Docker? then Claude?) and lands you directly in the product: the web client in the browser, or a Claude Code session in the container; answering "no" to Docker hands off to the native `init.sh` path so it is never called by hand.
  - **Docker-with-agent path** — bring the health-gated stack up in the background and drop straight into an agent session (`fmlab up --claude`), or (re)attach to an already-running stack (`fmlab agent`)
  - **Init hardening** — `init.sh` gains an explicit **webbed capability check** with graceful error fallbacks, a `bootstrap.sh` step, and a `.env.example` for first-run configuration; the public dev-container/compose bundle picks up the same auth-preflight
- **CLAUDE.md & skill-system refactoring** — the project brief becomes a lean router into a reference-doc layer
  - **CLAUDE.md slimmed from ~700 to ~115 lines** — the deep material moved into a dedicated `docs/agents/` set (`schema-reference`, `analysis-workflows`, `codegen-workflows`, `codegen-registry`, `pipeline-reference`, `query-cookbook`, `tooling`), each linked from the relevant section instead of inlined
  - **Codegen capability protocol** — a discover → select → apply → fallback flow for FileMaker-artifact skills that no longer assumes any specific skill is installed, with a `codegen-registry.md` mapping and a skill-independent validation gate
- **Two new skills — `fm-open` & `fm-show`** — close the loop from analysis back to the object
  - **`fm-open`** — opens a FileMaker object directly in FileMaker Pro via an fmIDE `fmp://` deep link, after verifying through the REST API that the fmIDE plugin is enabled and the target script exists
  - **`fm-show`** — opens the object in the FM-Lab web frontend (detail / references / graph view), working from inside the dev container by opening the browser on the host
  - **Shared resolver layer** — a common `_shared/` helper set (`resolve-object`, `open_url.sh`) so both skills resolve an object reference and launch a link the same way
- **Catalog & frontend refinements** (schema 1.7.0, XML import 5.1.0)
  - **LayoutObject type canonicalization** — localized layout-object `@type` values are normalized to their canonical English form, fixing a silent loss of container-kind objects on localized exports
  - **Button-embedded script steps as interactive tokens** — a script step that hangs directly on a layout button now renders in the frontend with the same tokenized, clickable model as script bodies, via a dedicated step-token endpoint and SQL
  - **Frontend bugfixes** — object-name display and plugin-function name rendering corrected across the calculation/token viewers (`CalcTokenSpan`, CustomFunction / Field / CustomMenu / PrivilegeSet viewers)

---

## [0.8.8] — 2026-07-06

Catalog completeness — closing the last where-used gaps across menus, calculations, buttons, and cross-file relationships — plus a broad hardening, bugfix, and optimization pass.

- **Catalog completeness** — new reference classes so objects previously reachable only through indirect paths now appear in where-used and dependency analysis (schema 1.6.1)
  - **Custom Menus & menu items** parsed into the catalog with a detail view; submenu items link to the menu they open
  - **Calculation-chunk references** resolved from layout-object formulas (conditional formatting, hide, tooltip, …) and other calc contexts
  - **SQL and plugin calls** resolved — MBS function names qualified, `FM.RunScript` wired to `calls_script`, and field usage inside SQL wrappers surfaced
  - **Button-embedded script steps** — a button that runs a single step now contributes the same navigation/reference links as the script side, with correct Go-to-Related-Record table-occurrence semantics
  - **External table occurrences** in `RelationshipCatalog` resolved across files
  - **Value-list sort references** captured, and **locale-independent step-role mapping** — field references no longer fall through on localized exports
- **Hardening, bugfixes & optimizations** (prominent items)
  - **XML pipeline hardening** — the Katana engine refactored into a shared library, with byte-identical output verified end-to-end
  - **webbed v2.4.0** adopted (signed community build) — fixes SAX-streaming double-encoding of non-ASCII content; the version check is raised accordingly
  - **Converter quality-test harness** — a data-driven, end-to-end check catalog that guards conversion correctness against a baseline
  - **XML import integrity dashboard** — surfaces duplicate-absorption and consistency findings from the import directly in the web client
  - **Reference hygiene** — empty-string references normalized away, removing phantom links from where-used
  - Frontend detail-view optimizations — file, value-list (with full-text search), and base-table detail views
  - dashboards / custom-queries cleanup

---

## [0.8.7] — 2026-07-03

Static code analysis as a first-class layer: curated rule bundles run as live catalog queries and surface as localized, drill-down dashboards.

- **Static Code Analysis** — PMD-inspired rule bundles that flag known issues and structural signals across the solution
  - Rules run as **live dashboard datasets** — no separate runner or scan step; each rule is a targeted catalog query, always in sync with the latest import
  - Grouped into categories — **best practices, code style, documentation, error-prone, performance, security, unused code** — plus a **modularization** category (file coupling and inventories for filesystem access and process / server-side / email / plugin / ODBC usage)
  - **Overview with health KPIs** — the implemented checks at a glance, with object-type-grouped live counts and a security group, each drilling down into its findings
  - Analysis foundation: per-step control-flow metadata and a materialized script block-tree (Loop / If nesting depth) that power block-level rules such as unbalanced If or loop-without-exit
  - Fully **localized across all 11 languages**, with reusable API filter-sets for the dashboards

---

## [0.8.6] — 2026-06-30

A containerized setup for fm-lab with a clear Quickstart path, a version manifest that tracks every moving part, and a round of UI refinements.

- **Docker setup** — run the whole stack in a container, no local toolchain required
  - A self-contained **dev-container + `docker-compose` bundle** with a clean multi-stage `Dockerfile` (base and Claude Code targets) and a network-hardening firewall init script
  - **Guided Quickstart** — the Home empty-state card now shows the live file count in `xml/`, an **Open folder** action (copyable host path in the container), and a one-click **Convert** that jumps into the import and starts it
  - Windows support (experimental) via Docker Desktop / WSL2 backend
- **Version manifest & runtime checks**
  - A central **`version.json` manifest** generated from a single source, tracking the version of each component (REST API, web client, `CLAUDE.md`, DB schema) with a per-component on-change action (restart, rebuild, copy, or force a DB rebuild)
  - New **`/api/version-manifest` endpoint** and a version bar in the web client settings
  - Init/version check raised to a **Node 20 / npm 10** baseline
- **UI refinements** — numerous frontend optimizations; the prominent ones:
  - **Files as the top level** — the object hierarchy and the Graph Explorer can group by file
  - **References panel** — duplicate removal, additional columns, and a flex layout
  - **In-script search** extended to step parameters (ScriptStep chunk content), so a query hits inside step contents, not just step names

---

## [0.8.5] — 2026-06-28

A top-down Graph Atlas over the whole solution, a cluster overview with auto-clustering, and a unified, more polished web client.

- **Graph Atlas** — a top-down entry point to the object graph (new `/atlas` route), complementing the focus-driven Graph Explorer
  - **Overview at a glance** — a treemap of files and communities sized by object count, plus a meta-graph of how the modules connect; drill from any tile into the Explorer or a detail view
  - **Annotations** — name and comment communities and individual nodes, stored in a separate sidecar database so they survive re-imports and re-clusters (remapped by majority vote)
  - **Noise filter** — dim or hide low-signal nodes to keep the big picture readable
  - **Graph Explorer refinements** — richer focus filters, an adaptive depth control backed by a depth-profile endpoint, per-type object lists, and truncation-aware reloading
- **Cluster overview & auto-clustering**
  - **New `/cluster` page** — clustering-run metrics, the full community list with inline (re)naming and filters, and a Home-dashboard cluster bubble for a quick count
  - **Community rebuild in the import** — clustering can run as a final import step, with two independent drift indicators (structural input-delta vs. naming) signalling when a re-partition or re-naming pays off; existing module names are reused across runs
- **Richer reference extraction** — closing object-graph gaps: previously-missed **cross-file references** now resolve, **references to built-in functions** and the text content of **Insert Text** steps are captured, plus an umlaut/encoding bugfix in the reference parser
- **XML engine (webbed)** — the tested DuckDB baseline is raised to **1.5.4** (required for webbed v2.2.1's SAX-streaming parsing of nested FileMaker structures); a data-driven capability registry probes the actually-loaded webbed and toggles the matching workarounds, and setup warns when the installed CLI is older; serializer encoding bugfixes (non-ASCII / carriage-return)
- **Unified & optimized UI/UX** — numerous frontend optimizations consolidated into one pass; the prominent ones:
  - **Navigation overhaul** — a reworked navigation model with consistent labels and breadcrumbs
  - **Home dashboard** — a new variables KPI and a cleaner KPI rhythm
  - **Restartable XML import** — the import streams through a broadcast hub, so navigating away no longer kills it, resuming via the incremental manifest
  - **Light-mode fix** for inherited white button text, plus assorted bugfixes
  - **`script_todos` dashboard** reworked to recognize multiple TO-DO notations

---

## [0.8.4] — 2026-06-24

Bugfixes and optimizations.

- **Clone-aware UUID resolution** — a solution duplicated via "Save a Copy As…" keeps the original's internal `File_UUID` (and the shared template's object UUIDs), which previously broke both import and where-used analysis
  - **Import no longer aborts** on a clone pair sharing a `File_UUID` — the second file used to crash the extract phase and, because the REST sync gates on zero failures, block publishing every other successfully imported file alongside it
  - **Explicit ambiguity instead of a silent guess** — a bare-UUID lookup matching several clones now returns `AMBIGUOUS_UUID` (HTTP 409) with the list of matching files; passing a `file` pins the exact one, and a still-unique UUID resolves as before (graceful downgrade). Applied across object details, references, back-references, graph subgraph/neighbors, and the fmIDE deep-link (which otherwise jumped into the wrong clone)
  - **`AmbiguousFilePicker`** in the frontend — when a UUID resolves to several clones the user picks the file, and the choice is threaded through navigation
  - **Surgical link scoping** in the catalog — `trigger_owner` is constrained to its own file, while `lookup_source` / `lookup_relationship` prefer the local file but preserve genuine cross-file lookups
- **Sharper community detection** (Graph-Analysis refinements)
  - **God-nodes and local variables filtered** out of the cluster graph, so communities form around real structure instead of being pulled together by ubiquitous, low-signal nodes
  - **Persistent, drift-tolerant semantic-name cache** — hand-curated community names now survive a re-cluster (e.g. after an XML re-import): names are cached per object UUID and re-applied to the new partition by majority vote, so a single clustering run no longer discards them
- **Import refresh & validation hardening** (from user feedback) — per-file DELETE-before-INSERT is confirmed as the default, so elements removed from a solution no longer linger as zombie rows on re-import; validation/consistency views refined

---

## [0.8.3] — 2026-06-23

The object graph becomes explorable and self-organizing: an interactive Graph Explorer in the browser, and automatic community detection that segments the solution into named modules.

- **Graph Explorer** — interactive, browser-based exploration of the whole object graph (new `/graph` route)
  - Pick any object as the focus and reach outward by **depth**, **direction** (uses / used-by / both); narrow by object type, link role, and built-in functions
  - **Inspect panel** with node metadata and neighbor list, plus one-click *set as focus* / *expand one hop* / *collapse hub* / *open in details*
  - Cytoscape `fcose` layout, hub highlighting, hover dimming, **PNG export**, deep-linkable view state (`?focus=&depth=&dir=&mode=`)
  - New REST graph API (`GET /api/graph/subgraph` · `/neighbors` · `/search`) and a **`graphify` plugin** that exports the graph as JSON to `output/`
- **Community detection** — the graph segments itself into modules and names them
  - New `ObjectClusters` / `CommunityNames` tables; a deterministic **Louvain** baseline (seeded) with an optional **Leiden** engine, run as a standalone batch after `convert-xml`
  - **Color lens** in the Graph Explorer toggles node coloring between object type and community, with a community legend
  - New **`fm-graph-cluster` skill** — sweeps candidate resolutions and scores them (modularity Q + distribution guardrails), names communities semantically, writes an analysis report to `output/`, and syncs the named partition to the Graph Explorer
  - **Cleaned logical-graph views** in convert-xml Phase 5 (`LogicalLinks`, `ClusterEdges`) — sub-objects hoisted to their container, multi-edges deduped, built-in primitives separated out. The hub/degree analysis now runs on the *same* edge set as the clustering
- **FileMaker 26 Custom Functions fix** (schema 1.4.1) — FileMaker 26 (SaXML v2.3.0.0) moved each Custom Function's formula out of the separate `<CalcsForCustomFunctions>` section into an embedded `<Calculation>`. The parser now extracts **structure-tolerantly from both locations** and merges them

---

## [0.8.2] — 2026-06-18

fmIDE plugin and XML import refinements.

- **fmIDE plugin** — settings and lifecycle reworked
  - New option to **show the plugin buttons only when it is actually installed in the solution** — keeps the UI clean for files that don't use fmIDE
  - **File scan with version detection** — recognizes the installed fmIDE version per file
  - **Startup behavior changed to manual activation** — the plugin no longer auto-activates; the user enables it explicitly
- **Browser-driven XML import** — the `xml_convert` sub-dashboard offers more intuitive behavior and new options
  - **Turbo mode** (default) — the import uses the full power of multithreading and chunk dispatching to speed up conversion
  - **Incremental toggle** (default on) — the import re-parses only files that actually changed, streamed as live SSE progress; on a real solution a no-op re-import drops to a handful of seconds

---

## [0.8.1] — 2026-06-17

Relationships with multiple join predicates and sort fields become fully resolvable — in the catalog and in the graph view.

- **Multi-predicate joins** — `RelationshipCatalog` is now **per predicate** (new `Predicate_Index` column); a multi-field relationship emits one `left_field` / `right_field` link pair per predicate instead of collapsing to a single pair (schema 1.2.0)
- **Sort fields as real dependencies** — the "sort records" field of a relationship side is parsed and linked (`sort_field`, `Link_Subrole = left`/`right`), so it shows up in the field's where-used analysis (schema 1.3.0)
- **Relationship detail view** — graphical relationship detail in the web frontend, with references sorting; bugfix for join-predicate field rendering
- **XML schema docs** extended to cover the multi-predicate structure
- **Dashboard KPIs for the object graph** — Home dashboard gains object-count and link-count KPIs (`ObjectCatalog` / `ObjectLinks`), plus a locales bugfix

---

## [0.8.0] — 2026-06-16

The XML import, rebuilt as a streaming, incremental, memory-aware pipeline — large multi-file solutions import faster, within a bounded memory budget, and a re-import only touches what actually changed. Every optimization is identity-checked to produce byte-identical catalogs, so none of it changes analysis results.

- **Katana-Engine** — XML is folded, refined and forged into fine-grained fragments, enabling massive catalogs to be processed with minimal memory usage and maximum parallelism.
- **Six-phase pipeline** — the conversion is split into Extract → Resolve → Details → Catalog → Homes → Validate. Only phase 1 reads the XML; every later phase works purely on the DuckDB tables. This keeps the parse load and memory peak low and makes each phase independently testable
- **Streaming split for large files** (`--split`) — each file's extract phase is chunked at top-level branch boundaries (the heavy script-steps and DDR branches get their own chunks), drastically lowering peak DOM memory — bit-identical to the unsplit run
- **Turbo mode** (`--turbo`) — chunk-granular parallel dispatch: every chunk across every file flows through a worker pool (heaviest-first) and is consolidated in two stages, for substantially shorter wall-clock on multi-core machines
- **Incremental import** (`--incremental`) — a persistent manifest fingerprints every file (mtime/size → sha256 + version gate); unchanged files are skipped entirely and their catalog rows are preserved. Re-importing after editing a single file goes from minutes to seconds
- **Automatic memory backoff** (`--auto`) — a chunk that runs out of memory is automatically re-split into smaller pieces and retried, so an import completes on memory-constrained machines without manual tuning
- **Memory-aware parallelism** — the `--jobs` default is now derived from actually-available memory and is container/cgroup-aware (not just host RAM), preventing the batch OOM that a fixed worker count could trigger
- **Validation phase** — a dedicated final phase produces plausibility/consistency check views, surfacing structural anomalies right after a conversion
- **Linux-friendly** — CLI-tool calls now fall back gracefully across GNU and BSD flag variants, so the import runs on Linux as well as macOS

---

## [0.7.7] — 2026-06-12

Graph completeness: script-trigger owners and popover panels become first-class, queryable nodes — closing the last reachability gaps in the object graph.

- **Script-trigger owner back-links** (`trigger_owner`) — every trigger is now reachable *from* its owner, not just from the script it calls
  - New structural link `ScriptTrigger → Layout / LayoutObject / File`, with `Link_Subrole` carrying the trigger type (e.g. `OnObjectSave`, `OnLayoutEnter`) — "which triggers hang on layout/object/file X?" is now a direct graph query
  - New **`File` object type** in `ObjectCatalog` (owner anchor for file-level triggers `OnFirstWindowOpen`, `OnLastWindowClose`, …; UUID = `FMSaveAsXML/@UUID`) — the file itself becomes a registered object
  - NULL-safe owner guard: unresolvable owners are skipped, never producing orphaned links
- **PopoverPanel objects** now emitted by the LayoutObject parser — closes a coverage gap where panels were entirely absent from `LayoutObjects` / `ObjectCatalog`
  - A PopoverPanel hangs under `<PopoverButton>`, not `<ObjectList>` — the parser now descends into it, capturing its UUID, calculated title (with field references), and child objects
  - Resolves previously-unresolvable trigger owners (`OnObjectEnter/Exit/Keystroke` on popover panels) — prerequisite for full `trigger_owner` coverage
  - Panels surface in detail view, search, and where-used like any other layout object
- **Object-reference parser bugfixes** — refinements to read/write field-reference coverage in `create_universal_catalogs.sql`

---

## [0.7.6] — 2026-06-12

Custom Record Privileges as a first-class analysis surface: calculation-based record, field, and object privileges parsed into the catalog, wired into the object graph, and rendered as interactive tokens in the frontend.

- **Three new privilege-detail tables** for solutions using Custom Record Privileges (the `<Records>`/`<Layouts>`/… `Custom="True"` mechanism, where the summary attributes no longer reflect real access)
  - **`PrivilegeSetRecordAccess`** — table level: one row per privilege set × table × operation (View/Edit/Create/Delete); access mode, calculation text/DDR-hash, evaluation context
  - **`PrivilegeSetFieldAccess`** — field level: per-field access mode for tables with `Fields access="Custom"`
  - **`PrivilegeSetObjectAccess`** — Layouts/ValueLists/Scripts: per-object access mode, layout record-access, class create flag
- **Graph integration** — closes the where-used gap for objects referenced *only* inside a Custom Record Privilege calc, which previously appeared unused
  - `PrivilegeSet → Field (reads_field)`, `→ Variable (reads_variable)`, `→ CustomFunction (calls_customfunction)`, `→ PluginFunction (calls_pluginfunction)` — `Link_Subrole = <Operation>:<Table>`; variable reads bidirectionally traversable
  - Scoped **restriction links** `restricts_field` / `restricts_object` (`Link_Subrole` = access mode) for actual restrictions only — a restriction is *not* a usage, so it never pollutes where-used/dead-code analysis; folders/separators excluded
  - `VariableUsages` extended with `Context_Type='record_access_calc'`
- **Record-access calc rendering in the frontend** — the calculation behind a privilege is now visible and explorable
  - New **`PrivilegeSetViewer`** / **`PrivilegeSetDetail`** components with typed, clickable token rendering (variable/field/TO/function colored and linked), `useCalcTokens` hook, and `object_details_privilegeset.sql`
  - `detail` i18n namespace extended (en + de)

---

## [0.7.5] — 2026-06-11

XML conversion moves into the web frontend: import the catalog by button press, with live progress and a persistent log — no terminal required.

- **New `xml_convert` sub-dashboard** — drives and monitors the XML→DuckDB import from the browser
  - Per-file import status table: ✅ imported & current · ✴️ imported but a newer file exists · ➡️ not yet imported
  - **Convert button** with a live progress bar and a persistent live log, streamed as **SSE** (analogous to the docs installer)
  - Status line: "n of m files processed" during the run; timestamp, duration, and success/error count on completion
- **Home dashboard empty-state guidance** — when the DB holds no imported files: KPI dashes instead of zeros, a hint text, a listing of the `xml/` directory, and a convert button (disabled when the directory is empty)
- **REST-API import layer**: `xml.controller` / `xml.routes` / `xml-convert.js` — `POST /api/xml/convert` streamed as SSE; shares the `.fmlab/xml_convert.lock` with the CLI so they can't run in parallel (web → `409 Conflict`, CLI → exit code 7)
- **New frontend primitives**: `XmlConvertControl`, `XmlConvertLog`, `XmlEmptyStateCard`, `useXmlConvertCurrentFile`; `convert_fm_xml.sh` extended for frontend invocation
- **Docset installer progress bar** in the frontend (`DocsetInstallControl`) with shared `tools/install_modes.sh` logic — same live-progress treatment as the XML import
- Bugfixes: Umlaut handling in the import log, log update + highlighting in the dashboard table

---

## [0.7.4] — 2026-05-21

Home dashboard restructured around navigation, and a deep, first-class integration of doc sets (Claris Help, MBS, DuckDB, fmIDE) into the catalog and dashboard layer.

- **Home dashboard restructured** — focused on orientation and entry rather than on data dumps
  - Layout fully reworked: tighter navigation tiles for dashboards, custom queries, and doc sets; greeting / project summary block; cleaner KPI rhythm
  - Top-N analyses (`top_scripts`, `top_tables`, `top_layouts`, `top_custom_functions`) moved out of the bundle and into `sql-custom/` — now reusable from any dashboard or the custom-queries surface; new `top_mbs_functions.sql` added
  - Health metrics extracted into a dedicated **`health_hints` custom dashboard** (`dashboards-custom/health_hints/`) — collects `health_indicators`, `variable_hotspots`, `cross_file_links`, `find_undocumented_fields`, `find_unused_fields`, `find_unused_scripts`, `list_global_variables`
  - Home locales refreshed across all 11 languages to match the new structure
  - `dashboard.service` extended with navigation/sub-dashboard resolution; `actions.ts` and the `List` primitive support the new navigation patterns
- **Deep doc-set integration** — doc sets become navigable catalog citizens, not just files on disk
  - **New architecture**: every doc set declares itself through a manifest with metadata, categories, entries, references, and update info
  - **REST-API doc layer**: `docs.controller` / `docs.routes` with endpoints for overview, doc-set home, categories, individual entries, references, and assets; supporting services `docs-manifest`, `docs-content`, `docs-references`, `docs-source`, `docs-install`, `system-reload`
  - **Pluggable doc adapters** (`plugin-docs/adapters/`): `claris-duckdb` (Claris Help reference DB), `dash-sqlite` (legacy Dash docsets), `markdown-fs` (file-tree markdown sets) — uniform interface for arbitrary doc sources
  - **Internal links and assets** resolve correctly across the adapter layer, so links inside doc entries route through the API instead of breaking
  - **Doc dashboards** as the navigation surface: `docs/` (entry), `docs_overview/` (all installed sets), `docset_home/`, `docset_category/`, `docset_detail/` — all bundled, themed, and localized
  - **Frontend doc components**: `DocsEntryView` with dedicated styling and `DocsBreadcrumb` — render entries with internal-link rewriting, asset proxying, and back-navigation
  - **Doc installers redesigned** for the new manifest+index model: `install-claris-docs`, `install-duckdb-docs`, `install-fmide-docs`, `install-mbs-docs` — each installer now generates the manifest, builds/updates the index, and registers the doc set; shared logic in `tools/install_modes.sh` and `tools/register_docs.py`
  - **Install button** for each available doc-set within the frontend
  - i18n: new dashboard / nav strings (en + de) for the doc surface
- **New custom dashboard `script_comment_density/`** — code-quality metric surfacing scripts with low (or absent) comment coverage; KPI block plus findings list, localized in all 11 languages
- **`create-custom-dashboard` skill** updated with refined conventions and guidance for the new dashboard layout (navigation tiles, locales, sub-dashboards)

---

## [0.7.3] — 2026-05-20

ScriptStep full-text search, two new diagnostic custom dashboards, and plugin-layer internationalization.

- **ScriptStep full-text search** — drill from any object into the script steps that reference it
  - New `ScriptStepDetail` component with dedicated styling: renders an individual script step with full token interactivity, surrounding context, and back-navigation to the parent script
  - New SQL template `object_details_scriptstep_tokens.sql` powers the tokenized step view
  - `object.controller` / `object.service` extended with ScriptStep-aware lookup, search, and listing endpoints (OpenAPI spec updated, generated TS types regenerated)
  - `ScriptViewer`, `HierarchyTree`, `ObjectListItem`, and the dashboard `Table` primitive refined to support the new step-level navigation and highlight model
- **Two new diagnostic custom dashboards** under `templates/dashboards-custom/`
  - **`credentials_in_scripts/`** — surfaces scripts that embed credentials / secrets in literal form: KPI block plus findings list with source script and context; localized in all 11 languages
  - **`if_else_asymmetry/`** — detects asymmetric If / Else If / End If blocks (likely script-logic bugs) with KPI overview and per-block findings; localized in all 11 languages
- **Plugin-layer i18n**
  - New `plugin-i18n.service` in the REST-API: resolves plugin manifest and UI labels against the active language with English fallback — mirrors the dashboard i18n architecture
  - `plugins.controller` and `plugins.routes` accept and forward the language parameter
  - **fmIDE plugin** localized: `plugin.json` slimmed down to non-translatable metadata, with per-language `locales/<lang>.json` files for all 11 languages
  - Frontend `PluginCard`, `LayoutTypeFilter`, and `SettingsView` migrated to `t()` calls; `detail.json` translation namespace extended in every language
- **Documentation**: refinements and clarifications about the composability and extensibility of the underlying architecture

---

## [0.7.2] — 2026-05-19

Internationalization across the whole stack: 11 languages in the web client, localized dashboards, English as the new primary language for the codebase, CLAUDE.md, and all skills.

- **Web client i18n** (`apps/web/src/i18n/`) — react-i18next-based translation infrastructure
  - **11 languages**: English (default), German, Spanish, French, Italian, Japanese, Korean, Dutch, Portuguese, Swedish, Chinese (Simplified)
  - 6 translation namespaces per language: `common`, `dashboard`, `detail`, `errors`, `nav`, `types`
  - New `LanguageSelector` component and `useApiLang` hook for synchronising UI language with API requests
  - Practically every frontend component migrated to `t()` calls — Breadcrumbs, DetailView, FieldDetail/Viewer, ObjectDetail, ScriptDetail/Viewer, SearchOptions, FolderTree, HierarchyTree, DependencyGraph, RelationshipGraph, LayoutCanvas, ReferencesFilter, SettingsView, ErrorMessage, LoadingSpinner, ThemeToggle, plugins, and more
- **Localized dashboards** — translations live alongside the dashboards
  - Each dashboard bundle now carries a `locales/<lang>.json` file (10 non-English locales) — applies to `home`, `_generic`, `custom_queries`, `dashboards`, `external_apis`, `script_todos`
  - New `dashboard-i18n.service` in the REST-API resolves manifest, layout, and dataset labels against the active language with English fallback
  - Dashboard primitives translate cell content through the new `_cellTranslate` helper, with extended formatters in `_format.ts`
- **REST-API language plumbing**
  - `rest-api/src/config/languages.js` and shared `packages/shared/src/languages.ts` — single source of truth for the supported language set
  - New `system.controller` / `system.routes` with a `GET /api/system/languages` endpoint
  - `dashboard.controller` and routes accept and forward the requested language
- **Codebase primary language switched to English**
  - `claude.md` fully rewritten in English
  - All skill `SKILL.md` files translated to English
  - **Multi-language trigger phrases** added to every skill (English + 10 other locales) — skills now fire reliably regardless of the user's working language
  - **XML schema docs** (`docs/agents/xml-schema.md`, `xml-schema-extended.md`) translated to English
- **Inline help in the frontend** — help text inside `DetailView`, `ObjectDetail`, `ScriptDetail`, `ScriptViewer`, and `TypeDetail` rewritten in English; `object_references_script.sql` adjusted accordingly
- **Custom dashboards moved to their own directory**
  - `external_apis`, `script_todos` relocated from `templates/dashboards/` to `templates/dashboards-custom/` — clean separation between core and user-authored bundles
  - SQL templates reorganized: home-dashboard analyses moved into `dashboards/home/queries/`, layout-specific SQL into `dashboards/home/layout/`
  - Home dashboard gained navigation tiles for sub-templates
  - `create-custom-dashboard` skill updated for the new target directory and structure
- **Tooling**: `tools/claude-language-hint.mjs` — emits a localized hint so Claude Code picks up the user's preferred language automatically; `.fmlab/user.local.example.json` extended with language preference example
- Bugfix: list scroll-position reset in `useInfiniteSearch` after filter/query change

---

## [0.7.1] — 2026-05-17

Dashboard polish, first batch of example custom dashboards, and refinements to the Script detail view.

- **Example custom dashboards** as reference implementations and immediately useful views on top of the catalog:
  - `dashboards/` — meta dashboard listing all available dashboards
  - `external_apis/` — analyzes outbound API usage in the solution: aggregated API families, individual external sources, URL-level details, and a summary card; built around the existing variable/calculation tracking
  - `script_todos/` — surfaces scripts marked as TODO / WIP with KPI block and grouped script list
- **Dashboard primitives upgraded** for interactive use:
  - Per-primitive **row search and filter** via the new `_useRowSearch` hook — applied to `List`, `Table`, `TileGrid`, and `KPIStrip`
  - **Action state** (`actionState.ts`): primitives can carry navigation/filter state across user interactions
  - Dashboard results are interactive: click navigation to the objects detail view for further code exploration
- **Script detail view** — optimizations and bugfixes:
  - New `highlightContext` provider for shared highlight state between viewer, search, and reference panels

---

## [0.7.0] — 2026-05-16

Dashboards as a first-class extension surface: bundled, declarative, data-driven views — with a Home dashboard as the new entry point and a generic renderer for every custom SQL query.

- **Dashboard bundles** as a new top-level concept: each dashboard lives in its own folder under `rest-api/templates/dashboards/<id>/` with a `manifest.json` (id, title, datasets, params, permissions), a declarative `layout.json` (primitive tree), bundled SQL datasets in `data/`, and optional static assets — fully self-contained and shippable
- **Home dashboard** as the new entry point: project summary, object-count KPIs, files overview, top-N scripts / tables / layouts / custom functions, variable hotspots, health indicators, and navigation tiles for further dashboards and custom queries
- **Custom-Queries dashboard**: navigation overview of every `sql-custom` template, grouped and searchable
- **Generic `_generic` dashboard**: any `sql-custom` template can be rendered as a full-page result view without writing a dedicated dashboard — auto-table with sortable columns, type-aware filters, virtual scrolling, scroll-reset on filter change, and full viewport-height usage
- **14 layout primitives** in the frontend (`apps/web/src/dashboard/primitives/`): `Card`, `Grid`, `Row`, `Stack`, `Spacer`, `KPI`, `KPIStrip`, `List`, `Table`, `AutoTable`, `TileGrid`, `NavButton`, `MarkdownBlock`, `Empty` — composable via the layout tree, with token substitution (`{{row.field}}`) for repeating contexts
- **Dashboard backend**: new `dashboard.controller` / `dashboard.service` / `dashboard-schemas` / routes; bundle discovery, manifest validation, dataset resolution from three sources (`bundle:` SQL files, `builtin:` server-provided datasets, `custom:` sql-custom templates), and parameter-bound query execution
- **Built-in datasets**: `list_dashboards`, `list_custom_queries`, `query_meta` — drive navigation and metadata views without per-bundle SQL
- New **`create-custom-dashboard`** skill: guides the user through dashboard creation interactively — clarifies the desired content, drafts SQL queries, shows sample results, suggests a presentation form, and generates the complete bundle directory
- New `sql-custom` templates: `find_undocumented_fields.sql`, `find_unused_scripts.sql`, `list_global_variables.sql`; existing templates (`cross_file_links.sql`, `find_unused_fields.sql`, `script_complexity_stats.sql`) refined for dashboard use
- **`VariablesCatalog` fix**: corrected read-count inflation caused by double-counting variable references from LayoutObject formula hashes — counts now match actual usage across scripts, calculations, and layouts
- **Pseudo object types** (MBS-Components, MBS-Functions): optimizations and fixes for filters and navigation
- **Scripts detail view**: optimizations and fixes
- **Frontend polish**: `SubPageHeader` component for consistent sub-page chrome, `PseudoTokenView` improvements, scroll-reset on filter change in result lists, and full viewport-height layouts across detail views
- Bugfix: CORS handling for plugin settings endpoint

---

Documentation for FM-Lab

## [0.6.10] — 2026-05-15

- **Documentation** — first round of project-level documentation under `docs/fm-lab/` of the public repo. The initial set covers the conceptual layer of fm-lab:
  - `Documentation.md` — top-level index and table of contents
  - `Wiki/Introduction.md` — what fm-lab is and the problem it solves
  - `Wiki/Vision.md` — long-term goal and direction
  - `Wiki/How it works.md` — end-to-end walkthrough from XML ingestion to agentic workflows (with diagrams)
  - `Wiki/Architecture.md` — system architecture and component boundaries (with diagram)
  - `Wiki/Workflow.md` — typical developer workflows on top of fm-lab (with diagrams)
  - `Wiki/Features.md` — feature inventory grouped by capability
  - `Wiki/Components.md` — directory-by-directory tour of the codebase

---

## [0.6.9] — 2026-05-13

Reference-DB distribution via `install-claris-docs` and consolidation of the function-reference skills.

- **`install-claris-docs`** now copies the REST-API reference index DB (`fm_spec.duckdb`) into `docs/claris-help/` — slug-based lookups for functions and ScriptSteps
- **`filemaker-function-reference`** skill rewritten: uses the local DuckDB reference index (373 functions, 206 ScriptSteps, 19 + 13 categories with localized names, signatures, parameters, URL slugs) instead of the legacy SQLite docset; supports multi-language lookups and falls back to the online Claris Help when a slug is missing locally
- **`install-filemaker-docs`** skill marked **deprecated** — replaced by `install-claris-docs` (current Claris Online Help, 11 languages, integrated index DB); kept for backwards compatibility but no longer used by any downstream skill

---

## [0.6.8] — 2026-05-13

Schema-drift detection and auto-healing for the XML import — survives breaking SQL template changes after a `git pull`.

- **Schema versioning** via `@SCHEMA_VERSION` marker in `sql/convert_xml.sql`, persisted in a new `SchemaInfo` table inside the DuckDB catalog
- **Auto-heal (default)** in batch mode: when the import detects schema drift against the existing DB, it automatically drops the DB and rebuilds from all XML files in `xml/`
- **`--force-rebuild`** flag: manual full rebuild, useful after arbitrary inconsistencies or recovery scenarios
- **`--no-auto-heal`** flag: drift only reported, no automatic rebuild (intended for CI and debugging)
- **Single-file mode**: aborts with exit code `6` on drift (auto-heal would discard other files in the catalog) and points the user to `convert-xml --batch --force-rebuild`
- DBs without a version marker are treated as outdated and trigger a rebuild
- Clear diagnostics replace the previous cryptic mid-run DuckDB errors when a `git pull` introduced template changes

---

## [0.6.7] — 2026-05-13

Central reference database, pseudo object types, token-based code rendering, cross-reference highlight, and full dark mode.

- **Central reference database** from `fm-spec`: localized Claris Help cache (English + German) served via a dedicated REST endpoint with language selector — ScriptStep and function reference info available inline in the frontend
- New **`install-claris-docs`** skill: crawls and installs Claris Help locally in one or multiple languages
- **MBS plugin help** served locally alongside Claris Help
- **Pseudo object types** in `ObjectCatalog`: `ScriptStep`, `Function`, `MBS-Component`, and `MBS-Function` registered as first-class catalog entries with type-specific detail templates — searchable and filterable like any other object
- **Token-based code rendering** across all formula contexts:
  - Scripts: token endpoint replaces plain step text — refs, hover popovers, code folding, code filter, inspections popover, viewer header
  - Custom Functions: dedicated `CustomFunctionViewer` with the same token model
  - Calculated / AutoEnter fields: rendered via `CalcTokenSpan` / `FieldViewer` with full token interactivity
- **Cross-reference highlight ("Ref-Mode")**: highlights every occurrence of a referenced object across script bodies, calculations, and reference panels; new back-references API drives navigation
- **Universal function links** in `convert_xml.sql`: built-in functions, plugin functions, and `Get(...)` sub-parameters registered as `ObjectLinks` in correct chunk order — enables exhaustive call-chain queries
- **Field references for every ScriptStep variant**: the parser now resolves field refs across all script-step shapes, not just the canonical ones — eliminates blind spots in dependency queries
- **Pseudo-token filter toolbar** in the references panel with type-aware filtering and search
- **Full dark mode**: `ThemeToggle`, persistent theme preference, themed layout-object and relationship-graph palettes, dark mode extended to Claris/MBS help panels

---

## [0.6.6] — 2026-05-09

Interactive layout view, layout object Z-order in the parser, and rich frontend navigation.

- **Interactive layout view**: new `LayoutCanvas` / `LayoutObjectShape` / `LayoutObjectTooltip` components — visual rendering of layout objects with hover tooltips, type filter (`LayoutTypeFilter`), free-text search, and cross-navigation to fields, scripts, and value lists
- **Layout object Z-order** in `convert_xml.sql`: parser now preserves the stacking order from the XML so the canvas renders objects respecting the original front-to-back hierarchy
- New SQL templates `display_layout_objects_data.sql` and `display_layout_parts_data.sql` powering the layout view; `display_layout_svg.sql` adapted to the new ordering
- **References filter & search** in the detail view: `ReferencesFilter` component to narrow down referenced/referencing objects by type and free-text query
- **Keyboard navigation**: cursor navigation through reference lists and a `useEscapeStack` hook for `ESC` → back navigation across nested views
- **URL-persistent page state**: `useUrlState` hook synchronizes active view, selection, filter, and search into URL parameters — deep-linkable and survives reload

---

## [0.6.5] — 2026-05-08

Relationship graph visualization, extended TableOccurrence schema, enriched script-reference tokens, and plugin documentation API.

- **Extended TableOccurrence data model**: parser now resolves the underlying `BaseTable` reference for every `TableOccurrence` and tracks the home file of each field (relevant for cross-file relationships) — surfaces in `convert_xml.sql` and propagates through `ObjectCatalog` / `ObjectLinks`
- **Schema additions** for graph-aware queries: TO rows carry their resolved base table, fields carry their home file, and relationships expose left/right TO + field metadata in the new graph SQL templates
- **Relationship graph view**: interactive visualization of `TableOccurrences`, fields, and relationships — TO boxes, join lines, automatic graph layout, search field with result selection, and cross-navigation / deep-linking between objects
- Dedicated REST API endpoints for the graph (`relationship_graph_tos.sql`, `relationship_graph_relationships.sql`, `relationship_graph_fields.sql`) with a `relationshipGraph` controller and route
- Web frontend components `RelationshipGraph` / `TOBox` / `JoinLine` and `useGraphSearch` / `useRelationshipGraph` hooks
- **Plugin function documentation API**: new `/plugin-docs` endpoint with HTML extractor and marker-based section parsing for inline help on plugin / MBS function calls
- MBS source service and `plugin-token-registry` for resolving and annotating plugin function references in the token formatter
- **Enriched token output** in `object_references_script.sql`: TableOccurrence info on field references, GTRR (Go to Related Record) target resolution, DDR-calculation token-refs, and additional reference metadata for script steps
- New `build_resolutions.sql` for cross-reference resolution preprocessing

---

## [0.6.4] — 2026-05-07

XML import preprocessor: preserves line breaks in calculation code and tolerates invalid XML control characters.

- Preprocessor integrated directly into `convert_fm_xml.sh`
- Line-break preservation via sentinel `U+2028`: bypasses the `webbed` extension's whitespace collapse (`CleanTextContent`) so original CR/LF in CDATA payloads (Custom Functions, Calculated Fields, AutoEnter calcs, Script steps, Layout-Object formulas) survives the parse — sentinel is replaced back to LF inside `convert_xml.sql`
- Stripping of XML 1.0 invalid C0 control characters (e.g. `Char(3)` embedded in FileMaker scripts) — adresses the `Invalid Input Error: contains invalid XML` abort
- Upstream issue draft prepared for the `duckdb_webbed` maintainer — feature request for option to preserve internal whitespace
- REST-API fix for DB close

---

## [0.6.3] — 2026-05-06

Extended object reference parser: complete coverage of read/write accesses across calculations and plugin calls.

- **Read accesses to fields** in addition to write accesses — full coverage of field references inside any calculation context
- **Layout-object calculations** parsed as references: conditional formatting, hide formula, tooltip, placeholder, and visibility expressions now produce `displays_field` / `reads_variable` / `triggers_script` links
- **CustomFunction call chains**: cross-references between calculations resolved via DDR chunks
- **Plugin function calls** (e.g. MBS Plugin) registered as object references in `ObjectCatalog` / `ObjectLinks`
- **Field → Layout** references for direct on-layout visibility analysis
- Improved layout-box label resolution

---

## [0.6.2] — 2026-05-03

Folder hierarchies as a first-class object type in the catalog.

- New `Folder` object type in `ObjectCatalog`; folders for Scripts, Layouts, and CustomFunctions are registered alongside their leaf objects
- Hierarchical parent/child relationships modeled in `ObjectLinks`
- Dedicated REST API endpoint for folder structures, including type-specific validator and controller
- Detail SQL template `object_details_folder.sql` for the folder view
- New `list_with_folders.sql` custom template
- Web frontend tree view (`FolderTree` / `TreeView` components): browseable folder hierarchy with collapsible nodes
- follow-up optimizations and bugfixes on the folder-based navigation

---

## [0.6.1] — 2026-04-29

Service release: Bugfixes and optimizations.

- Changed npm binding from old 'DuckDB native C++' to new 'DuckDB node-api' interface to prevent installation issues
- Optimizations in init.sh script (verbose mode for npm, Claude settings)
- Optimizations in convert_fm_xml.sh (printf Locale-Fix)
- Changed path references relative to project root
- More robust detection of path to DuckDB CLI and Node cli
- Optimizations in gitignore to prevent conflicts when updating repo from origin

---

## [0.6.0] — 2026-04-22

fmIDE Plugin System: extensible architecture for the REST API and web frontend.

- Plugin interface for registering custom API endpoints and frontend components
- `fmIDE` plugin: opens FileMaker objects directly from the browser via fmIDE
- Settings plugin for persistent per-user configuration
- Plugin code isolated from the main codebase into dedicated module directories
- `install-fmide-docs` skill for local fmIDE documentation
- Consolidated directory structure for `tools/` and `scripts/`

---

## [0.5.0] — 2026-04-17

Public release preparation, AI analysis skills, and dual-database architecture.

- **`fm-summarize`** / **`fm-analyze`** skills: AI-generated technical summaries and semantic analyses of FileMaker objects; `--short` mode for compact output
- **Dual-DB architecture**: master database (`db/fm_catalog.duckdb`) for write access; read-only copy (`rest-api/db/`) for the API server — eliminates file-lock conflicts during parallel import
- Atomic sync mechanism: after each import the copy is updated and the server is hot-reloaded via `POST /api/admin/reload` without a full restart
- Shell scripts `rest-api-start` / `rest-api-stop` / `rest-frontend-start` / `rest-frontend-stop`
- Publish script for preparing the public release
- Project renamed to **fm-lab**

---

## [0.4.0] — 2026-03-27

XML import improvements: robust parsing, AutoEnter fields, and full variable tracking.

- Parser for `AutoEnter` fields: lookup details (source field, relationship TO), calculated auto-enter values, and constant defaults
- Robust JSON parser for special character escaping, integrated directly into SQL (no external Python step)
- Parser for `Calculation_Text` extracted from CDATA sections
- Automatic skipping of outdated SaXML v2.0 format (FileMaker 18.x) with a warning
- **`VariableUsages` / `VariablesCatalog`**: full variable parser detecting local, global, and MBS superglobal variables from script steps, DDR chunks, auto-enter formulas, and layout merge variables
- `install-ooe-fm` and `install-fm-xml-export-exploder` skills for reference data setup
- `duckdb-skills:duckdb-docs` skill for in-terminal DuckDB documentation lookup

---

## [0.3.0] — 2026-02-12

Browser-based web frontend for interactive exploration of the FileMaker analysis.

- Search across all object types with filters by file and type, sorting, and grouping
- Infinite / virtual scrolling for large result sets (chunk-based), search-as-you-type
- Detail view for all object types with 5-tab sub-navigation
- Graph view for object relationships (Mermaid-based)
- Layout SVG preview: visual representation of layout object structures
- REST API `/api/get-details` endpoint with type-specific SQL templates for all object types
- Vite-based dev server; shared `packages/shared` library between frontend and API (npm workspaces monorepo)
- OpenAPI specification as single source of truth; TypeScript types auto-generated

---

## [0.2.0] — 2026-01-26

Multi-file support, universal object catalogs, and REST API.

- **Multi-file support**: all tables extended with a `File_Name` column; multiple XML files importable into one shared database
- **`ObjectCatalog`**: central registry for all 25+ object types across all imported files
- **`ObjectLinks`**: 31 implemented link types (operational dependencies + structural container hierarchies), including cross-file links
- **`FilesCatalog`**: metadata for all imported FileMaker files
- **DDR-Info support** (FileMaker 21+): optional `DDR_ScriptSteps` and `DDR_Calculations` tables; `DDR_Hash` as a JOIN key to calculated fields and custom functions
- REST API (Express.js): `/api/search`, `/api/search/count`, `/api/count`, `/api/info`, `/api/query`
- SQL template system with `getvariable('param')` interpolation; separate folders for report and custom templates
- Case-insensitive search and parameter handling
- `filemaker-script-erzeugen` skill: creates FileMaker scripts in `fmxmlsnippet` format with automatic backup management
- `install-mbs-docs` / `install-filemaker-docs` skills for local documentation setup
- Batch import with fail-fast flag, timing output, and extended error logging

---

## [0.1.0] — 2026-01-13

Initial release: XML conversion pipeline, core database structure, and first AI skills.

- Conversion script `convert_xml.sql` covering all major FileMaker object types: base tables, fields, scripts, script steps, layouts, layout objects (22 types, 4 nesting levels), value lists, accounts, relationships, and more — 30 tables total
- `XMLMetadata` table with FileMaker version and DDR-Info status
- Sample queries (`sql/sample_queries.sql`) as an entry point for ad-hoc analysis
- **`convert-xml`** skill: converts one or all XML files (`--batch`) and manages the import lifecycle
- **`mbs-function-reference`** skill: looks up MBS Plugin functions in a local documentation database
- **`skill-creator`** skill: guided workflow for creating new Claude Code skills

---

<!-- Link references. compare-ranges span adjacent tagged releases; documentation-only
     versions that were never tagged (e.g. 0.8.7, 0.8.1, 0.8.0, 0.7.5–0.7.7, …) are
     intentionally left unlinked and render as plain text. Add a line here per new tag. -->
[Unreleased]: https://github.com/marcel-more/fm-lab/compare/v0.9.10...HEAD
[0.9.10]: https://github.com/marcel-more/fm-lab/compare/v0.9.9...v0.9.10
[0.9.9]: https://github.com/marcel-more/fm-lab/compare/v0.9.8...v0.9.9
[0.9.8]: https://github.com/marcel-more/fm-lab/compare/v0.9.7...v0.9.8
[0.9.7]: https://github.com/marcel-more/fm-lab/compare/v0.9.6...v0.9.7
[0.9.6]: https://github.com/marcel-more/fm-lab/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/marcel-more/fm-lab/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/marcel-more/fm-lab/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/marcel-more/fm-lab/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/marcel-more/fm-lab/compare/v0.9.0...v0.9.2
[0.9.0]: https://github.com/marcel-more/fm-lab/compare/v0.8.11...v0.9.0
[0.8.11]: https://github.com/marcel-more/fm-lab/compare/v0.8.10...v0.8.11
[0.8.10]: https://github.com/marcel-more/fm-lab/compare/v0.8.9...v0.8.10
[0.8.9]: https://github.com/marcel-more/fm-lab/compare/v0.8.8...v0.8.9
[0.8.8]: https://github.com/marcel-more/fm-lab/compare/v0.8.6...v0.8.8
[0.8.6]: https://github.com/marcel-more/fm-lab/compare/v0.8.5...v0.8.6
[0.8.5]: https://github.com/marcel-more/fm-lab/compare/v0.8.4...v0.8.5
[0.8.4]: https://github.com/marcel-more/fm-lab/compare/v0.8.3...v0.8.4
[0.8.3]: https://github.com/marcel-more/fm-lab/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/marcel-more/fm-lab/compare/v0.7.4...v0.8.2
[0.7.4]: https://github.com/marcel-more/fm-lab/compare/v0.7.3...v0.7.4
[0.7.3]: https://github.com/marcel-more/fm-lab/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/marcel-more/fm-lab/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/marcel-more/fm-lab/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/marcel-more/fm-lab/compare/v0.6.9...v0.7.0
[0.6.9]: https://github.com/marcel-more/fm-lab/compare/v0.6.7...v0.6.9
[0.6.7]: https://github.com/marcel-more/fm-lab/compare/v0.6.6...v0.6.7
[0.6.6]: https://github.com/marcel-more/fm-lab/compare/v0.6.5...v0.6.6
[0.6.5]: https://github.com/marcel-more/fm-lab/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/marcel-more/fm-lab/compare/v0.6.1...v0.6.4
[0.6.1]: https://github.com/marcel-more/fm-lab/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/marcel-more/fm-lab/releases/tag/v0.6.0
