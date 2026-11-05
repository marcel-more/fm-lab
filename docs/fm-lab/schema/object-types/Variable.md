# Variable

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **variable** is a named runtime value of the FileMaker calculation engine. The prefix defines the scope: `$name` is **local** to the running script, `$$name` is **global** to the file for the session, and `$$$name` is the cross-file *superglobal* convention provided by the MBS Plugin (not a native FileMaker scope). `Let`-bound names inside a single calculation form a fourth, narrowest scope. Variables are created by assignment — there is no declaration and no catalog inside FileMaker.

Variable is therefore a **synthetic** type: the import pipeline derives every variable from its observable usages — Set Variable steps, DDR calculation chunks, merge variables on layouts and MBS plugin calls — and registers one [ObjectCatalog](../object-catalog/ObjectCatalog.md) entry per distinct variable *per scope anchor*. The `Object_UUID` is computed as `md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name)`: the anchor is the script for local variables, the file for global variables and a shared `__global` anchor for superglobals, so two scripts using their own `$i` stay two objects while every reader of `$$config` meets at one.

## Properties

There is no `<Variable>` element in the export — the property surface is entirely **derived**. The aggregation per variable lands in [VariablesCatalog](../catalog-tables/VariablesCatalog.md); every individual set/read with its context lands in [VariableUsages](../catalog-tables/VariableUsages.md).

| Property (derived) | In catalog | Notes |
|---|---|---|
| name (as written, `$`/`$$` included) | `Variable_Name`, `Display_Name`, `Normalized_Name` | Normalization enables matching across notation variants |
| scope | `Variable_Scope` | See [Enumerations](#enumerations) |
| scope anchor | `Scope_Anchor` (+ `Script_UUID` for local scope) | Script / file / `__global` — part of the identity |
| write / read statistics | `Set_Count`, `Read_Count` | Aggregated over all usages |
| spread | `Script_Count`, `File_Count`, `Files` | How widely the variable travels |
| first appearance | `First_Seen_Context` | |
| name hygiene | `Has_Spaces` | Variable names with spaces — a common refactoring target |
| extraction evidence | `Source_Reliability` | How the variable was detected, see [Enumerations](#enumerations) |
| per-usage context | `VariableUsages.Usage_Type`, `Context_Type`, `Step_Index`, `Calc_Hash`, … | One row per set/read, joinable to steps and [DDR_Calculations](../catalog-tables/DDR_Calculations.md) chunks |

Since the type is synthetic, there are no "not extracted" XML properties — everything FileMaker knows about a variable at runtime (its value) is by nature absent from a structure export.

## References

Variables are pure link *targets*: they never reference anything themselves. The three incoming roles distinguish write, read and display. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (Variable as source)

None — no link role has Variable as its source.

### Incoming links (Variable as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `sets_variable` | [Script](Script.md) / [CustomFunction](CustomFunction.md) | usage | Set Variable step / Let assignment writes the variable |
| `reads_variable` | [Script](Script.md) / [Field](Field.md) / [CustomFunction](CustomFunction.md) / [LayoutObject](LayoutObject.md) / [PrivilegeSet](PrivilegeSet.md) | usage | A step or calculation reads the variable |
| `displays_variable` | [LayoutObject](LayoutObject.md) | usage | A merge variable (`<<$$name>>`) is displayed on a layout |

Script-carried edges qualify the position with the step index as `Link_Subrole`; layout-object and privilege-set carriers use the calc-slot subrole patterns described in [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md). A variable with `sets_variable` edges but no `reads_variable`/`displays_variable` edge is a classic write-only leftover.

## Enumerations

| Property | Values |
|---|---|
| `Variable_Scope` | `local` (`$`), `global` (`$$`), `superglobal` (`$$$`, MBS Plugin convention), `let_local` (Let-bound) |
| `VariableUsages.Usage_Type` | `set`, `read` |
| `VariableUsages.Context_Type` | `script_step`, `calculation`, `auto_enter_calc`, `custom_function`, `layout_object`, `record_access_calc` |
| `Source_Reliability` / `Source` | `ddr` (`ddr_chunk`), `mbs` (`mbs_variable_call`), `merge` (`merge_variable`), `regex` (`regex_fallback`), plus `set_variable_step` as usage source |

## Schema & tooling

- **XML schema:** no catalog of its own — derived from [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md) chunks, [XML StepsForScripts](../../xml/catalogs/XML%20StepsForScripts.md) Set Variable steps and [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md) merge variables
- **DB schema:** [VariablesCatalog](../catalog-tables/VariablesCatalog.md) (aggregate) · [VariableUsages](../catalog-tables/VariableUsages.md) (per-usage detail)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_variable.sql` (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md))
- **Frontend:** object list at `http://localhost:5173/?type=Variable`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Script](Script.md) · [DDR_Calculations](../catalog-tables/DDR_Calculations.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
