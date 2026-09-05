# Dependencies

FM-Lab is built entirely on open-source components. This page lists the core technologies the project depends on, organized by architectural layer — from the analytical core through the ingestion pipeline up to the interaction layer. It intentionally covers only the components that shape the architecture, not every single package. See [Architecture](Architecture.md) for how these layers fit together.

- [Analytical core](#analytical-core)
- [Ingestion pipeline](#ingestion-pipeline)
- [Backend runtime](#backend-runtime)
- [Web frontend](#web-frontend)
- [Graph analysis](#graph-analysis)
- [Python](#python)
- [Version baseline](#version-baseline)

---

## Analytical core

### DuckDB

[DuckDB](https://duckdb.org/) is the foundation of FM-Lab. The entire Object Catalog — every extracted FileMaker object, link, and analysis view — lives in DuckDB database files. It is used in two forms:

- the **DuckDB CLI** executes the SQL templates of the [ingestion pipeline](katana-engine.md) and serves ad-hoc analysis queries
- the **Node.js client** (`@duckdb/node-api`) gives the REST API direct in-process access to the catalog

DuckDB was chosen for its combination of XML parsing, powerful analytical SQL, in-process execution without server overhead, and portability. See [DuckDB-powered Object Catalog](Architecture.md#duckdb-powered-object-catalog) for the full rationale.

### webbed extension

[webbed](https://duckdb.org/community_extensions/extensions/webbed) is a DuckDB community extension that brings XML/HTML processing into the SQL engine — typed `read_xml` ingestion and XPath-based extraction (`xml_extract_text` and friends). The whole ingestion pipeline is built around it: FileMaker SaXML exports are parsed, flattened, and resolved into relational tables purely in SQL, with no separate XML parser in the stack. FM-Lab tracks webbed releases closely and probes the loaded version at runtime to enable capabilities such as SAX streaming for very large exports.

---

## Ingestion pipeline

The [katana-engine](katana-engine.md) converter is deliberately thin on dependencies:

- **Bash** shell scripts (`ingestion/convert_fm_xml.sh` and helpers) orchestrate the conversion phases; they are written to run on the stock macOS bash 3.2 as well as Linux
- **DuckDB SQL templates** (`ingestion/sql/`) contain the actual extraction and resolution logic, executed by the DuckDB CLI with the webbed extension loaded

This keeps the pipeline portable: any machine with a shell and the DuckDB CLI can convert XML exports.

---

## Backend runtime

### Node.js and npm

The server side of FM-Lab runs on [Node.js](https://nodejs.org/) (version 20 or newer). The repository is organized as an **npm workspaces monorepo** — the REST API (`rest-api/`), the web client (`apps/web/`), and shared packages (`packages/*`) are separate workspaces installed together via `tools/init.sh`.

### REST API stack

The API server (`rest-api/`) is built on a small set of established libraries:

- [Express 5](https://expressjs.com/) — HTTP server and routing for all [REST API](../rest-api/REST%20API%20Overview.md) endpoints
- [Eta](https://eta.js.org/) — template engine that renders SQL query templates and HTML/text output formats
- [Joi](https://joi.dev/) — schema validation for request parameters and dashboard manifests

---

## Web frontend

The web client (`apps/web/`) is a single-page application built with:

- [React 18](https://react.dev/) — UI component model
- [TypeScript](https://www.typescriptlang.org/) — static typing across the frontend code base
- [Vite](https://vitejs.dev/) — dev server and production build tooling
- [i18next](https://www.i18next.com/) — internationalization (the interface ships in 11 locales)

### Graph visualization

Interactive graph views in the frontend are rendered with [Cytoscape.js](https://js.cytoscape.org/), a graph visualization library for large networks. Two layout extensions complement it:

- **cytoscape-fcose** — force-directed layouts for organic neighborhood and cluster views
- **cytoscape-dagre** — hierarchical layouts for directed dependency chains

The Graph Atlas overview additionally uses [visx](https://airbnb.io/visx/) (`@visx/hierarchy`) to render the cluster treemap.

---

## Graph analysis

Community detection for [Graph analysis](4%20Code%20Analysis%20Approaches.md#3-graph-analysis) (the `fm-graph-cluster` workflow) runs on two interchangeable engines with the same I/O contract:

- **Louvain** (default) — pure Node.js via [graphology](https://graphology.github.io/) and `graphology-communities-louvain`; this is the guaranteed baseline that works without any Python setup
- **Leiden** (optional enhancement) — Python via [python-igraph](https://igraph.org/python/); the dispatcher selects it automatically when Python and igraph are available

Both engines run with fixed seeds and resolutions so cluster assignments stay stable between runs.

---

## Python

Python 3 plays a supporting role and is not required for the core workflow:

- optional **Leiden clustering** via python-igraph (see [Graph analysis](#graph-analysis))
- utility scripts under `tools/` (documentation registration, wiki-link conversion for publishing)
- code generation tooling inside Claude skills (e.g. the `fm-generate-script` pipeline)

Apart from python-igraph, these scripts rely on the Python standard library only.

---

## Version baseline

The tested reference setup (checked by `tools/init.sh` at first run):

| Component | Minimum version |
|---|---|
| DuckDB CLI | 1.5.4 |
| webbed extension | 2.4.0 |
| Node.js | 20 |
| npm | 10 |
| Python 3 | optional (Leiden, utility scripts) |

See [Installation](Installation.md) for setup instructions.
