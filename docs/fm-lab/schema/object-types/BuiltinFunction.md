# BuiltinFunction

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **built-in function** is a function of the FileMaker calculation language itself — `Case`, `Substitute`, `Get ( LayoutName )`, … FileMaker's export has no catalog of built-in functions; they only appear as tokens inside calculation texts. BuiltinFunction is therefore a **synthetic** type: the import pipeline derives one object per distinct function found in the DDR calculation chunks (`FunctionRef` chunks in [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md)) and in the layout symbol inventory, which is what makes questions like *"where is `ExecuteSQL` used?"* answerable as a plain graph walk over [ObjectLinks](../object-catalog/ObjectLinks.md).

Built-in functions are solution-independent: their catalog rows carry `File_Name = NULL` and a deterministic `Object_UUID`, so the same function is one shared node across all files of the catalog.

**One node per function, whatever language the formula was written in.** The object name is the **canonical English name of the standard reference** — `Length`, `Get(PageNumber)` — not the token as it happens to be spelled in the formula. That matters because FileMaker's export offers no other handle: a calculation chunk carries just a name, in the UI language of the client that wrote the formula, with no function ID and no language marker. Before the normalization (catalog schema 1.32.0) the node name *was* that raw token, with two consequences that a German solution shows plainly: a localized spelling became its own node, and FileMaker additionally files the `Get` sub-parameter as a chunk of its own, so a single `Get ( PageNumber )` fell apart into up to three objects — `Get(PageNumber)`, `Get(Seitennummer)` and a bare `Seitennummer`. *"Where is `Get ( PageNumber )` used?"* then had three different answers. Today all three spellings resolve onto the one node `Get(PageNumber)`, and a layout symbol `{{Seitennummer}}` lands there too.

The resolution is recorded per node in [BuiltinFunctionIdentity](../catalog-tables/BuiltinFunctionIdentity.md) (reference function ID, canonical name, namespace) — consumers **look the identity up** rather than deriving it from the name. A token the reference does not know keeps the old name-based identity and gets no identity row: the `Get` wrapper of a dynamic `Get ( $var )`, the keyword and constant tokens (`True`, `False`, `and`, `or`, `not`, `Bold`), the JSON type constants (`JSONString`, `JSONNumber`, …), and functions newer than the bundled reference. The [fm-spec](../../Wiki/fm-spec.md) language layer ([function_name_lookup](../fm-spec-tables/function_name_lookup.md)) is still what renders a **localized display name** on request — but that is presentation, not identity.

Because derivation runs over DDR chunks, calculation-based usage is only populated for files exported with DDR-Info; layout symbols are independent of that option.

## Properties

A synthetic type has no XML property surface of its own — its properties are derived at import:

| Property | Derivation | Notes |
|---|---|---|
| `Object_Name` | Canonical English name of the reference, resolved from the calc chunk token or the layout symbol | `Get(<Parameter>)` form for Get parameters; independent of the export locale. Fallback for a token the reference does not know: the literal token |
| `Object_UUID` | Deterministic hash over the canonical name (`'BuiltinFunction::' + name`, Get parameters namespaced as `'BuiltinFunction::Get::' + parameter`) | Stable across imports. Because only the *input* was canonicalized, every node whose token was already canonical English keeps the UUID it had before schema 1.32.0 |
| `File_Name` | always `NULL` | Built-ins are solution-independent, shared across files |
| `Object_ID` | always `NULL` | No FileMaker-internal ID exists |
| `Source_Table` | `'DDR_Calculations'`, or `'LayoutObjectSymbols'` for a node first seen as a layout symbol | Provenance marker in [ObjectCatalog](../object-catalog/ObjectCatalog.md) |

There is no type-specific detail table; everything about a built-in function beyond its usages lives in the [fm-spec](../../Wiki/fm-spec.md) reference ([functions](../fm-spec-tables/functions.md) — 367 functions with stable IDs, categories, parameters, localized names and documentation links).

## References

A built-in function is a pure *target*: it has no outgoing edges. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (BuiltinFunction as source)

*None.*

### Incoming links (BuiltinFunction as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `calls_function` | [Script](Script.md) / [Field](Field.md) / [LayoutObject](LayoutObject.md) / [CustomFunction](CustomFunction.md) / [CustomMenuItem](CustomMenuItem.md) / … | usage | A calculation of the source calls the function |
| `displays_symbol` | [LayoutObject](LayoutObject.md) | usage | A `{{Symbol}}` in a text object — per Claris the value of `Get ( Symbol )` at display time, so a genuine usage of that `Get` parameter |

The `calls_function` subrole names the owner's calc-anchor slot that contains the call (step index, `Tooltip`, `Hide`, `Install`, …) — see the subrole table in [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md). Both roles meet on the same node, which is the point: a `Get` parameter's references view answers *who shows this* and *who computes with it* in one place.

One counting note: the `calls_function` edge count per function dropped when the identity was normalized, without a single call site being lost. A `Get ( PageNumber )` call previously produced two edges at two different nodes — one from the `Get` pair, one from the bare sub-parameter chunk — and both were counted.

## Schema & tooling

- **XML schema:** no catalog of its own — derived from the `FunctionRef` chunks in [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md) (requires the "Include details for analysis tools" export option)
- **DB schema:** rows in [ObjectCatalog](../object-catalog/ObjectCatalog.md) plus the identity row in [BuiltinFunctionIdentity](../catalog-tables/BuiltinFunctionIdentity.md); usages resolve via [ObjectLinks](../object-catalog/ObjectLinks.md), the chunk table [DDR_Calculations](../catalog-tables/DDR_Calculations.md) and the symbol inventory [LayoutObjectSymbols](../catalog-tables/LayoutObjectSymbols.md) · language vocabulary in the fm-spec tables [functions](../fm-spec-tables/functions.md) and [function_name_lookup](../fm-spec-tables/function_name_lookup.md) (see [Schema](../Schema.md) §3, [fm-spec](../../Wiki/fm-spec.md))
- **Detail view template:** `rest-api/templates/sql/object_details_builtinfunction.sql` — a structured projection with two sections: `meta` (catalog name, localized spelling of `?lang=`, reference `function_id`) and `usage` (where-used counts per link role and source type). It carries no caller list; the references view owns that. Served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=BuiltinFunction`; the detail tab renders its own view (identity, the reference metadata from [fm-spec](../../Wiki/fm-spec.md) — category, return type, origin version — links to the Claris help page and the fm-spec entry, and the usage summary)

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [BuiltinFunctionIdentity](../catalog-tables/BuiltinFunctionIdentity.md) · [CustomFunction](CustomFunction.md) · [PluginFunction](PluginFunction.md) · [DDR_Calculations](../catalog-tables/DDR_Calculations.md) · [fm-spec](../../Wiki/fm-spec.md)
