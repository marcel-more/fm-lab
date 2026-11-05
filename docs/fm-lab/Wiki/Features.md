# Features

The current public setup supports the following features:

- **XML Ingestion Pipeline** — converts FileMaker XML exports into a DuckDB database using a flexible [SQL template system](../templates/Ingestion%20Pipeline%20%28XML%20Import%29.md), designed for easy maintenance and updates as FileMaker evolves ♻️

- **Katana-Engine** — XML chunking and streaming for processing massive catalogs with minimal memory usage and maximum parallelism (see [details](katana-engine.md)) 🔪

- **Detailed Object Catalog** — detailed tables for the relevant [FileMaker Object Types](../schema/object-types/FileMaker%20Object%20Types.md) — from scripts, fields and layouts to relationships, value lists and custom functions — combined with a [universal catalog](../schema/object-catalog/ObjectCatalog.md) that links objects and their dependencies for fast cross-reference queries. The resolution reaches down to the finest grain: even every calculation formula, conditional-formatting rule, merge field and script trigger is an individually addressable object 🔗

- **Detailed Reference Catalog** — localized reference tables for documented FileMaker script steps, functions and trigger events, enabling linting and inline help across up to 11 locales (see [details](fm-spec.md)) 📄

- **DuckDB Backend** — in-process analytical database engine for fast and flexible queries without server setup, often delivering results in milliseconds, even for large solutions 🚀

- **REST API** — Express server providing HTTP access to the analysis database, enabling integration with external tools and services (see [details](../rest-api/REST%20API%20Overview.md)) 🧩

- **Web Client** — React/Vite frontend for interactive exploration of the solution structure and dependencies with rich visualizations 🔎

- **Dashboard System** — library of predefined analysis patterns in two forms, [single-file dashboards](../templates/Single-file%20Dashboards.md) (one `.sql` file) and [dashboard bundles](../templates/Dashboard%20Datasets.md), shipped and your own, browsable as folders, as a hierarchical list with status columns or as your favorites (see [details](Components.md#dashboard-overview)) 📁

- **Analysis Tests** — curated, declared checks with a compact result model: static-code-analysis rules, error checks and two-axis platform tests (compatibility and platform binding, including the OS sub-axis macOS / Windows / Linux / iOS and plug-in platform evidence), runnable per solution, file, object or cluster (see [details](Analysis%20Tests.md)) ✅

- **Change History** — who changed what and when, for every object type, read from the change stamps of the XML export: a *Last modified* line on every detail view, a [recent-changes dashboard](../schema/catalog-tables/ObjectChangeMeta.md#recent-changes-dashboard) with work sessions, an activity map and a stacked timeline, [hotspots and stale objects](../schema/catalog-tables/ObjectChangeMeta.md#hotspots-and-stale-objects-dashboard) (changed often × used widely, unreferenced by age), [modules changed together](../schema/catalog-tables/ObjectChangeMeta.md#changed-together-dashboard) in one work session, [module activity](../schema/catalog-tables/ObjectChangeMeta.md#module-activity-dashboard) — which modules live and which rest, also as a colour mode of the Graph Atlas and the Graph Explorer —, a [security change log](../schema/catalog-tables/ObjectChangeMeta.md#security-changes-dashboard), a [quality check of the stamps](../schema/catalog-tables/ObjectChangeMeta.md#change-metadata-quality-dashboard), release notes via [fm-changes](../skills/Skill%20fm-changes.md), and mass events (migrations, pastes, tool runs) recognized and kept apart from individual edits 🕓

- **Multi-user & multi-session support** - concurrent users, each on their own solution 🙌

- **Graph Explorer** — interactive navigation of the full object graph, with automatic community detection that reveals named clusters across the solution and turns thousands of objects and links into a navigable graph map 🕸️

- **Claude Skills** — slash commands for agentic analysis workflows in Claude Code, supported by helpers for XML conversion and documentation setup, enabling deep, solution-aware inspection beyond scripted analysis (see [details](../skills/Skills.md)) 🤖

- **Comprehensive Docs** — easy-to-install [documentation](../docsets/Doc%20Sets.md) for FileMaker Pro and MBS plugin functions 📚

- **Plugin System** — open architecture for adding new tools and integrations, starting with **[fmIDE](https://github.com/fmIDE/fmIDE)** as a first-class citizen to provide direct navigation into FileMaker's Script Workspace 🛠️

- **AI Code Generation** — architecture and data model built for AI-driven code generation: every generated artifact is grounded in reliable context from the object catalog and validated against the integrated machine-readable FileMaker syntax and grammar through a multi-step validation pipeline 🧠