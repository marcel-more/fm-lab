# PluginComponent

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **plugin component** is a functional area of an external plugin — for the MBS Plugin these are the component prefixes of its function names (`XL`, `DynaPDF`, `CURL`, …). FileMaker knows nothing of this grouping; PluginComponent is a **synthetic** aggregate the import pipeline derives so that plugin usage can be analyzed at module granularity instead of thousands of individual functions. One object exists per component that has at least one function call in the solution, named `MBS::<Component>` (e.g. `MBS::XL`).

Components are derived from the same source as [PluginFunction](PluginFunction.md) objects — the plugin calls registered in [PluginFunctionUsages](../catalog-tables/PluginFunctionUsages.md) (which in turn come from the DDR calculation chunks). Component membership is resolved from the qualified function sub-name: a curated component mapping list shipped with FM-Lab decides the exceptions, and the first dot-segment of the sub-name (`XL.Book.AddFormat` → `XL`) is the default heuristic. Like all plugin objects, components are solution-independent (`File_Name = NULL`) with a deterministic UUID, and only exist for files exported with DDR-Info.

## Properties

A synthetic type has no XML property surface of its own — its properties are derived at import:

| Property | Derivation | Notes |
|---|---|---|
| `Object_Name` | `MBS::<Component>` | Component from the curated mapping list, else the first dot-segment of the function sub-name |
| `Object_UUID` | Deterministic hash of the component name | Stable across imports |
| `File_Name` | always `NULL` | Components are solution-independent, shared across files |
| `Object_ID` | always `NULL` | No FileMaker-internal ID exists |
| `Source_Table` | `'PluginFunctionUsages'` | Provenance marker in [ObjectCatalog](../object-catalog/ObjectCatalog.md) |

## Object hierarchy

The component is the parent of its functions: every [PluginFunction](PluginFunction.md) carries a structural `groups_into` link to exactly one component. The hierarchy is two levels deep by design (component → function); *usage* always attaches to the function level — a component is never called directly, it only aggregates. The component detail view therefore rolls up the callers of all member functions.

## References

Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (PluginComponent as source)

*None.*

### Incoming links (PluginComponent as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `groups_into` | [PluginFunction](PluginFunction.md) | containment | The plugin function belongs to this component |

Containment links never count as usage: whether a component is "used" is answered by the `calls_pluginfunction` edges of its member functions, not by `groups_into`.

## Schema & tooling

- **XML schema:** no catalog of its own — derived from plugin-call tokens in the [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md) calculation chunks (requires the "Include details for analysis tools" export option)
- **DB schema:** object rows in [ObjectCatalog](../object-catalog/ObjectCatalog.md); membership via [ObjectLinks](../object-catalog/ObjectLinks.md) (`groups_into`); call-level detail in [PluginFunctionUsages](../catalog-tables/PluginFunctionUsages.md)
- **Detail view template:** `rest-api/templates/sql/object_details_plugincomponent.sql` — a structured projection with three sections: `meta` (catalog name, plug-in namespace, how many member functions exist and how many are used, deduplicated where-used totals), `function` (one row per member function with its own counts) and `usage` (where-used per link role and source type, aggregated over all member functions). The two-level caller list is gone; each function's own references view holds the call sites. Served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=PluginComponent`; the detail tab renders its own view (identity, the component size per [plugin-spec](../plugin-spec.md), a link to the vendor doc-set category page with the vendor's online page as fallback, the member functions and the aggregated usage summary)

One counting note: the aggregated totals deduplicate across member functions — a script calling three functions of the same component is **one** using object, not three. The per-function rows keep the individual counts.

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [PluginFunction](PluginFunction.md) · [BuiltinFunction](BuiltinFunction.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
