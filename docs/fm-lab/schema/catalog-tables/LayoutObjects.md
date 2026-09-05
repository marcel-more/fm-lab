# LayoutObjects

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md)

Every object on every layout — all 26 object types, from edit boxes and buttons to portals, tab controls and web viewers — with the real container hierarchy: `Parent_Object_ID` and `Nesting_Level` reproduce the nesting of tab panels, slide panels, groups and popovers (nesting depth 5 occurs in practice). Position (`Bounds_*`), stacking order (`Z_Order`) and the frequently needed formula texts (hide condition, tooltip, button label, trigger parameter) are extracted into columns.

## Columns

| Column | Type |
|---|---|
| `Layout_ID` | `BIGINT` |
| `Part_Type` | `VARCHAR` |
| `Object_ID` | `BIGINT` |
| `Object_Type` | `VARCHAR` |
| `Object_Name` | `VARCHAR` |
| `Object_Kind` | `BIGINT` |
| `Object_Hash` | `VARCHAR` |
| `Object_UUID` | `VARCHAR` |
| `Bounds_Top` | `BIGINT` |
| `Bounds_Left` | `BIGINT` |
| `Bounds_Bottom` | `BIGINT` |
| `Bounds_Right` | `BIGINT` |
| `Parent_Object_ID` | `BIGINT` |
| `Nesting_Level` | `BIGINT` |
| `Z_Order` | `BIGINT` |
| `Hide_Calculation_Text` | `VARCHAR` |
| `Tooltip_Calculation_Text` | `VARCHAR` |
| `Label_Calculation_Text` | `VARCHAR` |
| `ScriptTrigger_Parameter_Text` | `VARCHAR` |
| `Text_Content` | `VARCHAR` |
| `Object_XML` | `VARCHAR` |
| `File_Name` | `VARCHAR` |

## Notes

- `Object_Type` is canonicalized to English type names at import (the raw attribute is localized) — the full subtype list is enumerated in [Object Types](../object-catalog/Object%20Types.md).
- `Object_ID` is unique only within a layout; `Object_UUID` is the global key.
- `Object_XML` holds the complete raw definition for anything not extracted; field/script/value-list references are already resolved into [ObjectLinks](../object-catalog/ObjectLinks.md) (`displays_field`, `triggers_script`, `uses_valuelist`, `portal_context`, …), including references of button-embedded single steps.
- Conditional-formatting rules are structured in [LayoutObjectConditions](LayoutObjectConditions.md) and the `{{…}}` symbols of text objects in [LayoutObjectSymbols](LayoutObjectSymbols.md) — never regex `Object_XML` or `Text_Content` for either.
- `ScriptTrigger_Parameter_Text` is the object-level **aggregate** of all trigger-parameter texts (concatenated); the per-trigger truth lives in [ScriptTriggers.Trigger_Parameter_Text](ScriptTriggers.md).

**See also:** [Layouts](Layouts.md) · [LayoutParts](LayoutParts.md) · [LayoutObjectConditions](LayoutObjectConditions.md) · [LayoutObjectSymbols](LayoutObjectSymbols.md) · [ObjectLinks](../object-catalog/ObjectLinks.md)
