# SQL Templates

SQL is the foundation of FM-Lab's analytical layer by design. Rather than embedding queries throughout the application, FM-Lab centralizes data ingestion and retrieval in reusable SQL templates. This creates a composable query layer that is easy to extend, easy to maintain, and able to evolve with both the object catalog and future analytical requirements.

Every analysis rendered by the frontend, every dashboard tile, and every `/api/query` call ultimately executes one of these templates against the DuckDB object catalog.

This is the **overview** page. FM-Lab groups templates by **who calls them and
how** — each tier lives in its own directory, is resolved by a distinct part of
the system, and has its own page:

| Page | Directory | In one line |
|---|---|---|
| [Single-file Dashboards](Single-file%20Dashboards.md) | `rest-api/templates/dashboards/<folder>/` · `dashboards-custom/` | One `.sql` file with a header is a dashboard — shipped and your own; also callable through `/api/query`. |
| [Dashboard Datasets](Dashboard%20Datasets.md) | `rest-api/templates/dashboards/` · `dashboards-custom/` | Per-tile datasets inside dashboard bundles — shipped and your own. |
| [Built-in Query Templates](Built-in%20Query%20Templates.md) | `rest-api/templates/queries/system/` | Internal backbone of `/api/report` — object details, references, counts, graph. |
| [Detail View Templates](Detail%20View%20Templates.md) | `rest-api/templates/queries/modules/` | Internal SQL of `/api/query` loaded by UI hooks; never listed. |
| [Ingestion Pipeline (XML Import)](Ingestion%20Pipeline%20%28XML%20Import%29.md) | `ingestion/sql/` | The build SQL (P1–P6) that produces the catalog — **not** via REST. |

The rest of this page explains what the tiers share: how a template works, the
metadata header, parameters, and worked examples.

## How it works

The principle is deliberately simple and stackable:

```
SQL Template  ──►  DuckDB object catalog  ──►  output format  ──►  REST API
(named .sql +      (db/fm_catalog.duckdb —      (json, csv,        (/api/query,
 parameters)        the imported solution)       markdown, …)       /api/report, …)
```

1. **A template is a plain `.sql` file** with a small metadata header. It asks a
   question against the catalog tables (see [Folder structure](../Wiki/Folder%20structure.md) for where the
   catalog comes from).
2. **The catalog answers.** After XML import the whole FileMaker structure lives
   as resolved tables and edges — `ObjectCatalog`, `ScriptCatalog`,
   `FieldsForTables`, `ObjectLinks`, `LayoutObjects`, … — so a template never
   re-parses XML; it queries already-resolved data.
3. **The result is rendered through an output format.** The same rows can come
   back as JSON, CSV, Markdown, plain-text lists or a Mermaid diagram — chosen
   per request with `?format=…`. See [REST API Output Formats](../rest-api/REST%20API%20Output%20Formats.md).
4. **The REST API serves it.** Named templates are executed through
   [/api/query and /api/report](../rest-api/endpoints/Query%20and%20Report%20API.md); arbitrary ad-hoc SQL is
   **not** accepted from the outside — only named, parameterised templates.

Because the query, the parameters and the output format are three independent
knobs, one template serves many callers: a CLI curl, a dashboard tile, and the
web frontend can all reuse the same `.sql`.

## The metadata header

Every REST-served template starts with `-- @key: value` comment lines. They are
parsed by the template service; for a [single-file dashboard](Single-file%20Dashboards.md)
they *are* the dashboard definition (the full key list is there). Common keys:

| Key | Purpose |
|---|---|
| `@template_type` | `report`, `content` (the `object_details_*` family), `object` — how the result is consumed |
| `@title` / `@description` | shown in listings and on tiles |
| `@params` | expected parameters (with optional/default notes) |
| `@output_format` | the columns the template returns |
| `@display` | tile rendering hint (`table`, …) |
| `@click_action` / `@click_args` | make a row navigate (e.g. `openObject`) |
| `@icon` / `@tags` | iconography and search terms (the folder groups a dashboard — `@category` has no effect) |
| `@object_types` / `@default_result` | object-type filter and findings value of a single-file dashboard |
| `@author` / `@version` | provenance |

