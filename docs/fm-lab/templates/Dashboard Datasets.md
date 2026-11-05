# Dashboard Datasets

**Directories:** `rest-api/templates/dashboards/` (shipped) ·
`rest-api/templates/dashboards-custom/` (your own) ·
`rest-api/templates/dashboards-community/` (reserved) ·
**Config:** `DASHBOARDS_DIR`, `DASHBOARDS_CUSTOM_DIR`, `DASHBOARDS_COMMUNITY_DIR`, `DASHBOARDS_REMOVED_DIR`

A dashboard comes in two forms. This page describes the **bundle**: a folder
with a manifest, a layout, localisations, and a `data/` directory of SQL
datasets — one `.sql` per tile. These datasets are the SQL-template tier that
feeds dashboards. The smaller form — one `.sql` file with a header, rendered as
a table — is described in [Single-file Dashboards](Single-file%20Dashboards.md); both live side by side
in the same folders and share one id namespace. Part of the [SQL Templates](SQL%20Templates.md)
family.

## Anatomy of a bundle

```
dashboards/system/home/
├── manifest.json     # id, version, title, datasets[], params[], permissions
├── layout.json       # the tiles and how they arrange
├── locales/          # per-language strings (de, fr, ja, …)
└── data/             # one .sql per dataset
    ├── project_summary.sql
    ├── object_counts.sql
    └── files_overview.sql
```

The shipped bundles under `dashboards/` fall into three areas. `system/` holds
the app surfaces — among them **home** (project summary, object counts, files
overview, recently changed objects) and **file** (per-file info, change stamps,
triggers, start layout, accounts). `modules/` holds the overview and index
pages of the modules (dashboards, tests, docs incl. the docset views).
Everything else is shipped content in its rubric folder —
`static-code-analysis/`, `modularization/`, `developer-workflow/`,
`metadata-integrity/` and `changelog/` with the
[recent changes](../schema/catalog-tables/ObjectChangeMeta.md#recent-changes-dashboard) (work sessions and
mass events), and the rubrics of [Single-file Dashboards](Single-file%20Dashboards.md) (`layouts/`,
`scripts/`, `schema/`, `top/`). Your own dashboards live under
`dashboards-custom/`, directly on that level or grouped in sub-folders.

## The manifest wires datasets to tiles

Each entry in `datasets[]` names a source. Four source kinds:

```json
"datasets": [
  { "id": "project_summary", "source": "bundle:data/project_summary.sql" },
  { "id": "cluster_count",   "source": "builtin:cluster_count" },
  { "id": "nav_dashboards",  "source": "builtin:list_dashboards",
    "params": { "excludeTags": ["home", "nav", "internal", "system"] } }
]
```

- **`bundle:data/<file>.sql`** — a dataset SQL file inside this bundle.
- **`custom:<name>`** — reuse a [single-file dashboard](Single-file%20Dashboards.md) as a dataset (`dashboards-custom/` first, then `dashboards/`, `dashboards-community/` and the old location `sql-custom/`), else a [module template](Detail%20View%20Templates.md) (`queries/modules/`), else a bundle's own `queries/` folder.
- **`report:<template>`** — reuse a [built-in system template](Built-in%20Query%20Templates.md) (`queries/system/**/<template>.sql`).
- **`builtin:<name>`** — reuse a shared built-in dataset (with optional `params`).

A bundle can also ship its own drilldown templates in an optional `queries/`
folder; they resolve by name like any template (last stage of the template
lookup) and keep the dashboard self-contained.

Bundle-level `params[]` (e.g. an optional `file` filter) flow into the datasets
as named parameters.

