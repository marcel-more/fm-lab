# Query and Report API

Execute named SQL templates against the catalog: `/query` for analysis SQL, `/report` for the internal report templates that default to rendered HTML. Both exist as GET (parameters in the query string) and POST (JSON body) variants; `/query/list` and `/report/list` enumerate what each one reaches. Arbitrary SQL is **not** accepted — only named templates with parameters.

| Endpoint | Resolves a name to | In this order |
|---|---|---|
| `/api/query` | analysis SQL | 1. a single-file dashboard, see [Single-file Dashboards](../../templates/Single-file%20Dashboards.md) (`dashboards-custom/` → `dashboards/` → `dashboards-community/` → old location `sql-custom/`) · 2. a module template, see [Detail View Templates](../../templates/Detail%20View%20Templates.md) (`queries/modules/`) · 3. a `queries/` folder inside a dashboard bundle |
| `/api/report` | internal templates | system templates ([Built-in Query Templates](../../templates/Built-in%20Query%20Templates.md)) only (`queries/system/`) |

The same chains back the dashboard dataset sources `custom:<name>` and `report:<name>` ([Dashboard Datasets](../../templates/Dashboard%20Datasets.md)).

---

## GET/POST /api/query

| Field | Type | Default | Description |
|---|---|---|---|
| `template` | string | — | **Required.** Template name without `.sql` |
| `params` | object \| JSON string | — | Template parameters (JSON string in GET, object in POST) |
| `format` | enum | `json` | See [REST API Output Formats](../REST%20API%20Output%20Formats.md) |
| `theme` | enum | — | `default` · `dark` · `forest` · `neutral` — mermaid formats only |
| `direction` | enum | — | `TD` · `LR` · `BT` · `RL` — mermaid graph direction |
| `title` | string | — | Diagram/report title (max 200 chars) |
| `meta` / `debug` | boolean | `false` | `debug` returns the executed SQL |

Additional unknown parameters are passed through as template variables.

```bash
# GET with JSON-encoded params
curl "http://localhost:3003/api/query?template=unused_scripts&params=%7B%22file%22%3A%22Contacts%22%7D"

# POST
curl -X POST http://localhost:3003/api/query \
  -H "Content-Type: application/json" \
  -d '{"template": "unused_scripts", "params": {"file": "Contacts"}, "format": "markdown"}'
```

**Response (json):** the standard envelope with `data` as an array of result rows. Errors: `404 TEMPLATE_NOT_FOUND` (also for a system template — those answer only `/report`), `500 TEMPLATE_ERROR` (template failed during execution), `409 SCHEMA_DRIFT` (catalog older than the template expects — re-import the XML).

A single-file dashboard answers here and at `/api/dashboards/<name>/data` with the same rows; paged ones take `page`, `q`, `sort`/`dir` and `page_size` (see [Server paging](../../templates/Single-file%20Dashboards.md#server-paging-sorting-and-search)).

## GET/POST /api/report

Identical interface to `/query`, but `format` defaults to **`html`** — report templates are designed to render as styled documents. Use `format=json` to get the underlying rows.

```bash
curl "http://localhost:3003/api/report?template=object_count_by_type&format=json"
```

## GET /api/query/list · GET /api/report/list

Enumerate the installed templates with their metadata (name, description, expected parameters). `/query/list` lists the single-file dashboards of the content areas (shipped, custom, community, old location) with their `folder`, `area`, `overrides`, `legacy` and `unit: "file"`; module templates are internal and not listed. `/report/list` lists the system templates.

---

## Template parameter notes

- Parameters are substituted by a named-placeholder preprocessor — numbers belong in the JSON unquoted, strings quoted.
- Templates are locale-independent by convention (they match on IDs such as `Step_ID`, never on localized display names).

See also: [REST API Output Formats](../REST%20API%20Output%20Formats.md) (mermaid rendering of graph-shaped query results), [REST API Conventions](../REST%20API%20Conventions.md).
