# Detail View Templates

**Directory:** `rest-api/templates/queries/modules/` (searched recursively) ·
**Config:** `QUERIES_DIR` (the `queries/` root) · **Served by:**
[/api/query](../rest-api/endpoints/Query%20and%20Report%20API.md)

Detail view templates — the *module templates* — are **internal** SQL loaded
by UI hooks and controllers: the structured data behind a detail panel, not
something a user browses. They are resolved by name through `/api/query`, but
unlike [Single-file Dashboards](Single-file%20Dashboards.md) they never appear in the dashboard overview
and cannot be overridden. Part of the [SQL Templates](SQL%20Templates.md) family.

## What lives here

The directory is scanned **recursively**; templates are grouped in subfolders
by the view they serve:

- `hierarchy/list_with_folders.sql` — a folder-aware object listing used
  across views.
- `layout-view/display_layout_objects_data.sql` — one JSON row per layout
  object with absolute coordinates, part assignment, nesting, colours and
  per-object conditional-formatting/trigger indicators (read from the
  owner-anchored catalog tables, not from XML flags); the web frontend draws
  the interactive wireframe from this.
- `layout-view/display_layout_parts_data.sql` — the layout's parts as bands.
- `layout-view/display_layout_triggers.sql` — script triggers attached to the
  layout, each with the trigger's catalog UUID for the jump to its detail view.
- `layout-view/display_layout_meta.sql` — layout-level metadata (view options, …).
- `object-detail/object_change_meta.sql` — the last change stamp shown in an
  object's detail header.

## How resolution works

`/api/query?template=<name>` (and the dashboard source `custom:<name>`)
resolves a name in this order:

1. a **single-file dashboard** of that name — `dashboards-custom/` first, then
   the shipped `dashboards/`, then `dashboards-community/`, then the old
   location `sql-custom/` (see [Single-file Dashboards](Single-file%20Dashboards.md));
2. a **module template** here;
3. a `queries/` folder inside a dashboard bundle, so a dashboard can ship its
   own drilldown templates self-contained (see [Dashboard Datasets](Dashboard%20Datasets.md)) — only
   when the name exists nowhere else.

The [system templates](Built-in%20Query%20Templates.md) are never reached this way —
they answer only `/api/report`. A UI hook simply calls:

```
/api/query?template=display_layout_objects_data&params={"layout_uuid":"…"}
```

and the controller renders the panel from the rows. Because single-file
dashboards are looked up first, a dashboard named like a module template would
hijack the UI hook — the server therefore ignores such a file and logs a
warning.

## When to add one here vs. a single-file dashboard

- **`queries/modules/`** — core only: the query backs a specific UI hook /
  detail panel of FM-Lab itself.
- **[A single-file dashboard](Single-file%20Dashboards.md)** in
  `dashboards-custom/` — every analysis of your own, whether you browse it in
  the overview or call it by name.

## See also

- [SQL Templates](SQL%20Templates.md) — overview, metadata header, parameters
- [Single-file Dashboards](Single-file%20Dashboards.md) — the user-facing sibling
- [Objects API](../rest-api/endpoints/Objects%20API.md) — the layout detail / SVG special case
- [REST API Output Formats](../rest-api/REST%20API%20Output%20Formats.md) — the structured-data-for-client-drawing note
