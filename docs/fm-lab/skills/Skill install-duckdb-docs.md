# Skill: install-duckdb-docs

Downloads the official DuckDB documentation as a single Markdown file into `docs/duckdb/Documents/` — a fallback doc set for setups without the DuckDB docs plugin.

| | |
|---|---|
| **Category** | Setup & workspace |
| **Slash command** | `/install-duckdb-docs [--force]` |
| **Say it naturally** | "install the DuckDB docs", "update the DuckDB documentation" — English and German |
| **Input** | none |
| **Reads** | `blobs.duckdb.org/docs/duckdb-docs.md` |
| **Writes** | `docs/duckdb/Documents/duckdb-docs.md`, the marker `docs/duckdb/.version`, the doc-set registry `.fmlab/docs.json` |
| **Prerequisites** | `curl`, network access to `duckdb.org` |
| **Under the hood** | `.claude/skills/install-duckdb-docs/scripts/install_duckdb_docs.sh`; registration via `tools/register_docs.py` |
| **Skill directory** | `.claude/skills/install-duckdb-docs/` |
| **Related** | [Skill create-custom-dashboard](Skill%20create-custom-dashboard.md) (SQL authoring) |

## What it does

A single `curl` download with `Last-Modified` version tracking, a confirmation prompt on updates and `--force` to skip it. The file is large (several megabytes of Markdown) and covers the complete DuckDB documentation.

**When you need it — and when you don't.** The Docker image ships the official DuckDB docs plugin, whose `duckdb-docs` skill provides on-demand full-text search over the current DuckDB documentation; the system prompt routes the agent's SQL-syntax questions there. With the plugin present, this mirror is redundant for agent lookups; its remaining purpose is the web client's Docs card. The install script detects the plugin and says so: `--check` reports `plugin_present`, and a fresh install asks for confirmation before downloading. It is not skipped automatically — the Docs-card use case still justifies the mirror if you want it.

## How to use it

```
/install-duckdb-docs
/install-duckdb-docs --force
```

```bash
bash .claude/skills/install-duckdb-docs/scripts/install_duckdb_docs.sh [--force|--check]
```

## See also

- [Doc Set duckdb](../docsets/Doc%20Set%20duckdb.md) — the doc set and its fallback role
- [DuckDB](../Wiki/Dependencies.md#duckdb) — DuckDB's place in the stack
- [Doc Sets Installation](../docsets/Doc%20Sets.md#installation-and-updates) — the uniform install and update mechanics