## Parameters

Templates are parameterised so one file answers a family of questions. Three
substitution styles are supported and may be mixed:

| Style | Example | Typical use |
|---|---|---|
| DuckDB variable | `getvariable('file_name')` | the rule — every shipped template and dashboard |
| Named | `:file_name` | older dashboard datasets, the file view |
| Positional | `$1`, `$2` | short, order-based calls |

Values become SQL literals server-side: strings are quoted (single quotes
doubled), finite numbers are inserted as numbers, booleans as `TRUE`/`FALSE`,
`null` as `NULL`. Any other value — an array, an object, `NaN`, `Infinity` — is
rejected with `400 VALIDATION_ERROR` before the template runs. A list therefore
reaches a template as one delimited string and is split in SQL, e.g.
`list_contains(string_split(getvariable('ids'), ','), Object_UUID)`. A missing
named/positional parameter resolves to `NULL` — the common
`getvariable('x') IS NULL OR col = getvariable('x')` idiom turns that into an
"all rows" fallback.

> **`:param` caveat.** In dashboard datasets every bare `:word` with no matching
> parameter is replaced by `NULL`. Watch out for stray colons (a `::CAST`, a
> `localhost:3003`) — they can be mis-read as parameters.

### System parameters

The server sets four parameters itself. Read them like any other; they need no
declaration, and a request cannot override them (query parameters starting
with `fmlab_` are ignored):

| Variable | Value |
|---|---|
| `getvariable('fmlab_solution')` | id of the solution the request works on |
| `getvariable('fmlab_lang')` | UI language of the request (`en`, `de`, …) |
| `getvariable('fmlab_today')` | today's date, `YYYY-MM-DD` (server time) |
| `getvariable('fmlab_version')` | fm-lab version |

### Shared SQL in dashboard bundles

In the SQL files of a dashboard bundle, a line `--#include <relative path>` is
replaced by the content of that file — for CTEs that several datasets of the
same bundle share. The path is relative to the including file and stays inside
the bundle folder (fragments typically live in `data/shared/`). A fragment is
part of one statement: its final `;` is dropped, any other `;` is answered with
`400 VALIDATION_ERROR` naming file and line. Includes nest up to five levels;
cycles are refused. Single-file dashboards and query templates have no
includes.

## Runtime environment

The REST API runs templates on a read-only connection to the solution's catalog,
with the reference databases attached as `ref` ([fm-spec](../Wiki/fm-spec.md)) and `plugref`
([plugin-spec](../schema/plugin-spec.md)). Beyond these, the connection has no file or network access:

- a template file holds **one query**: a single statement of type `SELECT`
  (including `WITH`, `FROM`-first, `DESCRIBE`, `SUMMARIZE`, `SHOW`), a
  standalone `PIVOT`, or an `EXPLAIN` of such a query. Anything else — `COPY`,
  `EXPORT`, `ATTACH`, `DETACH`, `SET` / `SET VARIABLE` / `USE`, `CREATE` (also
  `TEMP`), `INSERT`, `LOAD`, `CHECKPOINT`, transactions — is answered with
  `400 VALIDATION_ERROR` ("statement type … is not allowed") and never runs.
  Several statements in one file — usually a `;` that ends the query early —
  are answered with `400 VALIDATION_ERROR` ("one statement per file"); a
  single trailing `;` is fine. The same holds for single-file dashboards and
  dashboard datasets;
- a query from a file runs at most **2 minutes** (`DUCKDB_FILE_QUERY_TIMEOUT_MS`,
  with Docker `FMLAB_QUERY_TIMEOUT_MS` in `.env`; `0` = no limit); a longer one
  is stopped and answered with `504 QUERY_TIMEOUT` ("Query stopped after … s").
  It runs on a connection of its own, so other queries of the same solution are
  not held up meanwhile. Data spilled to disk is capped as well
  (`DUCKDB_MAX_TEMP`: 50 GB in the Docker setups, 20 GB otherwise);
- `read_csv`, `read_json`, `read_text`, `read_parquet`, `glob` and `ATTACH`
  on any other path fail with a `Permission Error`;
