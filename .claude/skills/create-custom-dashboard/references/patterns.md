# Dashboard patterns

Named, composable blueprints built from the primitives (see
`references/primitives.md`). Pick by **user intent**, not by data shape alone.
Real analyses usually combine two (P2 + P3 is the normal case).

## Build form (step 3, stage 0)

Every dashboard is built in one of two forms. Recommend the form together with
the pattern — the user decides in gate G2.

| Form | What it is | Delivers |
|---|---|---|
| **Single-file dashboard** | one `<id>.sql` with a `-- @` header (`references/single-file.md`) | title card + one table: sort, search, row click, optional second row action, optional chip bar and server paging, findings value; English only |
| **Bundle** | directory with `manifest.json`, `layout.json`, `data/*.sql`, `locales/` | any pattern P1–P6: several datasets, KPI tiles, filter chips/menus, drilldown, several panels, notes, 10 languages |

Signals (internal decision rule — first match wins):

| Signal in the request or the confirmed data | Form |
|---|---|
| several result lists, mixed object types in separate panels, counts per trait shown as tiles, grouping first and members second, explanatory text, translated labels | Bundle |
| a partition the user wants to click (I2) that is more than one column's values | Bundle (P2 tiles) |
| "list of all …", "which … have …", one query, one object type, a click opens the object | Single-file |
| the same plus value chips over **one** column | Single-file (`@chip_filter`) |
| a ranking or inventory meant as a test member | Single-file (`@default_result`) |

In doubt, recommend the single-file form: it is the smaller artefact and grows
into a bundle without rewriting the SQL (`references/single-file.md` §Moving
between the two forms). The interactivity duties hold in both forms — in the
single-file form I1 is the row click, I2 is the chip bar (one column only), I3
is built in (the table is always searchable and sortable).

## The three interactivity duties (apply to every pattern)

- **I1 — Object rows are always navigable.** Rows representing catalog objects
  get `onRowClick` / `rowTemplate.onClick` with `openObject` and args `uuid`,
  `type`, **`file`** (all three; `file` disambiguates duplicate UUIDs). When the
  query knows the find site, add precision params (`step`, `sq`). Rows that are
  pure aggregates without object identity instead become **drilldown filters**
  (P3) where meaningful.
- **I2 — Meaningful partitions become clickable filters.** If the result set has
  a useful partition (with/without a trait; trait A/B/C), surface it as KPI hero
  tiles or FilterChips that actually filter — never as dead numbers.
- **I3 — Search above 3 rows.** Every List/Table/TileGrid whose result typically
  exceeds 3 rows gets `"searchable": "auto", "searchAutoThreshold": 3` (+
  `searchPlaceholder`). Analysis tables also get `"sortable": true`. Exception:
  fixed Top-N rankings with N ≤ 5.

## Server-side vs client-side filtering — decision rule

| Need | Mechanism |
|---|---|
| Counts and filtering over the **full** data (beyond one page) | KPI hero tiles (`openDashboard` self-nav param) or `FilterChips` / `Select` / `Slider` → URL param → `getvariable` → SQL re-runs |
| Value chips over a column of a paged list | `Table.chipFilter` with `param` (server chip, counts from `_chip_facets`) |
| Quick visual partition of a small, unpaged list | `Table.chipFilter` without `param` (client-side chips) |
| Free-text narrowing | built-in search (I3); on a paged table via `searchParam` (server-side) |

When in doubt: server-side. A client-side chip on a paged table would count and
filter one page only — it is not allowed there.

⚠️ Params are click-scoped by default: an `openDashboard` self-navigation drops
every param the click args don't carry. Mode/lens params (classification set,
noise filter, …) → declare `"sticky": true` in `manifest.params`; click-scoped
filters → carry them in the click args (see primitives.md §Filter primitives).

---

## P1 — Navigator / worklist

**Intent signals:** "show me all X", cleanup list, inventory, "which scripts …".
**Datasets:** one detail dataset (uuid/name/file/type + a few info columns).
**Interactivity:** I1 + I3; KPI strip optional and purely informative.
**Reference:** the `scripts_without_comment` example below; most `health_hints` cards.

```json
{ "type": "Card", "id": "worklist", "props": { "span": 12 },
  "data": { "dataset": "items" },
  "children": [ { "type": "List", "id": "worklist_list", "props": {
      "rowTemplate": {
        "primary": "{{name}}", "secondary": "{{file}} · {{step_count}} steps",
        "onClick": { "action": "openObject",
                     "args": { "uuid": "{{uuid}}", "type": "Script", "file": "{{file}}" } } },
      "searchable": "auto", "searchAutoThreshold": 3,
      "empty": { "message": "No entries found." } } } ] }
```

## P2 — Segmented overview (KPI heroes as filters)

**Intent signals:** trait comparison, "with/without", categories, "how many …
and which".
**Datasets:** `summary` (one row: `total` + one count per subset, shared base CTE
with the detail SQL — see sql-rules.md §5) + `details` (reads the filter param).
**Interactivity:** I1 + I2 + I3. Every KPI tile filters; a "Total" tile resets
with the empty value. Active tile is highlighted automatically.
**Reference:** `script_todos` (pattern param), `external_apis` (summary strip).

