# Built-in Query Templates

**Directory:** `rest-api/templates/queries/system/` · **Config:** `QUERIES_DIR` (the
`queries/` root) · **Served by:** [/api/report](../rest-api/endpoints/Query%20and%20Report%20API.md) and the
`report:<name>` dataset source

The built-in query templates are the internal backbone shipped with every
FM-Lab installation. They power the object detail views, the counts on the home
dashboard, the graph explorer and the reference lookups. The server and the
web frontend call them by name; they are not listed anywhere and cannot be
overridden. Part of the [SQL Templates](SQL%20Templates.md) family.

## What lives here

The templates are grouped by the part of the system that calls them:

- **`object-details/`** — `object_details_*`, one template per object type
  (`object_details_field`, `object_details_script`, `object_details_layout`,
  `object_details_relationship`, `object_details_customfunction`,
  `object_details_calculation`, …). These feed the [Objects API](../rest-api/endpoints/Objects%20API.md) detail
  view. The templates describe **attributes and structure**; the edges come
  canonically from `/api/references` and are not duplicated in the detail
  blocks. The `Layout` variant is special — it generates an SVG wireframe. Not
  every detail type is a template: the `ScriptTrigger` detail view is a
  controller projection built directly from the catalog tables, so there is no
  `object_details_scripttrigger.sql`.
  The same folder holds the **`*_tokens`** variants (e.g.
  `object_details_calculation_tokens`) used by the editor-style `tokens` output
  format (scripts, steps, fields, custom functions, menus, layout objects and
  calculation instances). Calculation instances are addressed by their
  `Calculation_UUID` from the `CalculationsCatalog`; the calculation hash
  remains only as a legacy alias — a hash is not unique per instance.
- **`references/`** — `back_references` and the per-line reference views
  (`object_references_script`, `object_references_layoutobject_step`).
- **`graph/`** — the graph/topology queries behind the [Graph API](../rest-api/endpoints/Graph%20API.md) and the
  graph explorer (`graph_overview_*`, `graph_subgraph`, `graph_depth_profile`,
  `graph_search`, `graph_trace`, …).
- **`relationship-graph/`** — tables, occurrences and relationships of the
  relationship graph view.
- **`object_count_by_type.sql`** — the per-type object counts.

## How they are called

By name through `/api/report`:

```bash
curl "http://localhost:3003/api/report?template=object_count_by_type"
```

`/api/query` does **not** reach these templates — it resolves dashboards and
the [module templates](Detail%20View%20Templates.md) only. A dashboard dataset uses
them with the source `report:<name>`.

Parameters use the DuckDB variable style, so a template stays "all rows" when a
filter is omitted:

```sql
WHERE getvariable('file_name') IS NULL
   OR File_Name = getvariable('file_name')
```

## Conventions

- **Ship as-is.** These are core templates — read-only and not overridable.
  Your own analyses are [Single-file Dashboards](Single-file%20Dashboards.md) in
  `rest-api/templates/dashboards-custom/`; a single-file dashboard that has the
  name of an internal template is ignored with a warning in the log.
- **Locale-independent identity.** Templates key on stable IDs (`Step_ID`,
  `Object_Type`), never on localised `Step_Name` literals, so they behave the
  same regardless of the solution's UI language.
- **Resolved edges, not raw XML.** Dependency questions read `ObjectLinks`; the
  `*_XML` columns are a last resort only.
- The inventory `rest-api/templates/queries/inventory.json` lists every
  internal template (system and modules); the publish gate checks it.

## See also

- [SQL Templates](SQL%20Templates.md) — the overview and the shared metadata/parameter rules
- [Detail View Templates](Detail%20View%20Templates.md) — the internal templates of `/api/query`
- [Single-file Dashboards](Single-file%20Dashboards.md) — your own named analyses
- [Query and Report API](../rest-api/endpoints/Query%20and%20Report%20API.md) · [Objects API](../rest-api/endpoints/Objects%20API.md) · [Graph API](../rest-api/endpoints/Graph%20API.md)
