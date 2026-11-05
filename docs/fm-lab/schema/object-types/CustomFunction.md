# CustomFunction

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **custom function** is a user-defined calculation function, managed in FileMaker's *Manage Custom Functions* dialog. It has a name, an ordered parameter list and a formula body, and is callable from any calculation of the file — field calculations, script-step expressions, other custom functions (including recursion) and validation calcs. An availability option controls whether all accounts or only full-access accounts may see and edit it; in the editing dialog custom functions can be organized into folders and separator lines.

CustomFunction is an **exported** type. In SaXML v2.2 (FileMaker 22) the export splits it in two branches: the *signature* (ID, name, availability, display form, parameters) in [XML CustomFunctionsCatalog](../../xml/catalogs/XML%20CustomFunctionsCatalog.md) and the *formula body* in [XML CalcsForCustomFunctions](../../xml/catalogs/XML%20CalcsForCustomFunctions.md); from SaXML v2.3.0.0 (FileMaker 26) the calculation is embedded directly in the function element and the separate calc branch disappears — the importer handles both forms. Each entry becomes a row in [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'CustomFunction'`; note that folder and separator entries of the function list are exported as regular `<CustomFunction>` elements and therefore also land as catalog rows (recognizable by their missing formula).

## Properties

### Signature (`<CustomFunction>` in the functions catalog)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `CF_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `CF_Name` | |
| `@access` | — | Availability option — **not extracted**; only `All` observed *(corpus)* |
| `@isFolder` | — | `True` = folder entry, `Marker` = separator line *(corpus)* — **not extracted**; folder/marker rows are only distinguishable by their empty formula |
| `<UUID>` (text) | `CF_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<Display>` | `CF_Display` | Display signature incl. parameter list, e.g. `GFN ( field )` |
| `<TagList>` | — | Tags — **not extracted** |
| `<ObjectList>/<Parameter @name>` | `Parameters` | Ordered parameter name list (`VARCHAR[]`) |

### Formula (`<CustomFunctionCalc>` in the calcs branch, SaXML v2.2)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `<CustomFunctionReference>` (`@id`, `@name`, `@UUID`) | `CF_ID` / `CF_Name` / `CF_UUID` | Re-identifies the function in [CalcsForCustomFunctions](../catalog-tables/CalcsForCustomFunctions.md) |
| `<Calculation>/<Text>` | `Calculation_Code` | Plain formula text (CDATA); NULL for folder/marker entries |
| `<Calculation>/<DDRREF>` (`@hash`) | `DDR_Hash` (both tables) | Joins the tokenized chunks in [DDR_Calculations](../catalog-tables/DDR_Calculations.md) |
| — (derived) | `Code_Chunks` | The same formula tokenized into typed chunks at the row level |

## References

All edges of a custom function are **calc-carried**: the formula body produces the outgoing links, and every calculation that calls the function produces an incoming `calls_customfunction`. Resolution requires DDR-Info (the chunk lists in [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md)); without it the catalog still lists the functions but the dependency edges stay coarse. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (CustomFunction as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `calls_function` | [BuiltinFunction](BuiltinFunction.md) | usage | The formula calls a built-in function |
| `calls_customfunction` | CustomFunction | usage | The formula calls another custom function (or itself — recursion) |
| `calls_pluginfunction` | [PluginFunction](PluginFunction.md) | usage | The formula calls an external plugin function |
| `reads_field` | [Field](Field.md) | usage | The formula reads a field |
| `reads_variable` | [Variable](Variable.md) | usage | The formula reads a global variable |
| `sets_variable` | [Variable](Variable.md) | usage | A `Let` assignment in the formula writes a variable |
| `has_calculation` | [Calculation](Calculation.md) | containment | The formula body as an addressable [Calculation](Calculation.md) instance (subrole `custom_function`) — never counts as usage |

### Incoming links (CustomFunction as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `calls_customfunction` | [Script](Script.md) / [Field](Field.md) / [LayoutObject](LayoutObject.md) / CustomFunction / [PrivilegeSet](PrivilegeSet.md) | usage | A calculation of the source calls this function |
| `validates_by_calc` | [Field](Field.md) | usage | A field-validation calculation calls this function |

PrivilegeSet-carried `calls_customfunction` links qualify their subrole as `<Operation>:<Table>` (the Custom-Record-Privilege rule containing the call); calc-carried links on other sources use the owner's calc-anchor slot as subrole (step index, `Tooltip`, `Install`, …).

## Enumerations

| Property | Values |
|---|---|
| `@access` | `All` *(corpus)* — the FileMaker UI also offers restricting a function to full-access accounts; that XML literal is not independently documented |
| `@isFolder` | absent (regular function), `True` (folder), `Marker` (separator line) *(corpus)* |

## Schema & tooling

- **XML schema:** [XML CustomFunctionsCatalog](../../xml/catalogs/XML%20CustomFunctionsCatalog.md) (signatures) · [XML CalcsForCustomFunctions](../../xml/catalogs/XML%20CalcsForCustomFunctions.md) (formulas, SaXML v2.2 only) — `Structure/AddAction` branch
- **DB schema:** [CustomFunctionsCatalog](../catalog-tables/CustomFunctionsCatalog.md) · [CalcsForCustomFunctions](../catalog-tables/CalcsForCustomFunctions.md) · formulas tokenized in [DDR_Calculations](../catalog-tables/DDR_Calculations.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_customfunction.sql` (+ `object_details_customfunction_tokens.sql` for the calculation token view), served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=CustomFunction`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [BuiltinFunction](BuiltinFunction.md) · [PluginFunction](PluginFunction.md) · [Field](Field.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
