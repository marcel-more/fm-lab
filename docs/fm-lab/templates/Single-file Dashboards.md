# Single-file Dashboards

**Directories:** `rest-api/templates/dashboards/<folder>/` (shipped) ·
`rest-api/templates/dashboards-custom/` (yours) · `rest-api/templates/dashboards-community/`
(installed packages) · **Config:** `DASHBOARDS_CUSTOM_DIR` · **Served by:**
[/api/query](../rest-api/endpoints/Query%20and%20Report%20API.md) and the dashboard endpoints ·
**Surface:** the dashboard overview `/dashboard`

A single-file dashboard is the smallest form of a dashboard: **one `.sql` file
with a `-- @` header**. Put it into a folder of a dashboard area and it is a
dashboard — listed in the overview, opened at `/dashboard/<name>`, callable by
name through `/api/query` — with no manifest, no layout, no code change. Part
of the [SQL Templates](SQL%20Templates.md) family; the other form is the bundle described in
[Dashboard Datasets](Dashboard%20Datasets.md).

| | Single-file dashboard | Bundle |
|---|---|---|
| Files | `<name>.sql` | `<name>/manifest.json`, `layout.json`, `data/*.sql`, `locales/` |
| Display | title card + one table (sort, search, row click, chip bar, server paging) | any layout: KPI tiles, filters, several panels, notes |
| Languages | English | 11 locales |
| Good for | lists, inventories, rankings, test members | overviews, drilldowns, multi-facet reports |

Both forms share everything else: one id namespace, folders, the overview with
its folder, list and favorites views, the star, the findings value, the
object-type filter, [Analysis Tests](../Wiki/Analysis%20Tests.md) membership, cleanup and overrides.

## Where the file goes

```
rest-api/templates/dashboards-custom/
├── my_list.sql                  Dashboards / Custom / <title>
└── team/                        Dashboards / Custom / Team
    ├── folder.json              optional: title, icon, description, order, locales
    └── weekly_check.sql         Dashboards / Custom / Team / <title>
```

- The **id** is the file name without `.sql` (`[a-zA-Z0-9_-]+`). Bundles and
  single files share one namespace.
- A file sits directly in an area or in a grouping folder (up to four levels).
  `.sql` files inside a bundle directory (`data/`, `queries/`) belong to that
  bundle and are never dashboards of their own; the top level of the shipped
  `dashboards/` holds no files.
- The shipped single-file dashboards live in the rubric folders `layouts/`,
  `scripts/`, `schema/`, `top/` and `metadata-integrity/` of
  `rest-api/templates/dashboards/` — copy one to start.
- `dashboards-custom/` is ignored by git except its scaffold; updates never
  touch it.

## The header

One key per line, `-- @<key>: <value>`; lists are comma-separated. The server
derives the dashboard's manifest from it.

```sql
-- @template_type: report
-- @title: Top scripts
-- @description: Scripts with the most steps.
-- @icon: script
-- @params: limit (optional, default 100), file (optional)
-- @click_action: openObject
-- @click_args: uuid={{uuid}}&type=Script&file={{file}}
-- @output_format: uuid, name, file, step_count
-- @object_types: Script
-- @author: fm-lab core
-- @version: 1.2
-- @tags: scripts, top, ranking

SELECT ...
```

| Key | | Effect |
|---|---|---|
| `@template_type` | required | `report` for dashboards |
| `@title` | required | title in the overview, the breadcrumb and the title card (missing: the humanized file name, with a warning in the log) |
| `@description` | required | tooltip, overview search, title card |
| `@object_types` | recommended | object types the rows point at — the overview's object-type filter reads only this |
| `@default_result` | recommended | the findings value (see below) |
| `@click_action` / `@click_args` | recommended | row click — e.g. `openObject` with `uuid`, `type`, `file`; `{{column}}` tokens are filled from the row |
| `@params` | recommended | `name (optional\|required, default <value>, <description>)`; `none` for no params. `file` is always accepted |
| `@output_format` | recommended | the columns in order (documentation — the table takes its columns from the result) |
| `@icon`, `@tags`, `@author`, `@version` | recommended | tile icon (default `query`), search terms, provenance |
| `@row_action` / `@row_action_args` / `@row_action_label` | optional | a second click target — an arrow button at the end of each row |
| `@chip_filter` / `@chip_param` | optional | chip bar over one column, see below |
| `@page_param`, `@search_param`, `@sort_param`, `@page_size`, `@sort_columns` | optional | server paging, see below |
| `@scope`, `@output_types` | optional | scopes and output types for [Analysis Tests](../Wiki/Analysis%20Tests.md) |
| `@display` | optional | informational |

