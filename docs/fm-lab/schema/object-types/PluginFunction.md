# PluginFunction

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **plugin function** is a calculation function provided by an external FileMaker plugin — most prominently the MBS Plugin, whose thousands of functions are all called through the dispatcher `MBS ( "Component.Function" ; … )`. Like built-in functions, plugin functions have no catalog in the FileMaker export; they only appear as tokens inside calculation texts. PluginFunction is therefore a **synthetic** type: the import pipeline scans the DDR calculation chunks ([XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md)), registers every call in [PluginFunctionUsages](../catalog-tables/PluginFunctionUsages.md) and derives one catalog object per distinct plugin function, making plugin dependencies first-class citizens of the [ObjectLinks](../object-catalog/ObjectLinks.md) graph.

Names are **qualified**: MBS functions are registered as `MBS:<Component.Function>` — the sub-function name is recovered from the first string argument of the `MBS(…)` dispatcher call (an internal sub-name map resolves it per call site). Dynamic MBS calls whose sub-name is a computed expression cannot be resolved to a concrete function and are filtered out of the object derivation. Non-container plugins (functions registered directly in the calculation namespace) produce one entry per calc token under their plain name. Like built-ins, plugin functions are solution-independent (`File_Name = NULL`, deterministic UUID), and derivation requires DDR-Info.

## Properties

A synthetic type has no XML property surface of its own — its properties are derived at import:

| Property | Derivation | Notes |
|---|---|---|
| `Object_Name` | Qualified function name, e.g. `MBS:<Component.Function>` | Sub-name recovered from the dispatcher's first argument; non-container plugins keep their plain token name |
| `Object_UUID` | Deterministic hash of plugin function name + sub-name | Stable across imports |
| `File_Name` | always `NULL` | Plugin functions are solution-independent, shared across files |
| `Object_ID` | always `NULL` | No FileMaker-internal ID exists |
| `Source_Table` | `'PluginFunctionUsages'` | Provenance marker in [ObjectCatalog](../object-catalog/ObjectCatalog.md) |

The per-call detail (owning object, calc hash, chunk position) lives in [PluginFunctionUsages](../catalog-tables/PluginFunctionUsages.md), one row per usage.

## Object hierarchy

Plugin functions aggregate into their **component**: every MBS function carries a structural `groups_into` link to a [PluginComponent](PluginComponent.md) object (`MBS::<Component>`, e.g. `MBS::XL`). The component is resolved from the sub-name — a curated component mapping list shipped with FM-Lab decides ambiguous cases, and the first dot-segment of the sub-name (`XL.Book.AddFormat` → `XL`) serves as the default heuristic. The component layer gives module-level views (graph clustering, dashboards) a usable granularity above the individual function.

## References

Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (PluginFunction as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `groups_into` | [PluginComponent](PluginComponent.md) | containment | The function belongs to this plugin component |

### Incoming links (PluginFunction as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `calls_pluginfunction` | [Script](Script.md) / [Field](Field.md) / [LayoutObject](LayoutObject.md) / [CustomFunction](CustomFunction.md) / [PrivilegeSet](PrivilegeSet.md) | usage | A calculation of the source calls the plugin function |

Calc-carried links qualify their subrole with the owner's calc-anchor slot (step index, `Tooltip`, `Install`, …); PrivilegeSet-carried calls use the `<Operation>:<Table>` pattern of the Custom-Record-Privilege rule.

## Schema & tooling

- **XML schema:** no catalog of its own — derived from plugin-call tokens in the [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md) calculation chunks (requires the "Include details for analysis tools" export option)
- **DB schema:** [PluginFunctionUsages](../catalog-tables/PluginFunctionUsages.md) (one row per call) · object rows in [ObjectCatalog](../object-catalog/ObjectCatalog.md) · chunks in [DDR_Calculations](../catalog-tables/DDR_Calculations.md)
- **Detail view template:** `rest-api/templates/sql/object_details_pluginfunction.sql` — a structured projection with two sections: `meta` (catalog name, plug-in namespace, sub-function, the [PluginComponent](PluginComponent.md) it groups into) and `usage` (where-used counts per link role and source type). It carries no caller list; the references view owns that. Served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=PluginFunction`; the detail tab renders its own view (identity, the reference metadata from [plugin-spec](../plugin-spec.md) — plug-in, version, deprecation status — a link to the vendor doc-set page with the vendor's online page as fallback, and the usage summary). The platform matrix stays in the badge above the tab bar

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [PluginComponent](PluginComponent.md) · [BuiltinFunction](BuiltinFunction.md) · [CustomFunction](CustomFunction.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
