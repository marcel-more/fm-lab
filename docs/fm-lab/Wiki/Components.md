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
- `rest-api/templates/dashboards/` — Dashboard bundles for standard views exposed through API endpoints.
- `rest-api/templates/dashboards-custom/` — Additional dashboard bundles for custom use cases. These can be generated using a Claude Code skill.
- `rest-api/templates/dashboards-custom/static-code-analysis/` — Dashboard bundles for static code analysis, inspired by the PMD standard ruleset. They are accessible through the web frontend and provide quick access to different code metrics. All dashboards support drill-down filters and interactive navigation to code references within the object browser.
- `rest-api/templates/sql/` — [SQL templates](../templates/Built-in%20Query%20Templates.md) for standard queries exposed through API endpoints.
- `rest-api/templates/sql-custom/` — [Additional SQL templates](../templates/Custom%20Query%20Templates.md) for custom use cases.
- `rest-api/templates/tests/` — Declared [Analysis Tests](Analysis%20Tests.md) test sets bundled with the installation.
- `rest-api/templates/tests-custom/` — User-defined test sets (user space, not overwritten by updates).

---

## Web Client

Rich browser-based interface for application-level functions and for [Interactive exploration](4%20Code%20Analysis%20Approaches.md#1-interactive-exploration) of the solution's object catalog. Most of FM-Lab's features are fully supported in the web interface (except agentic workflows).

Besides the object browser, dashboards and Graph Explorer, the web client includes an interactive [fm-spec](fm-spec.md) schema browser (`/fm-spec`, with detail pages per script step and per function).

`apps/web/` — React/Vite frontend

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

- `.claude/skills/install-ooe-fm` — Installs OOE references as a test suite for the XML converter. This component is entirely optional and not used elsewhere in the project.
- `.claude/skills/install-fm-xml-export-exploder` — Installs XML Export Exploder for reference purposes and local testing. This component is entirely optional and not used elsewhere in the project.
- `.claude/skills/skill-creator` — Helps you build your own skills that extend the agentic workflow.

**XML conversion**

- `.claude/skills/convert-xml` — Runs the XML conversion with checks and configuration options.
- `.claude/skills/test-convert-xml` — Runs a test conversion against the OOE references.

**Agentic analysis**

- `.claude/skills/fm-show` — Shows details or references for a given object in the web frontend.
- `.claude/skills/fm-trace` — Opens the selective flow graph (trace mode of the Graph Explorer) for a script or layout: call chain, touched objects, and triggers.
- `.claude/skills/fm-open` — Opens a given object directly in your FileMaker Solution through the fmIDE `Name that Thing API`.

- `.claude/skills/fm-summarize` — Creates a concise technical briefing for a given object.
- `.claude/skills/fm-analyze` — Runs an in-depth object analysis using semantic signals and recursive graph traversal up to five levels deep. It gathers context about dependencies, structure, logic, technical rules, and semantic meaning. This helps the agent explain functionality and business rules within the solution.
- `.claude/skills/fm-graph-cluster` — Segments the FileMaker object graph into functional clusters (communities) using [Graph analysis](4%20Code%20Analysis%20Approaches.md#3-graph-analysis) algorithms.
- `.claude/skills/fm-deep-research` — Writes a solution-level research report (executive summary, business context, architecture, technical description, findings, recommendations, segment appendix) from the clustered graph and the member objects of its largest segments, rendered from a Markdown template.
- `.claude/skills/fm-test` — Runs curated [Analysis Tests](Analysis%20Tests.md) (static-code-analysis rules and custom checks with a compact result model) in solution, file, object or cluster scope; `--find` discovers matching tests without running them.

- `.claude/skills/create-custom-dashboard` — Helps you build a new custom dashboard for [Static code analysis](4%20Code%20Analysis%20Approaches.md#2-static-code-analysis) by describing its goals in plain language.

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
