# Single-file dashboards

A **single-file dashboard** is one `.sql` file with a `-- @` header. The server
derives the manifest from the header and renders it with the generic layout:
a title card (`@title`, `@description`) above an `AutoTable` over the result
rows — sortable, searchable, optional chip bar, optional server paging, row
click and a second per-row action. Everything else works as for a bundle:
overview entry, folder, favorites star, findings value, object-type filter,
test membership, `/dashboard/<id>`.

Verified against `rest-api/src/services/template.service.js`
(`parseTemplateMetadata`) and `rest-api/src/services/dashboard.service.js`
(`deriveFileManifest`, `parseHeaderParams`). When a key is not listed here, it
has no effect.

## Placement and id

- File: `rest-api/templates/dashboards-custom/[<folder>/…]<id>.sql` — directly
  in the area or in a grouping folder (up to four levels, optional
  `folder.json` as for bundles, `references/patterns.md` §Folder placement).
  Never inside a bundle directory: `.sql` files under a `manifest.json` folder
  (`data/`, `queries/`) belong to that bundle.
- **id = file name without `.sql`**, pattern `[a-zA-Z0-9_-]+`; this skill uses
  lowercase `a-z0-9_`, max 30 characters. Bundles and single-file dashboards
  share **one** namespace.
- The id must not equal an internal template (`rest-api/templates/queries/system/**`
  or `queries/modules/**`): such a file is discarded with a log warning,
  because `/api/query` resolves single-file dashboards before the module
  templates and would otherwise hijack a UI template.
- The id of a shipped dashboard (bundle or file) **overrides** it — only on
  the user's explicit request.

## Header keys

One key per line, `-- @<key>: <value>`, at the top of the file. Lists are
comma-separated. A blank `--` line ends the header visually; comments below it
are free text.

### Required

| Key | Value | Effect |
|---|---|---|
| `@template_type` | `report` | result rows without column requirements (`object` demands `uuid`/`name`/`type`, `content` a `content` column — not for dashboards) |
| `@title` | English, ≤ 50 characters | manifest title, overview tile, breadcrumb, title card (missing → humanized id + log warning) |
| `@description` | English, one or two sentences | tile tooltip, overview search, title card |

### Recommended

| Key | Value | Effect |
|---|---|---|
| `@object_types` | `ObjectCatalog.Object_Type` values (`Script`, `Layout`, …) | `analysis.objectTypes` — the overview's object-type filter and the test gate M3 read only this |
| `@default_result` | one-line JSON, see below | findings value in the overview (with `meaning` as tooltip), result registry, test membership (M2) |
| `@click_action` / `@click_args` | action from the whitelist (`references/primitives.md` §Click actions), args as `k=v&k2=v2` with `{{column}}` tokens | row click — I1: `openObject` with `uuid`, `type` and `file` |
| `@params` | `name (optional\|required, default <value>, <description>)`, comma-separated; `none` = no params | manifest params; `query` and `file` are added automatically |
| `@output_format` | the output columns in order | documentation only — the table derives its columns from the result |
| `@icon` | short icon name as in the shipped files (`script`, `layout`, `table`, `field`, `variable`, `bug`, …) | tile icon (default `query`) |
| `@tags` | lowercase keywords | overview search |
| `@author`, `@version` | free text, `1.0` | manifest `author`, `version` (default `1.0.0`) |

### Optional

| Key | Value | Effect |
|---|---|---|
| `@scope` | `solution, file, object, object-list, cluster` | `analysis.scope.supported` (default `solution, file`); object-like scopes need the S-Block (`references/sql-rules.md` §3) |
| `@output_types` | `count`, `boolean`, `findings-table`, `inventory-table`, `graph`, `text` | `analysis.outputTypes` — test gate M4 |
| `@row_action` / `@row_action_args` / `@row_action_label` | second click target, same grammar as `@click_*`; English label | arrow button at the end of each row (e.g. "Show in layout") |
| `@chip_filter` | one result column | chip bar above the table |
| `@chip_param` | URL param the chip writes | server chip: the SQL filters on `getvariable('<param>')` and returns `_chip_facets` |
| `@page_param`, `@search_param`, `@sort_param` | `page`, `q`, `sort` | server paging, search and sort (frame below) |
| `@sort_columns` | output columns | restricts the sortable columns |
| `@page_size` | `1…10000` or `all` | rows per page (default 500) |
| `@display` | `table` | informational |

**Never** write `@category`: it no longer places the file — the folder does.
Unknown keys (`@note`, …) are ignored.

### `@default_result`

```
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "scripts_without_comment", "meaning": "Scripts without a comment step in scope (worklist — not a defect count)" }
```

| Field | Values | Note |
|---|---|---|
| `aggregate` | `row_count` (default) or `first_row:<column>` | `row_count` = rows the query returns; `first_row:<column>` = that column of the first row (for an aggregate query) |
| `type` | `number`, `boolean`, `text` | required |
| `name` | short snake_case name | required |
| `meaning` | one sentence; say whether it is a defect count or an inventory | tooltip of the findings value |
| `unit` | e.g. `findings`, `scripts` | optional consolidation hint; values are only ever summed within one unit |

