# Components

The repository is organized into separate sections for the different components and tasks within the overall workflow.

- [Ingestion pipeline](#ingestion-pipeline)
- [FileMaker Reference](#filemaker-reference)
- [REST API](#rest-api)
- [Web Client](#web-client)
- [Tools](#tools)
- [Docs](#docs)
- [Agent framework](#agent-framework)
- [Settings](#settings)
- [Local servers](#local-servers)

Refer to [Folder structure](Folder%20structure.md) for a detailed map.

---

## Ingestion pipeline

This part converts your solution's XML description into a generic object model inside a DuckDB database. Refer to [katana-engine](katana-engine.md) for a more detailed breakdown of the ingestion process.

### XML (Input)

`solutions/<id>/xml/` — FileMaker XML exports (SaXML) from your solution, prepared for conversion.

The folder can contain multiple files belonging to the same solution.

### Katana XML engine

`ingestion/convert_fm_xml.sh` — Runs XML batch conversion and accepts CLI options.

### SQL Templates

`ingestion/sql/` — Conversion and [parser templates](../templates/Ingestion%20Pipeline%20%28XML%20Import%29.md) for universal catalogs.

This is the main ingestion logic and is executed by the DuckDB CLI, which must be installed beforehand.

### DuckDB Catalog

`solutions/<id>/db/fm_catalog.duckdb` — The generated DuckDB database containing the extracted FileMaker objects and their relationships.

A separate catalog is populated for each solution during XML conversion.

---

## FileMaker Reference

Reference tables for FileMaker script steps, calculation functions and script-trigger events. They include machine-readable syntax and grammar definitions for linting during code generation, plus an additional mapping layer from script step names to distinct tokens and to emitter templates in multiple output formats. They also support up to 11 locales for translations into human language.
Refer to detailed description of [fm-spec](fm-spec.md) content and schema.

### fm-spec

`reference/fm_spec.duckdb` — DuckDB database containing reference information about FileMaker script steps and functions.

The reference table also maps to optional [doc sets](#docs) with links to the official documentation of FileMaker and supported plugins.

---

## REST API

Core module that allows external consumers to query structured information from the DuckDB object catalog. It also provides different service endpoints to the stack's base functions, and emits information aligned to the internal schema model in different pre-defined [output formats](../rest-api/REST%20API%20Output%20Formats.md).
Refer to detailed [REST API Overview](../rest-api/REST%20API%20Overview.md).

- `rest-api/` — Express server for HTTP access to the analysis database.
- `rest-api/db/solutions/<id>/fm_catalog.duckdb` — DuckDB database copy for exclusive, read-only access by the REST API.
- `rest-api/templates/dashboards/` — All shipped dashboards: the app pages under `system/` (home, file details, XML import), the overview and index pages of the modules under `modules/` (dashboards, tests, docs), and the content dashboards in their rubric folders (`static-code-analysis/`, `modularization/`, `developer-workflow/`, `metadata-integrity/`, `changelog/`, plus `health_hints/`) — bundles and, in `layouts/`, `scripts/`, `schema/`, `top/` and `metadata-integrity/`, [single-file dashboards](../templates/Single-file%20Dashboards.md).
- `rest-api/templates/dashboards/static-code-analysis/` — Dashboard bundles for static code analysis, inspired by the PMD standard ruleset. They are accessible through the web frontend and provide quick access to different code metrics. All dashboards support drill-down filters and interactive navigation to code references within the object browser.
- `rest-api/templates/dashboards-custom/` — Your own dashboards, bundles and single-file dashboards (user space, ignored by git and never touched by updates), listed in the overview under **Custom**. Create them with the [create-custom-dashboard](../skills/Skill%20create-custom-dashboard.md) skill.
- `rest-api/templates/dashboards-community/` — Installation target for community packages, listed under **Community** once it holds dashboards.
- `rest-api/templates/queries/` — Internal SQL templates the server and the web client call by name: `system/` ([system templates](../templates/Built-in%20Query%20Templates.md) of `/api/report`) and `modules/` ([module templates](../templates/Detail%20View%20Templates.md) of `/api/query`). Not listed, not overridable.
- `rest-api/templates/tests/` — Declared [Analysis Tests](Analysis%20Tests.md) bundled with the installation.
- `rest-api/templates/tests-custom/` — Your own tests (user space, ignored by git and never touched by updates), listed under **Tests / Custom**. Create them with the [create-custom-test](../skills/Skill%20create-custom-test.md) skill.
- `rest-api/templates/tests-community/` — Installation target for community test packages.

---

## Web Client

Rich browser-based interface for application-level functions and for [Interactive exploration](4%20Code%20Analysis%20Approaches.md#1-interactive-exploration) of the solution's object catalog. Most of FM-Lab's features are fully supported in the web interface (except agentic workflows).

Besides the object browser, dashboards and Graph Explorer, the web client includes an interactive [fm-spec](fm-spec.md) schema browser (`/fm-spec`, with detail pages per script step and per function).

`apps/web/` — React/Vite frontend

### Dashboard overview

The overview at `/dashboard` lists every content dashboard — bundles and [single-file dashboards](../templates/Single-file%20Dashboards.md) alike: the shipped rubrics (Static Code Analysis, Modularization, Metadata Integrity, Developer Workflow, Changelog, Layouts, Scripts, Schema, Top) with the Healthchecks entry point on top, then the area folders **Custom** — your own dashboards from `rest-api/templates/dashboards-custom/`, shown even while empty with a hint to [create-custom-dashboard](../skills/Skill%20create-custom-dashboard.md) — and **Community**, shown once it holds dashboards. A custom dashboard that replaces a shipped one with the same id carries the badge *overrides standard*; one still read from the former query folder `sql-custom/` carries *old location*. A single-file dashboard has no severity: its status columns stay empty, and *#* shows its declared result with the meaning as tooltip — for an inventory that is a row count, not a number of defects. The former query pages redirect for one release: `/query` → `/dashboard`, `/query?category=Layouts` → `/dashboard?folder=layouts`, `/query/<name>` → `/dashboard/<name>`. System and module pages (home, file details, the overview pages themselves, docsets) are reached through the main navigation and do not appear here (see [Areas and overrides](../templates/Dashboard%20Datasets.md#areas-and-overrides)).

A view selector above the list switches between three views; the overview opens in the list. The choice is part of the URL (`?view=folders|list|favorites`) and is remembered for links without it: each browser tab keeps its own view, and a new tab opens with the view you chose last.

| View | What it shows |
|---|---|
| **Folders** | One tile per folder with its entry counts — *direct entries (dashboards in total)*, direct entries being sub-folders plus dashboards — and the status aggregate of its subtree; a click opens the folder (`?folder=<path>`), the breadcrumb leads back. Tiles keep the standard order. The Healthchecks entry point spans the full width above the folders. |
| **List** | A hierarchical list with the columns name · ● error · ▲ warning · ✓ OK · ◦ neutral · # findings (per dashboard its result, per folder the sum). A click on a folder row expands it, a double click or `Enter` opens it as the new root, a click on a dashboard row opens the dashboard; arrow keys move through the rows. Below 640 px the four status columns fold into one. The **Healthchecks** row on top is a sum row: pulse icon, accent background, the number of rules and, in the status and findings columns, the totals over every rubric it covers. |
| **Favorites** | Your favorite dashboards as a flat list with the same columns and the rubric path under each title (see below). |

While rules of the Healthchecks have not been computed yet, a glowing dot runs along the pulse icon — in the folders view and in the list (no animation when the system asks for reduced motion).

All three views share the status filter, the object-type filter, the search and **Run all**. Results are computed on demand: opening a folder — or expanding one folder in the list — with up to 32 pending results computes them automatically; larger sets wait for **Run all**.

**Sorting.** In the list and the favorites view a click on a column header sorts by that column: **Name** (the standard order: folders by their configured order, dashboards by title), **●**, **▲**, **✓**, **◦** (per folder the number of dashboards in that state, per dashboard whether it has it) and **#** (findings). The first click sorts names ascending and counts descending, the second click reverses the direction, the third returns to *Name ↑*; the active header shows ↑ or ↓. Entries without a result stay at the end in both directions. The tree stays intact: only entries of the same level move, folders stay above dashboards and Healthchecks stays on top. Below 640 px the combined status column sorts by the worst state. In the favorites view the first header is split into **Name | Module** — *Module* groups the favorites by rubric (entries without a rubric first). The sort order is part of the URL (`?sort=findings-desc`, `?sort=error-desc`, …); changing it adds no "back" step. The folders view always keeps the standard order.

**Expand all / collapse all.** In the list, two buttons next to the entry count open or close every folder of the shown tree. Expanding all computes nothing — use **Run all** for that. Collapsing keeps the root row of a folder you opened with a double click. In a filtered tree (search, status or object type) both act only on the current view.

**Remembered folders.** The list remembers which folders are open — within a tab across reload and returning from a dashboard, and as the starting state of every new tab, also after a browser restart. Open tabs never change each other: a new tab starts with the list you operated last. Folders added since then start closed. Folding a folder during a search or filter, or the root row of a folder opened with a double click, is not remembered. The state is stored in the browser, separately for `/dashboard` and `/tests`.

**Object-type filter.** The menu in front of the search field narrows the overview to the dashboards that check one object type — *Script (89)*, *Layout (42)*, … with the number of dashboards per type, plus *Without object type* for dashboards without object rows (change dashboards, statistics). Like the search it works across all folders: the folders view shows the matches with their rubric path, the list a filtered tree, the favorites view the matching favorites; it combines with the search and the status filter. The choice is part of the URL (`?type=Script`). The types come from each bundle's declaration `analysis.objectTypes` (see [Object types](../templates/Dashboard%20Datasets.md#object-types)), so the filter works before anything has been computed.

**Cleaning up after an update.** Earlier versions kept the app pages directly in `rest-api/templates/dashboards/`, the shipped rubrics in `rest-api/templates/dashboards-custom/` and the queries in `rest-api/templates/sql-custom/`. `git pull` removes the old shipped copies there; if it stops at a file you edited, [one command](Troubleshooting.md#update-stops-local-changes-would-be-overwritten) saves your version and completes the update. At its first start after the update the REST API tidies up by itself: your own dashboards and queries from old places move to `dashboards-custom/` (they then appear under **Custom**), the old copies to `rest-api/templates/dashboards-removed/<timestamp>/`. An old copy you edited lives on as an own version — `<id>-local` under **Custom**, title suffix *(own version)* — and so does a shipped dashboard or test that [the update command](Installation.md#updating-fm-lab) had to put back. Nothing is deleted; you can delete the folder's content once you no longer need it. The overview reports the result once above the list; **Close** hides it. `STARTUP_CLEANUP_ENABLED=false` in `rest-api/.env` turns the automatic run off.

Leftovers that appear later — for example after an update by copying files — show the hint *N dashboard folders from an earlier version are still in old places* (for queries *… and N queries at old locations*). *Show details* lists every move; **Clean up** runs the same cleanup by hand. An edited old copy can be left in place by unticking it — it may then block the next update, so prefer its own version under **Custom**. A clean installation never shows the hint (see [Maintenance API](../rest-api/endpoints/Maintenance%20API.md)).

**Favorites.** A star marks a content dashboard as a favorite: outline = not a favorite, filled = favorite; a click toggles it. It sits at the right end of a dashboard's title row, in the top-right corner of every dashboard tile in the folders view (folder tiles have none) and in the last column of the list view (dashboard rows only). In the overview, filled stars always show, outline stars appear while you point at a tile or row (on touch devices always). The favorites view removes an entry through the star at the end of its row or the `Delete` key — the confirmation message offers *Undo*. **Run all** there runs exactly the shown favorites, and up to 32 pending favorites are computed automatically. A favorite whose dashboard was deleted or renamed appears as a hint (*1 favorite is no longer available — remove*) instead of a row. Favorites are stored workspace-wide in `.fmlab/favorites.json` (excluded from git): every browser sees the same list, it stays the same when you switch solutions, and another open tab picks up a change as soon as it becomes visible again (see [Favorites API](../rest-api/endpoints/Favorites%20API.md)).

### Test overview

The overview at `/tests` lists every [Analysis Test](Analysis%20Tests.md) with the same controls as the dashboard overview: a view selector **Folders | List | Favorites** (`?view=`, opens in the list; view and open folders are remembered the same way), the entry count, *Expand all / Collapse all* (list only), the object-type menu and the search. The folders are the shipped rubrics (Layout, Platform, Script, Solution), then **Custom** — your own tests from `rest-api/templates/tests-custom/`, shown even while empty with the hint *No custom tests yet. Create your own with /create-custom-test.* — and **Community** once it holds tests.

| Column | Content |
|---|---|
| **Name** | folder (count) or test title; badge *overrides standard* for a custom test with a shipped id |
| **Test type** | Exploration · Code quality · Error check · Security · Inventory · Performance · Platform (hidden below 640 px) |
| **Members** | number of member dashboards; per folder the total |
| **Status** | state of the last solution-scope run (● error, ▲ warning, ✓ OK, ◦ neutral); empty = never run; per folder the worst state and how many tests have run (`2/6`) |
| ☆ | favorite star |

Every column sorts (`?sort=`), the list shows no descriptions (they are the tile tooltip and are searched). Tests do not run from the overview — open one at `/tests/<id>`, use the object tab **Tests** or `/fm-test <id>`; the status column fills from those runs. The star also sits at the top right of a test's detail page; the favorites view (*Name | Folder*) works as for dashboards and keeps its own list (see [Favorites API](../rest-api/endpoints/Favorites%20API.md)). After an update the REST API moves leftovers out of the shipped `tests/` folder at its first start — your own tests to `tests-custom/`, old copies to `tests-removed/<timestamp>/`, a shipped test you edited to `tests-custom/<id>-local` — and the overview reports it once; leftovers that appear later show a hint box with **Clean up** (see [Test cleanup](../rest-api/endpoints/Maintenance%20API.md#test-cleanup)).

---

## Tools

- `tools/` — Utility scripts for various tasks.
- `tools/fmlab.sh` — Wrapper for starting FM-Lab through Docker or the native CLI.
- `tools/init.sh` — Initializes the project on first run by installing npm packages and configuring paths and default settings. It includes a preflight check for dependencies and expected versions.
- `tools/bootstrap.sh` — Shared, idempotent bootstrap steps used by both the native init and the Docker setup, so the two can never drift.
- `tools/solution.sh` — Multi-solution control tool: lists, creates and switches solution bundles (pointer file, workspace symlinks, running API). Backend of the `select-solution` skill.
- `tools/migrate-multisolution.sh` — One-time, idempotent migration of a flat legacy workspace to the multi-solution bundle layout.
- `tools/install_modes.sh` — Shared helpers sourced by all doc-set installer skills.
- `tools/start-servers.sh` — Starts the included HTTP servers.
- `tools/stop-servers.sh` — Stops the included HTTP servers.

---

## Docs

Central storage for internal and external documentation. Some doc sets are provided with the installation. Others can be downloaded on demand as a cached memory layer for fast lookups by agents and humans.

- `docs/` — Documentation files for FileMaker Pro and MBS plugin functions, installable through the web frontend or Claude skills.
- `docs/fm-lab/` — Location of this documentation.
- `docs/agents/` — Workflow and schema documentation referenced by CLAUDE.md.
- `docs/claris-help/` — Official FileMaker Pro documentation files, installable on demand in one or more local languages.
- `docs/mbs/` — Official documentation files for MBS plugin functions, installable on demand.
- `docs/fmIDE/` — Official documentation files for fmIDE, installable on demand.
- `docs/.../` — Optional documentation files, installable on demand.

Installing the basic documentation set is highly recommended. It provides inline help for the web client and grounded reference material for agentic workflows.

Some documentation packages include their own databases for fast indexed queries. The Claris and MBS documentation also provides dynamic context by mapping documentation entries to scripts and calculations in your solutions. These references are available for drill-down navigation and cross-referencing through the web frontend.

---

## Agent framework

### Claude System Prompt

`CLAUDE.md` defines the Claude system prompt. It provides project context, describes the ingestion pipeline and workflows, establishes operational rules, and references the supporting documentation in `docs/agents/`.

### Claude Skills

`.claude/skills/` contains Claude Code skills and slash commands for installation, conversion, lookup, analysis, and code generation.

Each bundled skill has its own reference page with invocation, options and prerequisites — see [Skills](../skills/Skills.md).

**Setup**

- `.claude/skills/install-claris-docs` — Installs the Claris FileMaker documentation.
- `.claude/skills/install-mbs-docs` — Installs the MBS plugin documentation.
- `.claude/skills/install-fmide-docs` — Installs the fmIDE documentation.
- `.claude/skills/install-duckdb-docs` — Installs the DuckDB documentation.
- `.claude/skills/select-solution` — Switches the active solution (pointer file, workspace symlinks and running API) via `tools/solution.sh`.

**Optional tools**

- `.claude/skills/skill-creator` — Helps you build your own skills that extend the agentic workflow.

**XML conversion**

- `.claude/skills/convert-xml` — Runs the XML conversion with checks and configuration options.

**Agentic analysis**

- `.claude/skills/fm-show` — Shows details or references for a given object in the web frontend.
- `.claude/skills/fm-trace` — Opens the selective flow graph (trace mode of the Graph Explorer) for a script or layout: call chain, touched objects, and triggers.
- `.claude/skills/fm-open` — Opens a given object directly in your FileMaker Solution through the fmIDE `Name that Thing API`.

- `.claude/skills/fm-summarize` — Creates a concise technical briefing for a given object.
- `.claude/skills/fm-analyze` — Runs an in-depth object analysis using semantic signals and recursive graph traversal up to five levels deep. It gathers context about dependencies, structure, logic, technical rules, and semantic meaning. This helps the agent explain functionality and business rules within the solution.
- `.claude/skills/fm-graph-cluster` — Segments the FileMaker object graph into functional clusters (communities) using [Graph analysis](4%20Code%20Analysis%20Approaches.md#3-graph-analysis) algorithms.
- `.claude/skills/fm-deep-research` — Writes a solution-level research report (executive summary, business context, architecture, technical description, findings, recommendations, segment appendix) from the clustered graph and the member objects of its largest segments, rendered from a Markdown template.
- `.claude/skills/fm-changes` — Writes release notes from the change stamps: what changed since a date, in a work session or by a person, grouped by file and module with a short description per object, rendered from a Markdown template.
- `.claude/skills/fm-test` — Runs curated [Analysis Tests](Analysis%20Tests.md) (static-code-analysis rules and custom checks with a compact result model) in solution, file, object or cluster scope; `--find` discovers matching tests without running them.
- `.claude/skills/create-custom-test` — Builds an own [Analysis Test](Analysis%20Tests.md) from existing dashboards: proposes the members, validates the `test.json` and runs it once.

- `.claude/skills/create-custom-dashboard` — Helps you build a new custom dashboard for [Static code analysis](4%20Code%20Analysis%20Approaches.md#2-static-code-analysis) by describing its goals in plain language — as a single-file dashboard or as a bundle.

**Agentic code generation**

- `.claude/skills/fm-generate-script` — Provides reference-driven FileMaker script generation. It includes a seven-phase validation pipeline with linting against machine-readable FileMaker syntax and grammar definitions. It also maps referenced object IDs to known objects in the solution's DuckDB catalog. This produces robust, context-aware generated code artifacts.

**Lookup documentation and explain features**

- `.claude/skills/filemaker-function-reference` — Looks up Claris FileMaker documentation through a fast and reliable local cache and database index.
- `.claude/skills/mbs-function-reference` — Looks up MBS plugin documentation through a fast and reliable local cache and database index.

### Scripts (Output)

`scripts/` — Reserved for generated FileMaker scripts produced by agentic coding workflows.

---

## Settings

### Plugin registry

`.fmlab/` — Registry and preferences for FM-Lab: the plugin registry, the installed doc-set catalog, the active-solution pointer, server settings and the converter's persisted parser-policy state.

---

## Local servers

### REST API

Provides a local HTTP server at `http://localhost:3003`

Manual start:
Use this option for custom setups, such as running the REST APl as a standalone service.

```bash
cd rest-api
cp .env.example .env   # adjust ports if needed
npm run dev
```

### Web Client

Provides a local HTTP server at `http://localhost:5173`

**Automatic startup**
Both servers are started and stopped with the corresponding scripts:
`tools/start-servers.sh`
`tools/stop-servers.sh`

**Important**
npm dependencies and shared packages must be set up in advance by the init script:
`tools/init.sh`

**Manual startup**
Use this option for active frontend development only.

```bash
cd apps/web
cp .env.example .env   # adjust VITE_API_URL if API runs on a different port
npm run dev
```
