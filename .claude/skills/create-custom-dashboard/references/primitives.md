# Primitive & action reference

Verified against `apps/web/src/dashboard/primitives/registry.ts`,
`apps/web/src/dashboard/actions.ts`, `apps/web/src/dashboard/actionState.ts` and
`rest-api/src/services/dashboard-schemas.js` (2026-07-17). When a prop is not
listed here, check the primitive's source file instead of guessing.

## Layout node shape

```json
{
  "type": "<Primitive>",
  "id": "<stable_node_id>",
  "props": { ... },
  "data": { "dataset": "<dataset_id>" },
  "visibleWhen": { "dataset": "<id>", "field": "<col>", "equals": <value> },
  "children": [ ... ]
}
```

- **`id` is mandatory on every node this skill generates** (`^[a-zA-Z0-9_-]+$`).
  Convention: `<card>_<primitive>` (`summary_kpistrip`, `url_details_table`). IDs
  anchor the locale overrides (see `references/localization.md`) and survive
  layout restructuring — the legacy positional paths do not.
- `data.dataset` binds a dataset. Children inherit the container's dataset; a
  child may bind its own. `KPIStrip`, `DefinitionList`, `FilterChips`, `Select`
  and `Slider` read the **first row** of their bound dataset.
- `visibleWhen` (optional, any node): show the node only when the first row of
  `dataset` satisfies `equals` / `notEquals` / `truthy` on `field`.

## Container primitives

| Primitive | Props (defaults) |
|---|---|
| `Grid` | `columns` (12), `gap` (16) — always the root |
| `Card` | `span` (12), `title`, `subtitle`, `variant` (`"hero"` = gradient, purely cosmetic) |
| `Stack` | `gap` (12), `align` (`stretch`), `span` |
| `Row` | `gap` (12), `align` (`center`), `span` |
| `Spacer` | `size` |

Span values: `12` full, `6` half, `4` third, `8`+`4` two-thirds + third.

**Card title convention:** the dashboard title box comes from `manifest.title` —
the first card carries **no** `title` (no `"Overview"` filler either). Only
follow-up cards get a title, and only a genuine section label.

## Value primitives (single row)

| Primitive | Props |
|---|---|
| `KPI` | `label`, `field`, `format`, `onClick` (ActionSpec) |
| `KPIStrip` | `items[]` of `{ label, field, format?, onClick? }` |
| `DefinitionList` | `items[]` same shape, rendered as "Label / value" rows (settings-style panels) |

**Clickable KPIs** (the filter-hero pattern): give an item `onClick` with an
`openDashboard` self-navigation whose `args.params` set a filter param. The tile
renders as a button and gets an **active state** automatically when the URL params
match `args.params` (see §Active state below).

## Collection primitives (many rows)

### `List`
```json
{ "type": "List", "props": {
  "rowTemplate": {
    "primary":   "{{name}}",
    "secondary": "{{file}} · {{step_count}} steps",
    "tertiary":  "…", "quaternary": "…",
    "badge":     "{{ref_count}}",
    "badgeOptions": { "hideZero": true, "filterable": true, "filterLabel": "used", "onClick": { … } },
    "onClick":   { "action": "openObject", "args": { "uuid": "{{uuid}}", "type": "Script", "file": "{{file}}" } },
    "inlineControl": "docsInstall"
  },
  "searchable": "auto", "searchAutoThreshold": 3, "searchPlaceholder": "Search …",
  "empty": { "message": "No entries found." }
}}
```
`badgeOptions.filterable` adds a toggle that hides zero-badge rows (only rendered
when both used and unused rows exist).

