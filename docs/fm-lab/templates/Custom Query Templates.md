# Custom Query Templates

> **Moved.** Custom queries are dashboards now: a `.sql` file with a `-- @`
> header in a dashboard folder is a **single-file dashboard**. The full
> description lives on [Single-file Dashboards](Single-file%20Dashboards.md).

What changed for custom queries:

| Before | Now |
|---|---|
| `rest-api/templates/sql-custom/<name>.sql` | `rest-api/templates/dashboards-custom/[<folder>/]<name>.sql` |
| *Custom Queries* page `/query`, `/query/<name>` | dashboard overview `/dashboard`, `/dashboard/<name>` (old links are redirected for one release) |
| grouping by `@category` | grouping by folder |
| config `TEMPLATE_CUSTOM_DIR` | `DASHBOARDS_CUSTOM_DIR` |
| test member `kind: query` | `kind: dashboard` (`query` is still read) |

Unchanged: the header keys, `/api/query?template=<name>`, the dataset source
`custom:<name>`, the output formats and the names of the shipped queries.

Files still in `sql-custom/` keep working for one release and show the badge
*old location*; the cleanup box on `/dashboard` moves them.

## See also

- [Single-file Dashboards](Single-file%20Dashboards.md)
- [Built-in Query Templates](Built-in%20Query%20Templates.md) · [Detail View Templates](Detail%20View%20Templates.md) — the internal templates