`@category` has no effect any more — the folder decides where a dashboard
appears. Columns whose name starts with `_` stay hidden in the table but are
available as click tokens.

### Findings value

```sql
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "tooltips", "meaning": "Layout objects with a tooltip in scope (inventory — not a defect count)" }
```

`aggregate` is `row_count` (the number of returned rows — with server paging
at most one page) or `first_row:<column>` (that column of the first row).
`type` is `number`, `boolean` or `text`; `meaning` becomes the tooltip of the
value in the overview's *Findings* column. A single-file dashboard has no
severity — its state columns stay empty. Without `@default_result` the
dashboard shows no value and cannot be a test member.

### Chip bar

`@chip_filter` names the result column whose values become the chips,
`@chip_param` the query parameter a selected chip sets — so a chip filters
**server-side** through a re-query, not by hiding client rows. The chip counts
come from the result column `_chip_facets` (a JSON `{value: count}` map over the
*whole* result before the search and the chip itself) and `_row_total` (the row
count of the current selection) — see the column conventions in
[Dashboard Datasets](Dashboard%20Datasets.md).

## Server paging, sorting and search

A dashboard whose result can exceed one page pages, sorts and searches **on the
server**, so counts, sort order and search hits always cover the whole result
and not just the loaded rows. Four header keys declare it:

```sql
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 500
-- @sort_columns: layout_name, overlap_px      (optional: restricts sortable columns)
```

The SQL ends in a fixed frame. The former last `SELECT` becomes the CTE
`result` (all output columns, all filters except search and chip, no `ORDER BY`,
no `LIMIT`); two marked blocks follow, shared verbatim by every paged query:

```sql
WITH … existing CTEs …,
result AS MATERIALIZED (
    SELECT … AS file_name, … AS layout_name, …   -- the output columns
    FROM …
),
-- >>> shared paging search block
haystack AS (…), searched AS (…)                 -- filters on the term in q
-- <<< shared paging search block
filtered AS (                                    -- only with a chip
    SELECT * FROM searched
    WHERE getvariable('relation') IS NULL OR relation = getvariable('relation')
),
-- >>> shared paging window block
pg AS (…)                                        -- page size, total, clamped page
-- <<< shared paging window block
SELECT f.*,
    (SELECT to_json(map_from_entries(list((relation, n) ORDER BY relation)))
       FROM (SELECT relation, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ overlap_px DESC, file_name, layout_name, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
```

Copy the two blocks from any paged shipped dashboard (for example
`rest-api/templates/dashboards/layouts/layout_overlap_explorer.sql`) — a unit
test keeps all copies identical; only the fallback page size inside the window
block differs and equals `@page_size`.

- **`MATERIALIZED` is required.** `result` is read for the count, the facets
  and the page; without the hint DuckDB recomputes it several times.
- **Default order.** The final `ORDER BY` keeps the query's previous order and
  ends with the whole row `f` as last tiebreak, so the order is total and no row
  appears twice or goes missing across pages.
- **Sorting.** `?sort=<column>&dir=asc|desc` sorts by any visible output column
  (or only those in `@sort_columns`). The backend replaces the marker
  `/*@sort*/` with the quoted column name — a name it has read from the query's
  own output columns, never text from the URL — plus `ASC` or `DESC`; text sorts
  case-insensitively, empty values come last. An unknown column leaves the
  default order. A hidden companion column `_sort_<column>` (a rank, or the raw
  number behind a formatted text) takes the column's place in the sort.
