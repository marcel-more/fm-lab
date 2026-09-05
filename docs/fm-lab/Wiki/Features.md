# Features

The current public setup supports the following features:

- **XML Ingestion Pipeline** — converts FileMaker XML exports into a DuckDB database using a flexible SQL template system, designed for easy maintenance and updates as FileMaker evolves ♻️

- **Katana-Engine** — XML chunking and streaming for processing massive catalogs with minimal memory usage and maximum parallelism (see [details](katana-engine.md)) 🔪

- **Detailed Object Catalog** — detailed tables for the relevant FileMaker object types — from scripts, fields and layouts to relationships, value lists and custom functions — combined with a universal catalog that links objects and their dependencies for fast cross-reference queries. The resolution reaches down to the finest grain: even every calculation formula, conditional-formatting rule, merge field and script trigger is an individually addressable object 🔗

- **Detailed Reference Catalog** — localized reference tables for documented FileMaker script steps, functions and trigger events, enabling linting and inline help across up to 11 locales (see [details](fm-spec.md)) 📄

- **DuckDB Backend** — in-process analytical database engine for fast and flexible queries without server setup, often delivering results in milliseconds, even for large solutions 🚀

- **REST API** — Express server providing HTTP access to the analysis database, enabling integration with external tools and services (see [details](../rest-api/REST%20API%20Overview.md)) 🧩

- **Web Client** — React/Vite frontend for interactive exploration of the solution structure and dependencies with rich visualizations 🔎

- **Dashboard System** — library of predefined analysis patterns, with support for custom queries and custom dashboards 📁

- **Analysis Tests** — curated, declared checks with a compact result model: static-code-analysis rules, error checks and two-axis platform tests (compatibility and platform binding, including the OS sub-axis macOS / Windows / Linux / iOS and plug-in platform evidence), runnable per solution, file, object or cluster (see [details](Analysis%20Tests.md)) ✅

- **Multi-user & multi-session support** - concurrent users, each on their own solution 🙌

- **Graph Explorer** — interactive navigation of the full object graph, with automatic community detection that reveals named clusters across the solution and turns thousands of objects and links into a navigable graph map 🕸️

- **Claude Skills** — slash commands for agentic analysis workflows in Claude Code, supported by helpers for XML conversion and documentation setup, enabling deep, solution-aware inspection beyond scripted analysis (see [details](../skills/Skills.md)) 🤖

- **Comprehensive Docs** — easy-to-install documentation for FileMaker Pro and MBS plugin functions 📚

- **Plugin System** — open architecture for adding new tools and integrations, starting with **[fmIDE](https://github.com/fmIDE/fmIDE)** as a first-class citizen to provide direct navigation into FileMaker's Script Workspace 🛠️

- **AI Code Generation** — architecture and data model built for AI-driven code generation: every generated artifact is grounded in reliable context from the object catalog and validated against the integrated machine-readable FileMaker syntax and grammar through a multi-step validation pipeline 🧠