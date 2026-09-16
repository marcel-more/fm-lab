# Doc Sets

A **doc set** is a local, versioned documentation mirror that lives under `docs/` and is wired into FM-Lab as a first-class knowledge source. Doc sets serve two consumers at once: **AI agents**, which ground their answers and generated code in authoritative reference material instead of model memory, and **humans**, who browse the same content through the web frontend's docs browser and inline help embeds.

Two doc sets ship with FM-Lab itself; the others are external vendor documentation, downloaded on demand into the local cache. Installed doc sets are registered in the docs catalog (`.fmlab/docs.json`, with a runtime overlay `.fmlab/docs.installed.json`), which drives the REST API's `/api/docs` endpoints and the web frontend's Docs pages. See [Components](../Wiki/Components.md#docs) for where doc sets sit in the overall architecture.

---

## Why doc sets, not grep or RAG

Plugging documentation into agentic workflows usually means either full-text search over raw files (grep) or a retrieval pipeline over embedded chunks (RAG). FM-Lab's doc sets take a third path — **structured, indexed, cross-referenced mirrors** — built on three features:

### Index DB

The two reference-heavy doc sets are backed by a real database index: the FileMaker reference index in [fm-spec](../Wiki/fm-spec.md) (`reference/fm_spec.duckdb`, DuckDB) and the MBS Dash index (`docs/mbs/docSet.dsidx`, SQLite). A lookup is a deterministic query, not a text scan:

- **Locale-independent resolution.** Name-lookup tables map a function or script-step name *in any supported language* (`MusterAnzahl` ↔ `PatternCount`, `Hole` ↔ `Get`) to a stable canonical ID, and from there to metadata and the right documentation page. Grep is locale-blind; RAG retrieval is probabilistic.
- **Typed metadata, queryable with SQL.** Parameters, return types, categories, version compatibility and deep-link URLs are columns, not prose. Questions like "all script steps that arrived in FileMaker 19" are a `SELECT`, with an exact, verifiable answer.
- **No retrieval infrastructure.** No chunking, no embeddings, no vector store, no relevance tuning — and the result set is complete, not top-k.

### Rubrics

Doc entries carry the **vendor's own taxonomy**: 19 function categories and 13 script-step categories for the FileMaker reference (localized), 168 plugin components for MBS (counted by primary assignment; multi-component memberships are listed on [Doc Set mbs](Doc%20Set%20mbs.md)). Thematic search ("which functions deal with JSON?") becomes a catalog query with a guaranteed-complete result — no similarity threshold deciding what you get to see. In the web frontend the same rubrics drive the docs browser's navigation.

The indexed doc sets additionally support **entry-level search**: a query is matched against the individual entries (functions *and* script steps for the FileMaker reference, function names for MBS) and aggregated *per rubric* — every rubric with at least one hit appears, with its full hit count and a small evidence sample. True to the "complete, not top-k" principle above, no global result cap decides which rubrics you get to see. Doc sets without a database index (plain markdown mirrors like fmIDE) offer rubric navigation only.

### Pseudo object types

The decisive difference to any grep/RAG setup: documentation entries surface **inside the object catalog of your own solution** as pseudo object types — `BuiltinFunction`, `ScriptStepType`, `PluginFunction` and `PluginComponent` (see [Object Types](../schema/object-catalog/Object%20Types.md#synthetic-object-types)). Every documented function or step type is simultaneously a node in your solution's dependency graph, so documentation and code cross-reference each other:

- *Where-used from the docs:* from a documentation entry straight to every script and calculation in your solution that uses it.
- *Docs from the code:* from a code reference straight to the authoritative documentation page.
- *Aggregated views:* usage counts, category filters and drill-down navigation over pseudo types in the web frontend.

A text-retrieval pipeline can quote documentation; it cannot join documentation to your dependency graph.

On top of these three features, all doc sets share the practical virtues of a local mirror: they work **offline**, they are **versioned** (update detection against the original source), and their content is **authoritative** — versioned vendor documentation instead of model recall.

---

## The doc sets

### Built-in

Shipped with every FM-Lab release — no installation needed.

| Doc set | Content | Index DB | Rubrics | Pseudo types |
|---|---|---|---|---|
| [Doc Set fm-lab](Doc%20Set%20fm-lab.md) | This manual — the FM-Lab documentation | — | — | — |
| [Doc Set agents](Doc%20Set%20agents.md) | Agent-facing reference (schema, pipeline, workflows) wired into the system prompt | — | — | — |

### Recommended

External vendor documentation, installed on demand. Installing these is highly recommended: they provide inline help for the web client and grounded reference material for agentic analysis and code generation.

| Doc set | Content | Index DB | Rubrics | Pseudo types |
|---|---|---|---|---|
| [Doc Set claris-help](Doc%20Set%20claris-help.md) | Claris FileMaker Pro online help, up to 11 languages | ✓ fm-spec (DuckDB) | ✓ 19 + 13 categories | ✓ |
| [Doc Set mbs](Doc%20Set%20mbs.md) | MBS Plugin function reference (~7,300 functions) | ✓ Dash (SQLite) | ✓ 168 components | ✓ |
| [Doc Set fmIDE](Doc%20Set%20fmIDE.md) | fmIDE wiki (integration, Name-that-Thing API, ActionScripts) | — | — | — |
| [Doc Set duckdb](Doc%20Set%20duckdb.md) | DuckDB SQL documentation — **fallback only**, see the page | — | — | — |

### Optional

Reference repositories rather than documentation mirrors — cloned for testing and format exploration, not wired into the docs browser.

| Doc set | Content |
|---|---|

---

## Installation and updates

Every installable doc set offers up to three routes; the individual pages list the exact commands.

- **Skill** — ask the agent (e.g. *"install the MBS docs"*); the matching `install-*` skill handles download, verification and registration.
- **CLI script** — each skill wraps a standalone shell script under `.claude/skills/install-*/scripts/` that can be run directly, with `--check` (report installed vs. remote version as JSON) and `--force` (replace without prompting) where supported.
- **Web frontend** — the four registered documentation sets (claris-help, mbs, fmide, duckdb) can be installed and updated from the web client's Docs pages, backed by `POST /api/docs/install/:id` with live progress streaming. The two optional repository clones are skill/CLI-only.

Update mechanics are uniform: each doc set stores a `.version` marker (HTTP `Last-Modified` or git commit), installers compare it against the original source and prompt before replacing an existing installation. The dev container's egress firewall already allowlists the required source domains (`help.claris.com`, `www.monkeybreadsoftware.com`, `duckdb.org`/`blobs.duckdb.org`, GitHub).

## See also

- [Components](../Wiki/Components.md#docs) — doc sets in the component overview
- [fm-spec](../Wiki/fm-spec.md) — the FileMaker reference index behind claris-help
- [Object Types](../schema/object-catalog/Object%20Types.md) — pseudo object types in the object catalog
- [REST API Overview](../rest-api/REST%20API%20Overview.md) — the API serving the docs browser
