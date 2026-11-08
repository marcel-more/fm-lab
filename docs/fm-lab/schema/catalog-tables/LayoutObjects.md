# LayoutObjects

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md)

Every object on every layout — all 26 object types, from edit boxes and buttons to portals, tab controls and web viewers — with the real container hierarchy: `Parent_Object_ID` and `Nesting_Level` reproduce the nesting of tab panels, slide panels, groups and popovers (nesting depth 5 occurs in practice). Position (`Bounds_*`), stacking order (`Z_Order`), the visible text of text objects and button labels, and the frequently needed formula texts (hide condition, tooltip, button-bar label, panel title, trigger parameter, field entry) are extracted into columns.

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
| `Title_Calculation_Text` | `VARCHAR` |
| `ScriptTrigger_Parameter_Text` | `VARCHAR` |
| `Entry_Options_Raw` | `BIGINT` |
| `Entry_Browse` | `VARCHAR` |
| `Entry_Find` | `VARCHAR` |
| `Entry_Calculation_Text` | `VARCHAR` |
| `Text_Content` | `VARCHAR` |
| `Object_XML` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `Part_Seq` | `BIGINT` |
| `Part_Kind` | `BIGINT` |

## Notes

- `Object_Type` is canonicalized to English type names at import (the raw attribute is localized) — the full subtype list is enumerated in [Object Types](../object-catalog/Object%20Types.md).
- `Object_ID` is unique only within a layout; `Object_UUID` is the global key.
- **Part of an object.** `Part_Seq` / `Part_Kind` name the [layout part](LayoutParts.md) the object belongs to (join on `File_Name`, `Layout_ID` and `Part_Seq`). The import derives them from the geometry: a root object (`Nesting_Level = 0`) belongs to the part whose band contains its top edge — a top edge exactly on a part boundary belongs to the lower part —, a nested object to the part of its parent. The bounds of nested objects are relative to their parent. `Part_Type` is the canonical type of that part. The P6 check `v_check_layoutobjects_without_part` counts objects without a part (expected 0).
- `Object_XML` holds the complete raw definition for anything not extracted; field/script/value-list references are already resolved into [ObjectLinks](../object-catalog/ObjectLinks.md) (`displays_field`, `triggers_script`, `uses_valuelist`, `portal_context`, …), including references of button-embedded single steps.
- Conditional-formatting rules are structured in [LayoutObjectConditions](LayoutObjectConditions.md) and the `{{…}}` symbols of text objects and button labels in [LayoutObjectSymbols](LayoutObjectSymbols.md) — never regex `Object_XML` or `Text_Content` for either.
- Text, label and title follow exactly one XML path per `Object_Kind` (the raw `@type` is localized, `@kind` is not):
  - `Text_Content` — the visible static text of a text object (kind 2) and the label of a button (kind 10) or popover button (kind 14). FileMaker evaluates anchors typed into a label at runtime — merge fields (unqualified ones always against the layout's table occurrence, also inside a portal row), merge variables and layout calculations `<<ƒ:…>>` — so they resolve like in a text object (`displays_field` with subrole `label_text`, `displays_variable`, `display_calculation` instances). A `{{symbol}}` in a label is **not** evaluated and stays literal.
  - `Label_Calculation_Text` — the label formula of a button-bar segment; FileMaker stores a segment label as a formula even when it is static text. Label text and label formula exclude each other.
  - `Title_Calculation_Text` — the title formula of a popover panel (kind 15) and of a tab panel (kind 12). The label of a popover segment in a button bar is empty; what shows is its panel's title.
  - The P6 check `v_check_layout_text_paths` compares the three columns against the object's own raw XML (expected 0 in every column).
- `Entry_Browse` / `Entry_Find` decode the field-entry bits of `Entry_Options_Raw` per mode (`allow`, `select_only`, `view_only`, `by_calculation`); `Entry_Calculation_Text` is the formula of the `by_calculation` state (FileMaker 26 exports only).
- `ScriptTrigger_Parameter_Text` is the object-level **aggregate** of all trigger-parameter texts (concatenated); the per-trigger truth lives in [ScriptTriggers.Trigger_Parameter_Text](ScriptTriggers.md).

**See also:** [Layouts](Layouts.md) · [LayoutParts](LayoutParts.md) · [LayoutObjectConditions](LayoutObjectConditions.md) · [LayoutObjectSymbols](LayoutObjectSymbols.md) · [ObjectLinks](../object-catalog/ObjectLinks.md)