### `Table`
```json
{ "type": "Table", "props": {
  "rowKey": "<unique column>",
  "density": "comfortable | compact",
  "sortable": true,
  "searchable": "auto", "searchAutoThreshold": 3, "searchPlaceholder": "Search …",
  "columns": [
    { "field": "at",    "label": "Changed", "nowrap": true },
    { "field": "name",  "label": "Name" },
    { "field": "count", "label": "Count", "align": "right", "format": "number" }
  ],
  "chipFilter": { "field": "<col>", "allLabel": "All",
                  "groups": [ { "label": "If / Else If", "values": ["If", "Else If"] } ] },
  "onRowClick": { "action": "openObject",
                  "args": { "uuid": "{{uuid}}", "type": "{{type}}", "file": "{{file}}" } },
  "empty": { "message": "…" }, "alwaysShowCount": true
}}
```
`chipFilter` renders value chips (with counts) above the table. Without
`param` it filters **client-side** — only within the loaded rows. With
`"param": "<url param>"` it is a **server chip**: a click writes the param, the
SQL filters the whole result and reports the counts in `_chip_facets` (decision
rule in `references/patterns.md`). `groups` apply to client chips only; a server
chip groups values in the SQL (a hidden chip column, e.g. `_chip_step`).

`nowrap: true` keeps a column on one line (timestamps, names, counts); the
remaining columns absorb the width and wrap instead.

**Server-side paging** — for every list that can outgrow one page (the rule,
not the exception; a fixed `LIMIT` is only for Top-N rankings and short group
lists):

```json
{ "type": "Table", "props": {
  "rowKey": "row_key", "sortable": true, "searchable": "auto",
  "pageParam": "page", "searchParam": "q", "sortParam": "sort", "clientMode": true,
  "chipFilter": { "field": "<col>", "param": "<col>" },
  "columns": [ { "field": "step", "label": "Step", "sortKey": "step_no" },
               { "field": "message", "label": "Message", "sortable": false } ]
}}
```
- The SQL pages, sorts and searches (frame in `references/sql-rules.md`) and
  reports the window on every row: `_row_total` (rows of the current selection),
  `_page` (effective page after clamping) and `_page_size`. The pager shows
  above and below the table; paging keeps the scroll position.
- A header click writes `sortParam` (column name, or `sortKey`) and the
  direction (`dir`, or `<sortParam>_dir`) and returns to page 1; the backend
  sorts the whole result. `sortable: false` keeps a header unclickable.
- `searchParam`: the term goes into the URL after a short pause; the SQL filters
  on the same columns the client search covers.
- `clientMode: true`: while the whole result fits on one page and neither a
  sort nor a search term sits in the URL, the table sorts and searches locally
  (natural order, no request). Set it only when the search param filters this
  dataset alone (not when `q` also drives KPIs or charts).
- Declare the same names in the manifest dataset entry (`pageSize`,
  `pageParam`, `searchParam`, `sortParam`). Several paged tables on one
  dashboard need their own names (`drivers_page`, `drivers_q`, `drivers_sort`).
- The `Card` that binds the dataset sets `"keepChildrenOnEmpty": true`, so a
  search without hits keeps the search field; `FilterChips` in that card set
  `"resetParams": ["page"]`.
- A `chipFilter` without `param` on a paged table is not allowed (it would count
  one page); a unit test enforces this and the two rules above for the shipped
  bundles — a custom bundle is not covered by it, so follow them by hand.
- Without `pageParam`, a `_row_total` above the loaded rows only names the
  cut-off of a LIMIT-capped result ("500 of 3,104").
- Reference bundles: `dashboards/static-code-analysis/unused_code/variable_set_never_read`
  (FilterChips + paging), `…/best_practices/relationship_with_sort` (server chip).

**Client paging, page-size select, keyboard navigation** — for a list whose
rows are all loaded anyway (small, bounded sets such as the files of a
solution). Not for a result that can grow large: that one pages on the server.

