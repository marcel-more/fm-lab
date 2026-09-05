# SQL Templates

SQL is the foundation of FM-Lab's analytical layer by design. Rather than embedding queries throughout the application, FM-Lab centralizes data ingestion and retrieval in reusable SQL templates. This creates a composable query layer that is easy to extend, easy to maintain, and able to evolve with both the object catalog and future analytical requirements.

Every analysis rendered by the frontend, every dashboard tile, and every `/api/query` call ultimately executes one of these templates against the DuckDB object catalog.

This is the **overview** page. FM-Lab groups templates by **who calls them and
how** — each tier lives in its own directory, is resolved by a distinct part of
the system, and has its own page:

| Page | Directory | In one line |
|---|---|---|
| [Built-in Query Templates](Built-in%20Query%20Templates.md) | `rest-api/templates/sql/` | The shipped backbone of `/api/query` — object details, counts, graph. |
| [Custom Query Templates](Custom%20Query%20Templates.md) | `rest-api/templates/sql-custom/` | Your own named queries; appear in the *Custom Queries* dashboard. |
| [Detail View Templates](Detail%20View%20Templates.md) | `rest-api/templates/sql-custom-details/` | Internal detail-view SQL loaded by UI hooks; not listed publicly. |
| [Dashboard Datasets](Dashboard%20Datasets.md) | `rest-api/templates/dashboards/` · `dashboards-custom/` | Per-tile datasets inside dashboard bundles. |
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
parsed by the template service and drive discovery, the Custom Queries listing
and dashboard tiles. Common keys:

| Key | Purpose |
|---|---|
| `@template_type` | `report`, `content` (the `object_details_*` family), `object` — how the result is consumed |
| `@title` / `@description` | shown in listings and on tiles |
| `@params` | expected parameters (with optional/default notes) |
| `@output_format` | the columns the template returns |
| `@display` | tile rendering hint (`table`, …) |
| `@click_action` / `@click_args` | make a row navigate (e.g. `openObject`) |
| `@icon` / `@category` / `@tags` | grouping and iconography |
| `@author` / `@version` | provenance |

## Parameters

Templates are parameterised so one file answers a family of questions. Three
substitution styles are supported and may be mixed:

| Style | Example | Typical use |
|---|---|---|
| Named | `:file_name` | dashboard bundles, the file view |
| Positional | `$1`, `$2` | short, order-based calls |
| DuckDB variable | `getvariable('file_name')` | built-in query templates |

Values are escaped server-side (single quotes doubled, `NULL` for missing
params, `TRUE`/`FALSE` for booleans), so a template stays injection-safe. A
missing named/positional parameter resolves to `NULL` — the common
`getvariable('x') IS NULL OR col = getvariable('x')` idiom turns that into an
"all rows" fallback.

> **`:param` caveat.** In dashboard datasets every bare `:word` with no matching
> parameter is replaced by `NULL`. Watch out for stray colons (a `::CAST`, a
> `localhost:3003`) — they can be mis-read as parameters.

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
- **Adaptability** — custom templates override built-in ones by name, allowing every installation to tailor analyses to its own conventions.
- **Expressive DuckDB SQL** — window functions, `GROUP BY ALL`, `COLUMNS(...)`, list/struct types, recursive CTEs, and graph-style traversals are all fair game. Even advanced analyses such as dependency walks, dead-code detection, or coupling metrics remain concise, readable SQL templates.
- **Multiple output formats** — templates are responsible only for producing results. Output adapters selected by request parameters transform those results into tabular data, generated text, or other predefined representations. Queries that already produce their final format can bypass adaptation entirely through the `raw` adapter.

## See also

- [Query and Report API](../rest-api/endpoints/Query%20and%20Report%20API.md) — the endpoints that execute templates
- [REST API Output Formats](../rest-api/REST%20API%20Output%20Formats.md) — how a result is rendered
- [Folder structure](../Wiki/Folder%20structure.md) — where templates and the catalog live
- [REST API](../rest-api/REST%20API%20Overview.md) — the API these templates sit behind