- **Page size.** A request may override it with `page_size` (API only; the page
  URL never passes it on), otherwise `@page_size` applies, otherwise 500. Every
  number is clamped to 1–10,000; `all` returns up to 10,000 rows without a pager.
- **Search.** The search block covers the same columns the table searches on
  the client: every visible column except `uuid`.
- **Chip counts** ignore the search: the facets count over `result`, while the
  hit count of a search shows in `_row_total`. The ordered map keeps the JSON
  text the same in every request (`json_group_object` does not fix the key
  order).

**Client and server mode.** As long as the whole result fits on one page and
neither a sort nor a search term sits in the URL, the table sorts and searches
the loaded rows locally — instantly, in natural order. A larger result, a sort
or a search term in the URL switches to the server; a local sort and search
move into the URL at that moment. The pager shows above and below the table; the
scroll position stays when paging.

**No silent cap.** A fixed `LIMIT` remains only for deliberate rankings (the
`top_*` dashboards). A unit test (`rest-api/tests/unit/paging-templates.test.js`)
fails for any shipped query or dataset with a `LIMIT` of 100 or more, or a
parameterised one, that neither pages, nor names the cut-off in `_row_total`,
nor stands on its exception list with a reason.

## Creating one

The [create-custom-dashboard](../skills/Skill%20create-custom-dashboard.md) skill builds a
single-file dashboard (or a bundle — it recommends the form). By hand:

1. Add `rest-api/templates/dashboards-custom/[<folder>/]<name>.sql` with a
   header and DuckDB SQL.
2. Parameterise with `getvariable('name')`
   (see [Parameters](SQL%20Templates.md#parameters)).
3. Save — the dashboard appears in the overview within two seconds, no reload
   needed. It opens at `/dashboard/<name>` and answers
   `/api/query?template=<name>`.

```bash
curl "http://localhost:3003/api/query?template=top_scripts&params=%7B%22limit%22%3A20%7D"
duckdb -readonly db/fm_catalog.duckdb -c ".read rest-api/templates/dashboards/top/top_scripts.sql"
```

The file also runs without the server: unset variables are `NULL` in the
DuckDB CLI, exactly as in the API; `SET VARIABLE file = '<name>'` sets one.

## Override behaviour

A dashboard in `dashboards-custom/` with the id of a shipped dashboard **wins**
— whether either side is a file or a bundle — and the overview marks it as
*overrides standard*. That makes `dashboards-custom/` the right place to tune a
shipped query for your installation: copy it, adjust it, keep the name.
Community dashboards never override. A single-file dashboard named like an
internal template ([system](Built-in%20Query%20Templates.md) or
[module](Detail%20View%20Templates.md)) is ignored with a warning.

## From file to bundle and back

- **File → bundle**: create a bundle directory and either move the file to
  `data/<name>.sql` (dataset `bundle:data/<name>.sql`) or keep it as a file
  under another name and reference it as the dataset `custom:<that name>`.
  Header params become manifest params; `@object_types`/`@default_result`
  become the manifest's `analysis` block.
- **Bundle → file**: a bundle with one dataset and a plain table becomes a
  file: the dataset SQL plus a header built from the manifest.

## Former location `sql-custom/`

Earlier releases kept own queries in `rest-api/templates/sql-custom/`. Files
there still work for one release: they appear under **Dashboards / Custom**
with the badge *old location*, and `custom:<name>` keeps resolving. The
cleanup box on `/dashboard` moves them to `dashboards-custom/<name>.sql`; see
[Maintenance API](../rest-api/endpoints/Maintenance%20API.md).

## See also

- [SQL Templates](SQL%20Templates.md) — overview, metadata header, parameters
- [Dashboard Datasets](Dashboard%20Datasets.md) — the bundle form
- [Analysis Tests](../Wiki/Analysis%20Tests.md) — single-file dashboards as test members
- [Built-in Query Templates](Built-in%20Query%20Templates.md) · [Detail View Templates](Detail%20View%20Templates.md) — the internal templates