- extensions are neither installed nor loaded on demand — `json`, `icu`,
  `parquet` and the core functions are built in, everything else (e.g.
  `webbed`) is unavailable to templates;
- DuckDB settings are locked — apart from the thread count, which the API
  manages itself, a `SET` fails.

Data a template needs belongs in the catalog or in a reference database. For
diagnosis only, `DUCKDB_RESTRICT_FILE_ACCESS=0` in `rest-api/.env` starts the
API without these limits — useful to tell whether a template fails because it
reads a file.

## Example: standard questions

A handful of everyday queries, one self-contained `.sql` each:

**How many scripts are in file F?**

```sql
-- @template_type: report
-- @params: file_name (optional)
SELECT File_Name, COUNT(*) AS script_count
FROM ScriptCatalog
WHERE getvariable('file_name') IS NULL
   OR File_Name = getvariable('file_name')
GROUP BY File_Name
ORDER BY File_Name;
```

**Which fields does table T contain?**

```sql
-- @params: table_name
SELECT Field_Name, Field_Type, Field_Comment
FROM FieldsForTables
WHERE Table_Name = getvariable('table_name')
ORDER BY Field_Name;
```

**Which script steps belong to script S?** (steps are ordered by `Step_Index`)

```sql
-- @params: file_name, script_name
SELECT Step_Index, Step_Name, Is_Enabled
FROM StepsForScripts
WHERE File_Name  = getvariable('file_name')
  AND Script_Name = getvariable('script_name')
ORDER BY Step_Index;
```

**Which fields does script S use?** — read the resolved `ObjectLinks` edge, never
regex `Step_XML`. `sets_field` = written, `reads_field` = read:

```sql
-- @params: script_name
SELECT tgt.File_Name, tgt.Object_Name AS field, ol.Link_Role, COUNT(*) AS n
FROM ObjectLinks ol
JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID
JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
WHERE src.Object_Type = 'Script'
  AND src.Object_Name = getvariable('script_name')
  AND ol.Link_Role IN ('sets_field', 'reads_field')
GROUP BY ALL
ORDER BY ol.Link_Role, tgt.Object_Name;
```

**Which fields does layout L contain?** — again via the resolved edge
(Layout → Field), not by scanning layout XML:

```sql
-- @params: layout_name
SELECT tgt.File_Name, tgt.Object_Name AS field, ol.Link_Role
FROM ObjectCatalog lay
JOIN ObjectLinks ol    ON lay.Object_UUID = ol.Source_UUID
JOIN ObjectCatalog tgt ON ol.Target_UUID = tgt.Object_UUID
WHERE lay.Object_Type = 'Layout'
  AND lay.Object_Name = getvariable('layout_name')
  AND tgt.Object_Type = 'Field'
ORDER BY tgt.Object_Name;
```

## Why templates, not hard-coded queries

- **Flexible architecture** — queries, parameters, and output formats are independent, allowing a single `.sql` template to serve many callers and interfaces.
- **Extensibility** — dropping a file into the appropriate template tier adds a new capability without code changes, redeployment, or restarts. Templates are hot-reloaded automatically.
- **Adaptability** — your own dashboards override shipped ones by name, allowing every installation to tailor analyses to its own conventions.
- **Expressive DuckDB SQL** — window functions, `GROUP BY ALL`, `COLUMNS(...)`, list/struct types, recursive CTEs, and graph-style traversals are all fair game. Even advanced analyses such as dependency walks, dead-code detection, or coupling metrics remain concise, readable SQL templates.
- **Multiple output formats** — templates are responsible only for producing results. Output adapters selected by request parameters transform those results into tabular data, generated text, or other predefined representations. Queries that already produce their final format can bypass adaptation entirely through the `raw` adapter.

## See also

- [Query and Report API](../rest-api/endpoints/Query%20and%20Report%20API.md) — the endpoints that execute templates
- [REST API Output Formats](../rest-api/REST%20API%20Output%20Formats.md) — how a result is rendered
- [Folder structure](../Wiki/Folder%20structure.md) — where templates and the catalog live
- [REST API](../rest-api/REST%20API%20Overview.md) — the API these templates sit behind
