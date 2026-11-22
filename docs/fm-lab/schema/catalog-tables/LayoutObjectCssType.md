# LayoutObjectCssType

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**Source:** curated mapping, created at import

Under which name the theme CSS keeps the rules of a layout object type: `Edit Box` → `edit_box`, `Text` → `text_box`, and so on. The mapping is fixed and was checked in FileMaker 22 and 26 with a custom style on every object type.

## Columns

| Column | Type |
|---|---|
| `Object_Type` | `VARCHAR` |
| `Parent_Object_Type` | `VARCHAR` |
| `Type_Token` | `VARCHAR` |
| `Group_Token` | `VARCHAR` |
| `Has_Text` | `BOOLEAN` |

## Notes

- A row with `Parent_Object_Type` applies to that container only and wins over the general row: buttons inside a button bar use `button_bar_segment`, panels of a tab control `tab_panel`.
- `Group_Token = 'field'` marks the field controls. The theme rule `field` supplies a property only when the type rule leaves it unset.
- Drop-down lists, drop-down calendars and concealed fields use `edit_box`. Their own theme rules `drop_down` and `calendar` do not change the field font.
- `Has_Text` marks object types that show text themselves. Types without a row — rectangles, lines, graphics, groups, grouped buttons, popover panels — show no text of their own; the texts inside a grouped button are objects of their own.

**See also:** [ThemeStyleRules](ThemeStyleRules.md) · [LayoutObjectStyles](LayoutObjectStyles.md) · [LayoutObjects](LayoutObjects.md)