```json
{ "type": "Table", "props": {
  "rowKey": "File_Name", "sortable": true,
  "defaultSort": { "field": "File_Name", "dir": "asc" },
  "pageSizeOptions": ["all", 10, 25, 50, 100],
  "defaultPageSize": "auto", "autoPageSizeThreshold": 100,
  "keyboardNav": true,
  "stateKey": "fmlab.<dashboard>.<table>",
  "columns": [ … ], "onRowClick": { … }
}}
```
- `defaultSort`: start sort of a client-sorted table, shown with its indicator.
  Sortable headers are buttons (Tab, Enter/Space) and carry `aria-sort`.
- `pageSizeOptions`: renders a page-size select in the count bar (only above
  the smallest numeric option) and pages the rows after chip, search and sort;
  the pager shows above and below. A new search, sort or chip returns to page 1.
- `defaultPageSize`: `"all"` (default), a number, or `"auto"` — every row up to
  `autoPageSizeThreshold` rows (default 100), above it the threshold option. A
  choice of the user overrides it.
- `keyboardNav`: the rows are one tab stop; ↑/↓ move the focus (across pages),
  Home/End jump within the page, PageUp/PageDown turn it, Enter runs
  `onRowClick`.
- `stateKey`: sort, chosen page size, page and focus row survive reload and
  "back" (tab level); sort and page size also seed a new tab (browser level).
  After Enter opened a row, "back" puts the keyboard focus on that row again.
  Use a unique key per table.
- Ignored together with `pageParam` (server paging owns sort and pages there).
- Reference bundle: `dashboards/system/home` (`files_overview_table`).

### `AutoTable`
Columns derived automatically from the dataset (columns prefixed `_` are always
hidden). Props: `exclude[]`, `sortable` (default **true**), `searchable` (default
**true**), `paginate` / `pageSize`, `maxHeight` ("70vh"), `density`,
`clickAction` + `clickArgs` ("k=v&k2=v2" with token substitution) or `metaDataset`.
Use for generic/exploratory outputs; prefer `Table` when you control the columns.

### `TileGrid`
```json
{ "type": "TileGrid", "props": {
  "tile": { "title": "{{name}}", "subtitle": "{{description}}", "icon": "{{icon}}",
            "badge": "{{count}}", "onClick": { "action": "openDashboard", "args": { "id": "{{id}}" } } },
  "minTileWidth": 220, "viewToggle": true,
  "searchable": "auto", "searchAutoThreshold": 3
}}
```

**Search rule (all three):** `searchable` accepts `true` / `false` / `"auto"`;
`"auto"` shows the field above `searchAutoThreshold` rows (frontend default 10).
This skill always emits `"searchable": "auto", "searchAutoThreshold": 3` on
List/Table/TileGrid — documented exception: fixed Top-N rankings with N ≤ 5.

## Filter primitives (server-side, URL param → `getvariable`)

These write their choice into a URL search param; the dashboard forwards **all**
URL params to every dataset, where the SQL reads them via `getvariable('<param>')`.
Because the query re-runs, counts are true totals (not LIMIT-capped).

| Primitive | Props | Use for |
|---|---|---|
| `FilterChips` | `param` (required), `default`, `options[]` of `{ value, label, countField? }`, `resetParams[]`; bind a summary dataset — `countField` reads its first row | 2–5 named lenses (all / without X / only X) with true-total counts |
| `Select` | `param` (required), `default`, `valueField` ("value"), `labelField` ("label"), `label`, `emptyOptionLabel`, `multiple`, `separator` (","), `resetParams[]`; options come from the bound dataset's rows | many options / data-driven option lists (e.g. classification sets, file pickers); `multiple: true` for "any of these types / files" |
| `Slider` | `param` (required), `label`, `min` (0), `max` or `maxField` (from bound dataset), `step` (1), `default`, `valueSuffix` | numeric thresholds |
| `ToggleChips` | `items[]` of `{ param, label, on, off, default, resetParams? }`, `resetParams[]` (shared); no dataset | several independent on/off switches in one chip bar (e.g. "Mass events", "Technical authors") — each chip flips its own param between `on` and `off` |

