# FM-Lab: AI Agent Coding Harness for FileMaker

Reliable FileMaker development starts with a shared understanding of FileMaker principles and the structure of the solution at hand — for both humans and AI agents.

FM-Lab provides that foundation by converting **FileMaker SaXML exports** into a queryable **DuckDB** catalog. It turns the XML structure of a FileMaker solution into a fast, in-memory digital twin — covering all object types and their dependencies — for deep cross-reference analysis, documentation, and AI-assisted development at scale.

![FM-Lab](Banner.jpg)

**[⚡ QUICKSTART](#-quickstart)** — from clone to catalog in one command.

## Highlights

> “Using **agentic analytics** with FM-Lab feels less like searching through metadata and more like asking a senior developer who already understands the structure of the solution in every little detail.”

> “DuckDB is a key enabler here. Its role in this architecture is hard to overstate. It turns code analysis from digging through static files into querying a live map of the solution in memory. **This RAM-accelerated, in-process architecture** removes the drag of disk-heavy workflows and makes **deep catalog and graph analysis** practical.”

> “The Katana-XML engine delivers **a major leap in conversion speed**, making large FileMaker catalogs practical to analyze interactively in fast iteration cycles.”

## Prologue

FileMaker development is facing a new paradigm: **solution structure must be readable and understandable by both humans and AI agents**. While many major programming environments have well-established ecosystems for code analysis, documentation and refactoring, FileMaker's proprietary format makes it hard to participate in that ecosystem — there is no native API to query a solution's structure programmatically.

Several tools try to bridge this gap. Some serve human developer workflows very well, but many are not designed for scalable, agent-driven analysis or open extension. Most are closed source, which limits their adaptability in a rapidly evolving landscape.

This project takes a different approach. It converts the structure of a FileMaker solution — exported as SaXML — into a queryable DuckDB database. The relevant object types (scripts, fields, layouts, relationships, value lists, and more) land in dedicated tables, with **a universal catalog that links objects and their dependencies across the entire solution**. DuckDB's in-process engine makes this catalog fast enough for both interactive queries and **AI-driven analysis at scale**, without any database server setup. A REST API and a web client provide additional access layers for GUI and integration workflows.

The first release focuses on this core: reliable **XML conversion**, a comprehensive **object catalog,** and a modular architecture that is open source and **designed for extension**. Future releases will build on this foundation — the long-term goal is to become a solid developer tooling platform for the FileMaker space.

**Addendum:** [Claris has announced upcoming agentic coding functionality for FileMaker](https://www.claris.com/blog/2026/how-claris-is-building-for-what-comes-next) for the upcoming releases. This does not contradict the goals of this project, but rather emphasizes the need for a solid foundation for code analysis and tooling in the FileMaker ecosystem. The architecture of fm-lab is designed to be flexible and adaptable, so it can integrate with Claris's AI coding features as they evolve, while also providing value to developers who want to leverage AI tools in their workflows today.

## Analysis workflows

FM-Lab supports [four complementary approaches](/docs/fm-lab/Wiki/4%20Code%20Analysis%20Approaches.md) to analyzing a FileMaker solution:

- **Interactive exploration** - browse the solution through a web frontend with rich navigation, visualizations, and drill-down views
- **Static code analysis** - detect known patterns, issues, and structural signals through targeted catalog queries
- **Graph-based analysis** - inspect object relationships using graph algorithms, visual maps, and LLM-assisted reasoning
- **[Agent-based analysis](/docs/fm-lab/Wiki/Workflow.md#agentic-code-analytics)** - give AI agents direct, structured access to the knowledge graph, metadata, and documentation context

## Features

- **XML Ingestion Pipeline** — converts FileMaker XML exports into a DuckDB database using a flexible SQL template system, designed for easy maintenance and updates as FileMaker evolves ♻️
- **Katana-Engine** — XML chunking and streaming for processing massive catalogs with minimal memory usage and maximum parallelism 🔪
- **Detailed Object Catalog** — detailed tables for the relevant FileMaker object types, combined with a universal catalog that links objects and their dependencies for fast cross-reference queries 🔗
- **Detailed Reference Catalog** — localized reference tables for documented FileMaker script steps and functions, enabling linting and inline help across up to 11 locales 📄
- **DuckDB Backend** — in-process analytical database engine for fast and flexible queries without server setup, often delivering results in milliseconds, even for large solutions 🚀
- **REST API** — Express server providing HTTP access to the analysis database, enabling integration with external tools and services 🧩
- **Web Client** — React/Vite frontend for interactive exploration of the solution structure and dependencies with rich visualizations 🔎
- **Dashboard System** — library of predefined analysis patterns, with support for custom queries and custom dashboards 📁
- **Analysis Tests** — curated, declared checks with a compact result model: static-code-analysis rules, error checks and two-axis platform tests, runnable per solution, file, object or cluster ✅
- **Multi-user & multi-session support** - concurrent users, each on their own solution 🙌
- **Graph Explorer** — interactive navigation of the full object graph, with automatic community detection that reveals named clusters across the solution and turns thousands of objects and links into a navigable graph map 🕸️
- **Claude Skills** — slash commands for agentic analysis workflows in Claude Code, supported by helpers for XML conversion and documentation setup, enabling deep, solution-aware inspection beyond scripted analysis 🤖
- **Comprehensive Docs** — easy-to-install documentation for FileMaker Pro and MBS plugin functions 📚
- **Plugin System** — open architecture for adding new tools and integrations, starting with **[fmIDE](https://github.com/fmIDE/fmIDE)** as a first-class citizen to provide direct navigation into FileMaker's Script Workspace 🛠️
- **AI Code Generation** — architecture and data model built for AI-driven code generation: every generated artifact is grounded in reliable context from the object catalog and validated against the integrated machine-readable FileMaker syntax and grammar through a multi-step validation pipeline 🧠

## [Architecture](docs/fm-lab/Wiki/Architecture.md)

[![Architecture](docs/fm-lab/Assets/FM-Lab-base-Architecture.jpg)](docs/fm-lab/Wiki/Architecture.md)

```
SaveAsXML → Parser → DuckDB → REST API ←→ Tools
                                       ←→ UI
                                       ←→ AI Agent
```

## [How it works](docs/fm-lab/Wiki/How%20it%20works.md)

Learn how FM-Lab turns FileMaker XML exports into a structured Object Catalog and uses it as the foundation for analysis, documentation lookup, and agentic workflows. [The walkthrough](docs/fm-lab/Wiki/How%20it%20works.md) explains the layers of the stack, the flow from ingestion to interaction, and why this architecture is different from simple text-based RAG approaches.

## [Components](docs/fm-lab/Wiki/Components.md)

- **SQL Templates** (`sql/`) — Conversion templates and parser templates for universal catalogs.
- **REST API** (`rest-api/`) — Express server for HTTP access to the analysis database.
- **Web Client** (`apps/web/`) — React/Vite frontend
- **Solution Bundles** (`solutions/`) — One or multiple FileMaker solutions to explore. Each solution lives in its own bundle `solutions/<id>/` (XML inbox, database, state); `default` exists out of the box.
- **XML (Input)** (`solutions/<id>/xml/`) — FileMaker XML exports (SaXML) prepared for conversion from your solution.
- **Object Catalog (Output)** (`solutions/<id>/db/`) — The generated DuckDB database containing the extracted FileMaker objects and their relationships.
- **[fm-spec](docs/fm-lab/Wiki/fm-spec.md)** (`reference/fm_spec.duckdb`) — Reference tables for FileMaker script steps and functions, providing queryable syntax and grammar definitions for linting.
- **Docs** (`docs/`) — Documentation files for FileMaker Pro and MBS plugin functions, installable via Web frontend or Skills.
- **Tools** (`tools/`) — Utility scripts for various tasks.
- **Claude Skills** (`.claude/skills/`) — Contains Claude Code skills and slash commands for installation, conversion, lookup, analysis and code generation.
- **Plugin registry** (`.fmlab/`) — Registry and preferences for FM-Lab plugins.

## ⚡ Quickstart

The only prerequisite on your machine is **[Docker](https://docs.docker.com/get-docker/)** — batteries included: DuckDB, Node.js and PATH setup all live inside the container.

```bash
git clone https://github.com/marcel-more/fm-lab.git
cd fm-lab
bash tools/fmlab.sh up  # answers two questions, then starts
```

`fmlab.sh up` asks **“Use Docker?”** and **“Start with the Claude Code agent?”**, brings the stack up in the background, and drops you straight into the product — the web client in your browser, or a live Claude Code session in the terminal. Then **drop your FileMaker XML export** into `solutions/default/xml/` (FileMaker Pro ▸ Tools ▸ Save a Copy as XML — enable “Include details for analysis tools”; one file per solution file) and click **XML conversion** in the web client. **Done** — explore the object catalog, dependencies and the Graph Explorer.

## Setup

There are **three ways** to run FM-Lab. They share the same catalog and settings in the cloned repo, so you can switch between them freely (e.g. add the agent later — nothing is lost).

### The one command — `tools/fmlab.sh up`

For running **from a shell** (with or without Docker), the wrapper is the single entry point. It asks two questions and then does the right thing — nothing hidden: every `docker compose …` command it runs is printed first.

```
#  Use Docker? [Y/n]
     → Yes = Docker start            (way a)
     → No  = native setup on host    (way c)

#  Start with the Claude Code agent? [y/N]
     → Yes = Claude overlay
     → No  = analysis only
```

Skip the prompts with flags: `--docker` / `--native`, `--claude` / `--no-claude`, `-d` (background only). `bash tools/fmlab.sh down` stops the stack, `… logs` follows the logs, `… agent` re-attaches Claude to a running stack.

### a) Docker (recommended, all platforms)

Answer **Yes** to “Use Docker?”, or run the raw command:

```bash
docker compose up
```

The image ships every prerequisite pinned to a tested version (DuckDB CLI + webbed extension + Node/npm + Leiden clustering engine); the host needs **only Docker**. Both servers come up:

- **Web client** → http://localhost:5173
- **REST API** → http://localhost:3003

The catalog (`db/`), conversions and settings live in the cloned repo **on the host**, so they survive restarts; updating is a plain `git pull` (the repo is mounted, not baked into the image). This is also the **Windows** path — the whole POSIX layer runs inside Linux, so the host OS no longer matters.

### b) VS Code Dev Container (easy start)

Open the repository in VS Code with the **Dev Containers** extension installed, select **“Reopen in Container”** → pick **`fm-lab`** or **`fm-lab + Claude Code`**. Everything starts automatically — bootstrap, both servers, and the browser opens the web client. In the Claude variant the egress firewall and a credentials preflight run on start, and you reach the agent through the **Claude Code for VS Code** extension — no terminal steps required.
Recommended if you already work in VS Code.

### c) Native (no Docker, macOS / Linux)

For a host install without Docker, answer **No** to “Use Docker?”, or go straight there:

```bash
bash tools/fmlab.sh up --native   # hands off to tools/init.sh
```

`init.sh` checks the [prerequisites](#prerequisites), installs dependencies, seeds the environment, starts the servers, and converts any XML already in `solutions/default/xml/`.

**Windows:** Native Windows is not supported — use way a) or b) via **Docker Desktop** with the **WSL2** backend and keep the cloned repo **inside** the WSL2 distribution (e.g. `~/projects/…`), **not** on the Windows drive (`/mnt/c/…`) — a repo on `/mnt/c` suffers slow bind mounts and file-watcher (inotify) problems.

### The AI agent (Claude Code)

The Claude variant adds the **[Claude Code](https://docs.claude.com/en/docs/claude-code)** CLI on top of the same tool, with the [duckdb-skills](https://github.com/duckdb/duckdb-skills) plugin bundled and a persistent login. Start it via `bash tools/fmlab.sh up --claude`, the Dev Container **“+ Claude Code”** variant, or the raw overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.claude.yml up
docker compose exec -it api claude  # sign in once; login then persists
```

On first launch choose **“Claude account with subscription”** and complete the browser sign-in once — persisted in a named volume, so it survives restarts.

The agent stack also grants an **opt-in egress firewall** (restricted allowlist applied automatically in the Dev Container).

Refer to [Installation](/docs/fm-lab/Wiki/Installation.md) for a more detailed description.

## Prerequisites

- **Docker (ways a / b):** only **[Docker](https://docs.docker.com/get-docker/)** on the host — everything else is in the image.
- **Native (way c):** [DuckDB CLI](https://duckdb.org/docs/installation/) ≥ 1.5.4 + the **webbed** community extension (the XML reader; `init.sh` installs it when missing); Node.js ≥ 20, npm ≥ 10.
- **AI agent (optional):** [Claude Code](https://docs.claude.com/en/docs/claude-code) (bundled in the Docker agent variant) + the [duckdb-skills](https://github.com/duckdb/duckdb-skills) plugin (recommended).
- **XML export:** FileMaker Pro for the SaXML export (SaXML v2.1.0.0+ / FileMaker 19+). Future FileMaker versions may require parser adjustments.

## Preparing the XML export

Export **each file** of your solution via `Tools > Save a Copy As XML` (SaXML) in FileMaker Pro. The export contains the full structure — scripts, fields, layouts, relationships, value lists, and more — which FM-Lab parses into the DuckDB catalog. Repeat for every file of a multi-file solution, and keep the exports current with your solution.

**Important:** enable **“Include details for analysis tools”** when saving — it adds valuable metadata for analysis. You can automate the export with the [Save a Copy as XML script step](https://help.claris.com/en/pro-help/content/save-a-copy-as-xml.html).

## Day-to-day

**Convert** — click **XML conversion** in the web client (live progress, persistent log, no terminal), use the `/convert-xml` skill, or the CLI:

```bash
bash tools/convert_fm_xml.sh --turbo  # streaming; only changed catalogs
bash tools/convert_fm_xml.sh --batch  # standard; all files in the active solution's inbox (solutions/default/xml/)
bash tools/convert_fm_xml.sh "MyDatabase.xml"  # a single file
```

**Servers**

```bash
## Docker
bash tools/fmlab.sh up         # start servers
bash tools/fmlab.sh down       # stop servers

## native
bash tools/start-servers.sh    # start servers
bash tools/stop-servers.sh     # stop servers
```

## Further Documentation

- [`Documentation.md`](docs/fm-lab/Documentation.md) — Full project documentation (work in progress)
- [`CLAUDE.md`](CLAUDE.md) — the agent guide (workflows, rules, skill routing); detailed references live in [`docs/agents/`](docs/agents/) (schema & link roles, query cookbook, pipeline internals, codegen workflows)

## Status

The project has grown along a clear arc — from a solid foundation toward an increasingly capable, accessible developer platform:

- **v0.1 – v0.5** · _Foundation_ — the XML conversion pipeline, the DuckDB object catalog, and the first AI skills.
- **v0.6.x** · _Access & exploration_ — REST API, web client, and a plugin architecture turn the catalog into an interactive surface.
- **v0.7.0 – v0.7.1** · _Dashboards_ — declarative, data-driven views as a first-class extension layer.
- **v0.7.2** · _Internationalization_ — the whole stack opens up to non-English developers, with all technical identifiers kept intact.
- **v0.7.3 – v0.7.7** · _Depth & reach_ — deeper analysis, integrated documentation sets, and the XML import moving into the browser.
- **v0.8.0 – v0.8.2** · _Katana XML engine_ — optimized and powerful XML ingestion.
- **v0.8.3 – v0.8.5** · _Graph-based analysis_ — community detection, semantic naming, and an interactive Graph Explorer.
- **v0.8.6** · _Docker installer_ — including all dependencies for easy setup. Experimental Windows support via Docker on WSL2.
- **v0.8.7 – v0.8.8** · _Static code analysis_ — predefined inspection queries for standard checks, completion of the object catalog, and expanded reference coverage.
- **v0.8.9 – v0.8.10** · _fm-spec sidecar + system prompt cleanup_ — groundwork for reliable agentic code generation.
- **v0.9.0** · _Multi-solution support + agentic code generation_ — a generated script is validated against the FileMaker spec and the actual object catalog before being delivered.
- **v0.9.2** · _Multi-user & multi-session support_ — concurrent users, each on their own solution.
- **v0.9.3 – v0.9.6** · _Robustness + documentation_ — hardening the setup and the processing, providing detailed docs for schema and backend.
- **v0.9.7 – v0.9.8** · _Tests_ — providing structured tools for users and agents to apply static code analysis at different scopes. With a growing collection of rules and dashboards.
- **v0.9.9** · _Closing gaps_ — calculations, script triggers, conditional-formatting rules, merge fields, and layout variables join the object catalog.

- More details in [`CHANGELOG.md`](CHANGELOG.md) — release history

The core architecture is in place and ready for real-world use. Many more features are under active development — stay tuned for updates! 😎

## Your role as a supporter

- Your feedback is always welcome. Please allow for a structured review process.
- The project is currently in a pre-release stage, with extensive groundwork and architectural decisions requiring careful coordination by the maintainer.
- Development takes place in a private repository. This public repository contains a subset that is synchronized for releases only.
- Suggestions are welcome, but pull requests cannot be merged because of the static publishing pipeline.
- As a best practice, provide a Markdown file with a short description of your topic, the relevant details, and your preferred resolution. Let your AI agent summarize the issue and attach the resulting document.
- To report a bug or request a feature, please use the **Issues** or **Discussions** section on GitHub, or contact the maintainer through another channel.

## Roadmap

- Pre-configured installer with granular framework update options
- Windows support (via Docker setup or native)
- Granular deployment options for separate ingestion, API, and frontend services
- Auto-update of new XML imports
- Snapshots for tracking changes over time
- Deeper integration with developer tools and workflows, including VS Code, Raycast, Obsidian, and others
- Support for additional AI agents and agent configuration formats
- AI-assisted code generation, refactoring, and documentation based on the object catalog (more object types & rule based orchestration)

## Vision

_One interface to rule them all — in your personal style of workflow:_

- Your FileMaker Solution
- Your Favorite Tools
- Your Agent
- Your Project Docs
- All FileMaker-related docs and knowledge
- All possible extensions
- All in one Interface

## Fine Print

### AI-assisted development

This project was developed with significant support from AI-assisted development workflows, including Claude Code.

Spec-driven development with AI agents is used as a best practice together with human oversight and decision-making to ensure that the project remains aligned with its goals and maintains a clean architecture.

All changes were reviewed, selected, and integrated by the project maintainer.

### Disclaimer

This software is provided "as is", without warranty of any kind, express or implied. No guarantees are made regarding completeness, functionality, or stability. The authors accept no liability for data loss or unintended interactions with the user's environment. Use at your own risk.

### License

MIT — see [`LICENSE`](LICENSE).

---

### Data sources & attribution

The bundled FileMaker reference database (`reference/fm_spec.duckdb`)
describes script steps, functions and their grammar. Its contents draw on several sources; see [`reference/SOURCES.md`](reference/SOURCES.md) for the full list.