Invalid JSON or an invalid field drops the declaration with a log warning — the
dashboard stays visible but has no findings value and cannot be a test member.
The JSON values contain no `:` directly followed by a letter or digit except
in `first_row:<column>`, which is harmless here (the header is parsed from the
raw file; see the write-gate below).

With the paging frame, `row_count` counts the rows of the returned page — at
most `@page_size`. When the result can outgrow one page, choose a page size
above the expected total or say so in `meaning`.

Without a scope-capable SQL (no S-Block), declare only `solution, file` — a
test run in object scope then skips this member instead of reporting the whole
solution.

### `@params`

```
-- @params: file (optional), pattern (optional, default all, one of all|with|without), limit (optional, default 100)
```

Commas inside the parentheses are safe. Every `getvariable('<name>')` the SQL
reads belongs here. All header params are strings; the SQL normalises the
value shapes (`references/sql-rules.md` §3).

## SQL body

- The rules of `references/sql-rules.md` apply unchanged: identity pair
  (UUID, File_Name), qualified columns in joins, `getvariable` params, no
  `:word`, `Step_ID` instead of step names, the scope block for analysis rows.
- **Object rows** return `uuid` (or `_nav_uuid`), `name`, `file`/`file_name`
  and — when the types mix — `type`; the click args reference exactly these
  columns. Columns starting with `_` stay hidden in the table but are
  available as tokens (`{{_nav_uuid}}`, `{{_step_uuid}}`).
- **Test members** additionally return a `_message` column (one readable
  sentence per row) — the tests panel shows it per finding (warning M5c when
  it is missing).
- **Lists that can outgrow one page** use the paging frame of
  `references/sql-rules.md` §3 and declare it in the header:

  ```
  -- @page_param: page
  -- @search_param: q
  -- @sort_param: sort
  -- @page_size: 500
  -- @params: file (optional), page (optional), page_size (optional, default 500), q (optional), sort (optional), dir (optional)
  ```

  The SQL returns `_row_total`, `_page`, `_page_size` on every row and ends in
  `ORDER BY /*@sort*/ … LIMIT … OFFSET …`. Copy the blocks verbatim from
  `rest-api/templates/dashboards/layouts/tooltip_inventory.sql`.
- **Server chip:** `@chip_filter: <col>` + `@chip_param: <col>` + the param in
  `@params`; the chip predicate sits in the `filtered` CTE and `_chip_facets`
  counts over `result` (same file as reference).
- **Top-N rankings** without paging end in a parameterised `LIMIT`
  (`rest-api/templates/dashboards/top/top_scripts.sql`).

## Example header (shipped file)

`rest-api/templates/dashboards/scripts/error_code_inventory.sql`:

```sql
-- @template_type: report
-- @title: Error-code inventory
-- @description: Every numeric literal a script compares with Get(LastError), …
-- @icon: bug
-- @display: table
-- @chip_filter: code
-- @chip_param: code
-- @page_param: page
-- @search_param: q
-- @sort_param: sort
-- @page_size: 2000
-- @params: file (optional), page (optional), page_size (optional, default 2000), q (optional), sort (optional), dir (optional), code (optional)
-- @click_action: openObject
-- @click_args: uuid={{_nav_uuid}}&type=Script&step={{_step_uuid}}&file={{file_name}}
-- @row_action: openObject
-- @row_action_args: uuid={{_nav_uuid}}&type=Script&step={{_step_uuid}}&file={{file_name}}
-- @row_action_label: Show step
-- @output_format: file_name, script_name, step_no, code, code_text, scope, meaning, status, _message, _chip_facets, _row_total, _page, _page_size
-- @object_types: Script
-- @output_types: count, inventory-table
-- @scope: solution, file, object, object-list, cluster
-- @default_result: { "aggregate": "row_count", "type": "number", "name": "error_code_comparisons", "meaning": "Comparisons of Get(LastError) with a numeric literal in scope (inventory - not a defect count)" }
-- @author: fm-lab core
-- @version: 1.0
-- @tags: scripts, errors, error-codes, inventory
--
-- Free-text notes on the method follow here.
```

## Moving between the two forms

Neither direction needs a rewrite of the SQL:

- **File → bundle.** Create `dashboards-custom/[<folder>/]<id>/` with
  `manifest.json`, `layout.json`, `locales/`, and either move the file to
  `data/<id>.sql` (dataset `bundle:data/<id>.sql`) or keep it under a new id
  and reference it as `custom:<that id>`. Header params become
  `manifest.params`; `@object_types`/`@default_result` become the
  `analysis` block (`defaultResult.dataset` = the dataset id, `column` instead
  of `aggregate` when a summary dataset delivers the value). Remove the file
  under the bundle's id — the bundle and the file would collide.
- **Bundle → file.** A bundle with exactly one dataset and a plain table
  becomes `<id>.sql`: dataset SQL plus a header built from the manifest
  (`title`, `description`, `params`, `analysis`) and the table's click
  action. Locales are lost — a single-file dashboard is English only.