All four keep the URL canonical: at the default value the param is removed.
`resetParams` (FilterChips, Select, ToggleChips) names URL params dropped
together with every change — typically the page param of a server-paged `Table`.
`FilterChips` chooses one of several values for **one** param; use
`ToggleChips` when the chips are independent of each other. A chip whose param
only changes the view (e.g. hides a card) needs no `resetParams`.

**Multi-select** (`Select` with `"multiple": true`): a dropdown of checkboxes
that writes the chosen values, joined by `separator`, into one param; nothing
chosen = param absent = no filter. `emptyOptionLabel` captions that state ("All
types"); an × next to the control and the dropdown's first entry clear the
choice. The dropdown is rendered outside the card, so the card cannot clip it.
SQL side (a handful of values, so `list_contains` is fine — unlike the
`scope_uuids` block): see `references/sql-rules.md` §3. A value that contains the
separator cannot be selected on its own — pick another `separator` then.

**Sticky params.** By default a filter param is click-scoped: an `openDashboard`
self-navigation replaces the whole query string, so any param the click args do
not carry is dropped. Two ways to keep a *mode/lens* param alive across clicks:

- **Declare it sticky in the manifest** (preferred): `{ "name": "api_set",
  "type": "string", "required": false, "sticky": true, … }`. The frontend
  preserves manifest-sticky params on self-navigation automatically (new args
  still win over the preserved value). Reference: `modularization/external_apis`
  (`file`, `api_set`, `comment`).
- **Carry it in the click args** (works everywhere, also cross-dashboard):
  `"params": { "host": "{{host}}", "comment": "{{comment}}" }`.

A legacy base set (`api_set`, `file`, `comment`) is always sticky for backward
compatibility (`STICKY_DASHBOARD_PARAMS` in `apps/web/src/dashboard/actions.ts`).
Truly click-scoped filters (the thing a KPI tile or drilldown row *sets*) must
NOT be declared sticky — otherwise they can never be reset by a click that
omits them.

## Chart primitives (many rows, draw only)

Verified against `apps/web/src/dashboard/primitives/charts/*.tsx` (2026-10-25).
The charts compute nothing: the dataset delivers every bucket — empty ones
included — plus levels, series slots, labels and the drill-down window as text.
Each chart loads lazily on first use, has one tab stop (arrow keys move, Enter
opens) and passes the clicked row's tokens to its click action. Reference
bundle: `rest-api/templates/dashboards/changelog/changes/` (`activity_map.sql`,
`activity_series.sql`) and the file view's `system/file/data/change_trend.sql`.

| Primitive | Props | Dataset contract (one row per …) |
|---|---|---|
| `CalendarHeatmap` | `onCellClick` (ActionSpec), `ariaLabel` | **cell of the frame, empty cells included:** `grain` (`day` → `row` = weekday 0 = Monday, `col` = week; `hour` → `row` = day of the frame, `col` = hour, `row_label` names the day; `week` → one block per `year`, `row` = section of the month 0–4, `col` = month 0–11), `level` 0–4, `n`, `label`, `q1`/`q2`/`q3` (level thresholds for the legend), `bulk_objects`/`bulk_events` (ring marker, never a hue), `top_types`/`top_persons` (`[{key, n}]`, tooltip), `from_at`/`to_at`, `is_selected`, `count_mode` |
| `StackedTimeSeries` | `onBarClick` (ActionSpec), `height` (220), `ariaLabel` | **bucket × series** (a bucket without data keeps one row with `series` NULL): `bucket_index`, `bucket_label`, `tick` (short axis label), `series`, `series_label`, `slot` (1–7 palette, 0 = other, −1 = mass events, hatched), `series_total`, `series_members`, `n`, `bucket_n`, `bulk_objects`/`bulk_events` (flag above the column), `from_at`/`to_at`, `is_selected`, `stack_by`, `count_mode`, `bulk_mode` |
| `Sparkline` | `label` (names the single series), `valueField` (`n`), `labelField` (`month`), `onPointClick` (ActionSpec), `height` (40), `maxWidth` (360) | **point, in order:** the label column as text, the value column; any further columns feed the click tokens |

- **Colours** come from the theme tokens: `--color-chart-1…7` and
  `--color-chart-other` for the slots, `--color-heat-0…4` for the levels. The
  SQL decides the slot, so a series keeps its colour and its stack position
  whatever the filter — give a series a stable slot (fixed mapping or a rank
  over the whole solution), never a rank inside the current filter.
- **Levels:** 0 = empty cell, 1–4 = quartiles of the non-empty cells in view;
  give the busiest cell level 4 (plain quartiles leave equal values in the
  lightest level).
- **Legend of `StackedTimeSeries`:** click toggles a series, Shift- or
  Alt/Option-click isolates it, "All series" restores. The selection is not in
  the URL.
- **Drill-down:** the click action is usually a self-navigation with the cell's
  window, e.g. `{ "action": "openDashboard", "args": { "id": "<this>",
  "from": "{{from_at}}", "to": "{{to_at}}" } }`; keep the chart's frame
  independent of `from`/`to`, otherwise it collapses to the clicked cell, and
  mark the cell with `is_selected`.
- SQL pitfalls for these datasets (times as text, `INTEGER` inside lists of
  structs, `list_slice` instead of `[1:3]`): `references/sql-rules.md` §3.

## Content primitives

| Primitive | Props |
|---|---|
| `Markdown` | `content`, `span` — notes/help blocks |
| `NavButton` | `label`, `subtitle`, `showCount` (row count of the bound dataset), `onClick` |
| `Empty` | `message` |

(Registry primitives not listed here — `DocsInstallErrorBezel`, `XmlConvert*`,
`SemanticNamesStatus`, `XmlImportIntegrity` — are system-internal; do not use
them in custom bundles.)

## Click actions (whitelist)

Token substitution against the clicked row runs before dispatch. `args` may also
be given as `argsString: "k=v&k2=v2"` (values URL-decoded; useful when the SQL
emits ready-made arg strings).

| Action | Args | Effect |
|---|---|---|
| `openObject` | `uuid` (required), `type`, `file`, plus extra keys or nested `params` | Object detail view. **Always pass `file`** (duplicate-UUID disambiguation). Precision anchors: `params: { "step": "{{step_uuid}}" }` scrolls to a script step, `"sq": "{{term}}"` pre-fills the detail search, `"tab"`, `"ref"`, `"types"` (layout object-type filter, e.g. `"Container,Web Viewer"`) |
| `openFile` | `file` | File detail view `/file/<name>` |
| `openDashboard` | `id`, `params?` (nested or flat) | Another dashboard — or **the same dashboard as filter mechanism** (see below) |
| `applyFilter` | `q?`, `type?`, `file?`, `mode?`, `subtype?`, `label?`, `category?`, `sort?` | Home search view with pre-set filters |
| `navigate` | `path` (app-internal, leading `/`) | Generic SPA navigation |
| `openDocsEntry` | `set`, `category`, `fn`, `lang?` | Docs full-text view |
| `runQuery` | `query`, `params?` | Custom template via the `_generic` bundle |
| `openUrl` | `url` (`https://` external w/ confirmation, or `/api/…` same-tab) | External link |
| `copyToClipboard` | `value` | Copy |

### The self-navigation filter idiom

KPI tiles and aggregate-table rows filter the dashboard by navigating to
**itself** with a param:

```json
"onClick": { "action": "openDashboard",
             "args": { "id": "<this_dashboard_id>", "params": { "pattern": "todo" } } }
```

The URL param reaches every dataset as `getvariable('pattern')`. A "Total/All"
tile resets by sending the empty value `""`.

- `""` is written into the URL as `pattern=` — it is *not* removed. The SQL
  normalises it (`NULLIF(…, '')`), but a `FilterChips`/`Select` bound to the
  same param then sees `''` instead of its `default` and marks no chip as
  active. When a chip bar shows the same param, let the tile send the explicit
  value (`"view": "hotspots"`), not `""`.
- A click argument that is exactly one token (`"file": "{{file_filter}}"`)
  keeps the row's native value; when that value is `NULL` the argument is left
  out of the URL. Use this for optional pass-through filters in a drill-down —
  an empty string would arrive as `file=` instead.
- A dataset may need another default than the shared SQL block it carries
  (e.g. period "all" instead of "90"): set it per dataset in
  `manifest.datasets[].params` — URL params still win.

### Active state

A clickable KPI (or row) is highlighted as *active* when every key in
`args.params` (after token substitution) matches the current URL params. The
empty string `""` (and the literal `"Alle"`) count as reset values — they are
"active" when the param is absent. Only `args.params` participates; `uuid`,
`type` etc. are ignored. This is why filter params belong in nested `params`,
not flat args.

## Token substitution & formats

`{{field}}` → field value of the current row. Filters:
`{{ field | upper }}`, `{{ field | lower }}`, `{{ field | number:2 }}`,
`{{ field | date:relative }}`, `{{ field | date:iso }}`,
`{{ field | truncate:60 }}`, `{{ field | default:N/A }}`.

`format` values for KPI items / table columns:

| Format | Behaviour |
|---|---|
| `number` | locale-formatted number |
| `count` | like `number` but renders `0` as empty (pivot noise reduction) |
| `badge` | pill; canonical English values are auto-translated (`dashboard:cellValues`) |
| `filesize` | B / KB / MB / GB |
| `date:relative` | "5 days ago" (falls back to absolute beyond a week) |
| `date:iso` | ISO timestamp |
| `date` (any other `date:*`) | locale date string |

(There is **no** `boolean` or `date:short` format — emit canonical strings and
use `badge`, or format in SQL.)

## Manifest schema constraints (Joi — violations = bundle silently invisible)

- `id` matches `^[a-zA-Z0-9_-]+$` **and** equals the bundle directory's basename.
- `title` required, non-empty.
- `params[].type` ∈ `string | number | boolean` (never `integer`/`int`/`float`/`bool`).
- `params[].sticky` (boolean, default false): survives `openDashboard`
  self-navigation — for mode/lens params only, never for click-scoped filters
  (see §Filter primitives).
- `datasets[].source` matches `^(bundle|custom|report|builtin):.+$`.
- `datasets[].params` (optional object) = per-dataset default param values.
- Every `data.dataset` name used in `layout.json` must exist in
  `manifest.datasets[].id` — the loader does NOT catch this (empty card at runtime).
- `permissions`: `{ "read_only": true, "allow_navigation": true }`.
- `analysis.objectTypes` (optional array of `ObjectCatalog.Object_Type` values):
  the object types the rows point at. Required in practice whenever a dataset
  emits `AS nav_uuid` — the dashboard overview filters by object type from this
  declaration only (no run); a bundle without it appears only under
  *Without object type*. Bundles without object rows (statistics, change
  lists) omit it.

Dataset sources: `bundle:data/<name>.sql` (preferred, self-contained) ·
`custom:<template>` (a single-file dashboard — `dashboards-custom/` overrides
`dashboards/`, then `dashboards-community/` and the old location `sql-custom/` —,
else a module template of `queries/modules/`, else the `queries/` folder of a
dashboard bundle) ·
`report:<template>` (internal templates in `rest-api/templates/queries/system/`) ·
`builtin:<name>` (server builtins:
`list_dashboards` — bundles and single-file dashboards, with `unit` and
`object_types` per row —, `files`, `query_meta`, …).

Icons (`manifest.icon`, Lucide names): `database`, `code`, `layout-list`,
`git-fork`, `table-2`, `search`, `variable`, `function-square`, `tag`,
`alert-triangle`, `link`, `box`, `layers`, `filter`, `globe` — default `database`.
