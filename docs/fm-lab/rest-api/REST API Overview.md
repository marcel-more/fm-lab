# REST API Overview

The FM-Lab REST API provides programmatic access to the FileMaker object catalog stored in DuckDB. Every endpoint reads from the imported solution catalog (`SaveCopyAsXML` exports, no user data) — the API never touches live FileMaker files.

- **Base URL:** `http://localhost:3003/api`
- **Authentication:** none (local development server)
- **Default response format:** JSON envelope (see [REST API Conventions](REST%20API%20Conventions.md))
- **Alternative output formats:** 11 formats from `raw` to `mermaid` and `tokens` — see [REST API Output Formats](REST%20API%20Output%20Formats.md)
- [Component location](../Wiki/Components.md#rest-api) inside the repo's [Folder structure](../Wiki/Folder%20structure.md)

## Quick start

```bash
# Health check
curl "http://localhost:3003/api/version"

# Find an object by name
curl "http://localhost:3003/api/search?name=%25Import%25"

# Show its references
curl "http://localhost:3003/api/references?uuid=<Object_UUID>"
```

## Endpoint groups

### Catalog access (core)

| Group | Endpoints | Documentation |
|---|---|---|
| Objects | `/get`, `/get-details`, `/get-calc`, `/conditional-formatting` | [Objects API](endpoints/Objects%20API.md) |
| Lists & search | `/list`, `/list/categories`, `/list-with-folders`, `/count`, `/search`, `/search/count` | [Search API](endpoints/Search%20API.md) |
| References | `/references`, `/back-references` | [References API](endpoints/References%20API.md) |
| Query & report | `/query`, `/report`, `/query/list`, `/report/list` | [Query and Report API](endpoints/Query%20and%20Report%20API.md) |
| Analysis tests | `/tests`, `/tests/context`, `/tests/:id`, `/tests/:id/run` | [Tests API](endpoints/Tests%20API.md) |
| Results | `/results/summary`, `/results/aggregate`, `/results/registry`, `/results/run` | [Results API](endpoints/Results%20API.md) |
| Graph | `/graph/*`, `/relationship-graph/:fileName` | [Graph API](endpoints/Graph%20API.md) |

### Reference & code generation

| Group | Endpoints | Documentation |
|---|---|---|
| Reference database | `/reference/*` (script steps, functions, grammar, Claris Help mirror) | [Reference Database API](endpoints/Reference%20Database%20API.md) |
| Codegen | `/codegen/lint`, `/codegen/compile`, `/codegen/decompile` | [Codegen API](endpoints/Codegen%20API.md) |

### Operations

| Group | Endpoints | Documentation |
|---|---|---|
| System | `/version`, `/info`, `/version-manifest`, `/system/config` | [System API](endpoints/System%20API.md) |
| Favorites | `/favorites/:kind`, `/favorites/:kind/:id` (`dashboard`, `test`) | [Favorites API](endpoints/Favorites%20API.md) |
| Maintenance | `/maintenance/dashboards/cleanup`, `/maintenance/tests/cleanup` | [Maintenance API](endpoints/Maintenance%20API.md) |
| Solutions & admin | `/solutions`, `/admin/*` | [Solutions API](endpoints/Solutions%20API.md) |
| XML import | `/xml/*` (status, runs, convert, SSE progress stream) | [XML Import API](endpoints/XML%20Import%20API.md) |

### Internal endpoints (not part of the public API)

The following groups exist to support the FM-Lab web frontend and are **not** covered by this documentation. They may change without notice:

- `/dashboards/*` — declarative dashboards (bundles and single-file dashboards) for the web UI
- `/docs/*`, `/plugin-docs/*` — local documentation mirrors (Claris Help, MBS, DuckDB)
- `/plugin-spec/*` — plug-in platform metadata derived from the installed MBS docs (see [plugin-spec](../schema/plugin-spec.md))
- `/plugins/*`, `/fmide/*`, `/graphify/*` — plugin management and optional plugins (disabled by default)
- `/annotations/*` — user annotations for the Graph Explorer
- `/change-authors` — curated author aliases of the change metadata (settings page; stored with the user annotations)
- `/debug/session*` — frontend debug-session ingestion

## Multi-solution workspaces

A workspace can hold several imported solutions. All endpoints operate on the **active solution** by default; a request can target a different solution explicitly with the `X-Solution` header. Details: [Solution scoping (X-Solution)](REST%20API%20Conventions.md#solution-scoping-x-solution).