A server-paged dataset (see [Paging, sorting and search](#paging-sorting-and-search)) declares its page
size and URL parameters on its `datasets[]` entry:

```json
{ "id": "findings", "source": "bundle:data/findings.sql", "pageSize": 500 },
{ "id": "drivers",  "source": "bundle:data/drivers.sql",  "pageSize": 100,
  "pageParam": "drivers_page", "searchParam": "drivers_q", "sortParam": "drivers_sort" }
```

- **`pageSize`** — rows per page (1–10,000, or `"all"`); without it 500.
- **`pageParam`**, **`searchParam`**, **`sortParam`** — the URL parameters of
  the table (default `page`, `q`, `sort`; the direction travels in `dir`, or
  `<sortParam>_dir` for any other name). The backend maps them onto the SQL
  variables `page` and `q`, so the SQL always reads the same names.
- **`sortColumns`** (optional) — restricts which output columns are sortable.

## Parameters — the `:param` caveat

Dashboard datasets typically use the **named** `:param` style. The interpolator
replaces every `:` followed by a word character (letter, digit, underscore) with
the matching parameter or, without one, with `NULL` — in string literals and
comments too. Every `$n` is replaced the same way, as a positional parameter.
A stray colon is misread as a parameter and nulled out:

- the second colon of a `::` cast → write `CAST(x AS VARCHAR)`;
- the `:3` of a list slice `[1:3]` → write `list_slice(list, 1, 3)`;
- `localhost:3003`, `'%H:00'` or a `key:value` literal → split the string
  (`'%H' || ':' || '00'`).

Keep colons and dollar signs deliberate.

## Column conventions

Result columns whose name starts with `_` are **technical**: the list/table
primitives neither display them nor include them in the client-side row search.
Use the prefix for plumbing columns like `_click_action` / `_click_args`
(navigation wiring) or validation metadata. Two of them carry chip-bar data:
`_chip_facets` (a JSON `{value: count}` map — the facet distribution over the
**whole** result before the search and the chip itself, not just the returned
page) and `_row_total` (the row count of the current selection), which let a
chip bar show true counts on paged results. A server-paged table reads two
more: `_page` (the page the SQL actually returns, after clamping to the last
page) and `_page_size` — see below. The helper columns of the paging frame
carry the prefix as well (`_ord_*`, `_pg_*`, `_row_seq`, `_sort_<column>`).
Three names are reserved
and stay un-prefixed by design: `uuid`,
`nav_uuid` and `row_key`. Docset-facing built-ins report entry counts as
`entries` / `entry_count` (the generic terms — a docset entry can be a
function, a script step or a page).

## Paging, sorting and search

Every list that can return more than one page pages, sorts and searches **on
the server**; a fixed `LIMIT` remains only for deliberate rankings and short
group lists (see *No silent cap* in [Single-file Dashboards](Single-file%20Dashboards.md)).

**The SQL frame** is the one of the paged custom queries, with three bundle
specifics:

- The former last `SELECT` becomes `unkeyed AS MATERIALIZED`. Expressions of
  the previous order that are not output columns (`oc.File_Name`, a `CASE` on
  the severity) travel along as hidden columns `_ord_1 …`.
- `result AS MATERIALIZED` drops the `_ord_*` columns and numbers the rows:
  `row_number() OVER (ORDER BY u._ord_1, …, u) AS row_key` — the whole row `u`
  breaks the remaining ties, so every request assigns the same key and pages
  from separate requests fit together.
- The table search uses the block `shared paging table-search block`; besides
  `_` columns and `uuid` it skips `nav_uuid` and `row_key`, exactly like the
  client-side table search.

The frame ends in `ORDER BY /*@sort*/ row_key, f` plus `LIMIT`/`OFFSET` from
`pg`, and the fallback page size inside the window block equals the manifest
`pageSize`. Page 1 without parameters is the previous result, so Analysis Tests
and other callers without paging parameters see the same rows as before. The
bundle `static-code-analysis/unused_code/variable_set_never_read` is the
reference; `static-code-analysis/best_practices/relationship_with_sort` adds a
server chip.

**The table** (`Table` in `layout.json`) opts in with props:

| Prop | Effect |
|---|---|
| `pageParam`, `searchParam`, `sortParam` | the URL parameters, same names as in the manifest; a header click writes `sort`/`dir` and returns to page 1 |
| `clientMode: true` | while the whole result fits on one page and no sort or search term sits in the URL, sort and search stay local; set it only when the search parameter filters this dataset alone |
| `columns[].sortKey`, `columns[].sortable: false` | sort another output column for this header, or keep a header unclickable |
| `chipFilter: { field, param }` | server chips: a click writes `param`, the SQL filters in `filtered`, the counts come from `_chip_facets` |

The search field sends its term after a short pause, the pager shows above and
below the table, and paging keeps the scroll position. A `chipFilter` without
`param` would count and filter just the loaded page; on a paged table it is not
allowed.

**The surrounding layout:**

- The `Card` that binds the dataset sets `keepChildrenOnEmpty: true` — a search
  without hits must not remove the search field.
- `FilterChips` in the same card reset the page: `"resetParams": ["page"]`.
- Several paged tables on one dashboard carry their own parameter names
  (e.g. `drivers_page`, `drivers_q`, `drivers_sort`), in the layout and in the
  manifest; otherwise one search or page would drive all of them. A dashboard
  parameter that already means something else (e.g. a `sort` that selects a
  measure) needs a different sort parameter name as well.

A unit test (`rest-api/tests/unit/paging-templates.test.js`) checks the frame,
the shared blocks and these layout rules for every paged dataset.

**Small, fully loaded lists** page in the browser instead — no paging
parameters, no SQL frame. The table opts in with props:

| Prop | Effect |
|---|---|
| `pageSizeOptions: ["all", 10, 25, 50, 100]` | page-size select in the count bar (shown above the smallest numeric option) and a pager above and below the table |
| `defaultPageSize` | `"all"` (default), a number, or `"auto"`: every row up to `autoPageSizeThreshold` rows (default 100), above it the threshold option; a choice of the user overrides it |
| `defaultSort: { field, dir }` | start sort of a client-sorted table (`sortable: true`), shown with its indicator |
| `keyboardNav: true` | ↑/↓ move between the rows (across pages), Home/End within the page, PageUp/PageDown turn it, Enter opens the row |
| `stateKey` | sort, page size, page and focus row survive reload and "back"; sort and page size also seed a new browser tab |

These props are ignored on a table with `pageParam`. The files table on the
start page (bundle `system/home`) uses all of them.

**Changelog lists.** The datasets of the Changelog dashboards
(`dashboards/changelog/`) search in their shared filter block, because the term
filters the KPIs and charts of the dashboard as well. They therefore run
always on the server (no `clientMode`), page the rows of `result` through the
variant `shared paging changelog-window block`, keep `row_key` as the row's
identity (e.g. object UUID and file) and order the pages by a hidden
`_row_seq`.

**Multi-value filters.** A filter dropdown can allow several values. It writes
them comma-separated into one parameter (`type=Script,Layout`); the SQL splits
the list (`string_split`) and tests membership. No value chosen means no
filter. Filters reset the page when they change, so a new filter starts on
page 1. The bundle `changes` (`dashboards/changelog/changes/`) is the
reference.

## Chart datasets

The chart tiles (activity map, stacked time series, sparkline) only draw: the
dataset delivers every bucket, level and drill-down window ready-made.

- **One row per cell or bucket, empty ones included.** Generate the frame with
  `generate_series` and join the data onto it, so a gap stays visible as a gap.
- **Times as text.** Return bucket bounds and labels via `strftime`, not as
  `TIMESTAMP`: the API sends a timestamp as UTC, and the browser would shift a
  local client time by its own time zone. The drill-down window per cell
  (`from_at`, `to_at`) is text as well and goes straight into the click action.
- **Lists of structs as a column** carry small detail sets, e.g. the top three
  types of a cell for the tooltip: `[{key: 'Script', n: 12}, …]`. The API
  converts `BIGINT` to a JSON number only in top-level columns — cast counts
  inside a list or struct to `INTEGER`, otherwise the response fails to
  serialize. Cut the list with `list_slice`, not `[1:3]` (see the `:param`
  caveat).

The datasets `activity_map.sql` and `activity_series.sql` of the bundle
`changes` are the reference.

## Areas and overrides

The storage location decides a bundle's area, and the area decides where it
appears in the dashboard overview:

| Area | Location | In the overview |
|---|---|---|
| system | `dashboards/system/**` | no — app pages, reached through the main navigation |
| module | `dashboards/modules/**` | no — module overview and index pages |
| builtin | `dashboards/<rubric>/…` | yes, in its rubric folder |
| custom | `dashboards-custom/**` | yes, under **Custom** |
| community | `dashboards-community/**` | yes, under **Community** (shown once it holds dashboards) |

The areas hold bundles and single-file dashboards alike.

The folder path of a custom bundle starts with `custom/` (a community bundle's
with `community/`), so your own folders never collide with shipped rubrics. The
names `system`, `modules`, `custom` and `community` are reserved at the top of
`dashboards/`.

On an id collision a **custom dashboard overrides a builtin one** — bundle or
file on either side — the overview marks it with the badge *overrides
standard*, and the shipped original drops out of the list. Ids of system and
module bundles are reserved: a custom bundle with such an id is ignored (logged
as a warning), and a community dashboard never overrides anything.

`rest-api/templates/dashboards/inventory.json` lists every bundle, single-file
dashboard (`unit: "file"`) and folder the release ships. It is not a bundle setting — the dashboard cleanup compares
the installed tree with it to find folders left over from an earlier layout
and own files at old locations (see [Dashboard overview](../Wiki/Components.md#dashboard-overview)) and moves them to
`rest-api/templates/dashboards-removed/<timestamp>/`. That folder is ignored by
git, never listed in the overview and belongs to you: delete its content when
you no longer need it.

## Object types

The block `analysis.objectTypes` of a manifest — for a single-file dashboard
the header key `@object_types` — names the object types the dashboard's rows
point at — the values of `ObjectCatalog.Object_Type`
(`Script`, `Layout`, `Field`, `CustomFunction`, `TableOccurrence`, …):

```json
"analysis": {
  "objectTypes": ["Script", "LayoutObject"]
}
```

The object-type filter of the dashboard overview reads only this declaration,
so it works without computing anything. Declare it whenever a dataset emits an
`AS nav_uuid` column; a bundle without object rows (statistics, change lists)
leaves it out and appears under *Without object type*. The same list tells
[Analysis Tests](../Wiki/Analysis%20Tests.md) which objects a dashboard member applies to in object scope.

## Creating a dashboard

Use the [create-custom-dashboard](../skills/Skill%20create-custom-dashboard.md) skill: it
clarifies the goal, drafts and confirms the SQL, recommends the build form —
single file or bundle — and an interactive pattern, and writes either
`dashboards-custom/[<folder>/]<id>.sql` or the full bundle under
`dashboards-custom/[<folder>/]<id>/` (manifest, layout, `data/*.sql`, locales),
including the object types of its rows.

## See also

- [SQL Templates](SQL%20Templates.md) — overview, metadata header, parameters
- [Single-file Dashboards](Single-file%20Dashboards.md) — one query as a dashboard instead of a full bundle
- [Query and Report API](../rest-api/endpoints/Query%20and%20Report%20API.md) — how datasets ultimately execute
