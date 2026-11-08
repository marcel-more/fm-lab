# LinkRoleRegistry

Part of the [FM-Lab schema](../Schema.md) · Object catalog · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** curated registry (no XML source)

The classification registry for every link role that can appear in [ObjectLinks](ObjectLinks.md) (63 registered roles: 52 usage, 9 containment, 2 restriction). Each role is categorized by `Link_Kind` — `usage` (a functional dependency), `containment` (a structural owner relation) or `restriction` (an access limitation) — and carries the boolean `Counts_For_Where_Used` flag that where-used and dead-code analyses rely on.

## Columns

| Column | Type |
|---|---|
| `Link_Role` | `VARCHAR` |
| `Link_Kind` | `VARCHAR` |
| `Counts_For_Where_Used` | `BOOLEAN` |

## Notes

- Restriction roles (`restricts_field`, `restricts_object`) never count as usage: a privilege set limiting access to a layout does not make that layout "used".
- `has_calculation` (containment) never counts as usage either — the usage semantics of a calculation stay on its owner's edges (see [Calculation](../object-types/Calculation.md)).
- One **usage** role is registered with `Counts_For_Where_Used = FALSE`: `trigger_script`, the granular ScriptTrigger→Script navigation edge. Its counting truth is the owner mirror `triggers_script` — counting both would double every trigger (see [Link Roles and Subroles](Link%20Roles%20and%20Subroles.md)).
- The import pipeline warns when a link role appears in `ObjectLinks` without a registry entry.

**See also:** [ObjectLinks](ObjectLinks.md) · [Link Roles and Subroles](Link%20Roles%20and%20Subroles.md) (all roles with descriptions)