```json
{ "type": "Card", "id": "summary", "props": { "span": 12, "variant": "hero" },
  "data": { "dataset": "summary" },
  "children": [ { "type": "KPIStrip", "id": "summary_kpistrip", "props": { "items": [
      { "label": "Total", "field": "total", "format": "number",
        "onClick": { "action": "openDashboard",
                     "args": { "id": "<id>", "params": { "<param>": "" } } } },
      { "label": "With trait", "field": "with_trait", "format": "number",
        "onClick": { "action": "openDashboard",
                     "args": { "id": "<id>", "params": { "<param>": "with" } } } },
      { "label": "Without trait", "field": "without_trait", "format": "number",
        "onClick": { "action": "openDashboard",
                     "args": { "id": "<id>", "params": { "<param>": "without" } } } }
  ] } } ] }
```

Detail SQL: the "Total" tile sends the **empty string**, so treat `''` like NULL:
`(NULLIF(CAST(getvariable('<param>') AS VARCHAR), '') IS NULL OR <subset predicate>)`
(idioms in sql-rules.md §3).

## P3 — Aggregate + drilldown

**Intent signals:** two levels — "per family / file / module / type … and the
hits underneath".
**Datasets:** aggregate dataset (one row per group, counts) + detail dataset
(filtered by the group param). Optionally a consolidated second roll-up.
**Interactivity:** aggregate rows use `onRowClick: openDashboard` (self) with the
group value as param — active row highlights like a KPI. A leading "All" row
(UNION in SQL, param value `""`) resets. Detail rows follow I1. Carry other
active filter params in the click args, or declare mode/lens params
`"sticky": true` in the manifest (see primitives.md §Filter primitives).
**Reference:** `modularization/external_apis` (api_families → url_details → url_hosts).

```json
"onRowClick": { "action": "openDashboard",
  "args": { "id": "<id>", "params": { "group": "{{group}}", "<other_param>": "{{<other_param>}}" } } }
```

## P4 — Lens analysis (classification switch / threshold)

**Intent signals:** "switch between classifications", noise filter
(comments/inactive code), numeric threshold ("only ≥ N").
**Building blocks on top of the main dataset:**
- 2–5 named lenses with true-total counts → `FilterChips` (+ tiny counts dataset)
- many/data-driven options → `Select` (options from a dataset)
- numeric threshold → `Slider` (`maxField` from a stats dataset)
**Reference:** `external_apis` (`api_set` Select, `comment` FilterChips).

```json
{ "type": "FilterChips", "id": "noise_filter", "props": {
    "param": "comment", "default": "exclude",
    "options": [
      { "value": "all",     "label": "All",              "countField": "count_total" },
      { "value": "exclude", "label": "Without comments", "countField": "count_without" },
      { "value": "only",    "label": "Only comments",    "countField": "count_comments" } ] },
  "data": { "dataset": "comment_counts" } }
```

## P5 — Multi-facet report

**Intent signals:** "health check", "audit", several independent checks on one page.
**Structure:** several cards, each with its own dataset, each internally following
P1 rules (navigable, searchable). A hero KPI strip may summarise the facets —
if a facet KPI can filter/jump to its card's data, wire it (I2); otherwise it may
stay informative.
**Reference:** `health_hints`.

## P6 — Static panel

**Intent signals:** explanatory text, methodology notes, a few standalone values.
**Building blocks:** `Markdown` (notes block, usually the last card — document
KPI semantics, filter behaviour, classification rules there), `KPIStrip` /
`DefinitionList` without clicks.
**Reference:** the closing Notes card in `external_apis`.

---

## Intent → pattern matrix (step 3, stage 1 — bundle form)

| The user wants … | Pattern |
|---|---|
| a list to work through / inventory | P1 |
| counts per trait **and** the matching objects | P2 |
| groups first, then members ("per X … which Y") | P2 or P3 (P3 when the group list itself is a result) |
| to toggle classifications / hide noise / thresholds | P4 on top of P1–P3 |
| many independent checks at once | P5 (each facet P1) |
| numbers/explanation only, no navigation | P6 (justify skipping I1) |

## Shape → primitive (step 3, stage 2)

| Result shape | Primitive |
|---|---|
| 1 row, 1–6 aggregate columns | `KPIStrip` (hero card) |
| 1 row, many label/value pairs | `DefinitionList` |
| rows with `uuid`+`name`, navigation focus | `List` |
| rows with 3–8 mixed columns, analysis focus | `Table` (sortable) |
| exploratory / unknown columns | `AutoTable` |
| navigation targets (dashboards) | `TileGrid` or `NavButton`s |
| free text | `Markdown` |

If List and Table both fit, offer both: List = compact navigation, Table = all
columns for analysis.

## Folder placement

Related dashboards can be grouped in a folder of the user area:
`dashboards-custom/<folder>/[<sub>/]<id>/` (bundle) or
`dashboards-custom/<folder>/[<sub>/]<id>.sql` (single file), up to four levels, plus an optional
`<folder>/folder.json` (`title`, `icon`, `description`, `order`, inline
`locales`) — see the shipped `dashboards/modularization/` and
`dashboards/static-code-analysis/`. Without a `folder.json` the label is the
humanized directory name. Single dashboards stay directly in `dashboards-custom/`.
Every folder becomes one breadcrumb level below **Custom**:
`Dashboards / Custom / <folder label> / <title>`.
