# ThemePartStyles

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**Source:** derived at import from the CSS of [ThemeCatalog](ThemeCatalog.md) (`Theme_XML`)

The row-state defaults of every theme: whether a body part uses the *alternate row state* and the *active row state* when the part itself sets nothing. One row per theme, file and style — `Style_Name = 'body'` is the theme default of the body part (CSS rule `body:normal .self`), every other row a named part style (`part.<name>:normal .self`, e.g. `alternating_part`).

## Columns

| Column | Type |
|---|---|
| `Theme_UUID` | `VARCHAR` |
| `Theme_Name` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `Style_Name` | `VARCHAR` |
| `Alt_Background` | `BOOLEAN` |
| `Active_Row_Style` | `BOOLEAN` |

## Notes

- `Alt_Background` is `-fm-body-alt-background`, `Active_Row_Style` is `-fm-use-body-current-row-style`; `NULL` means the rule does not set the property.
- These are stages 2 and 3 of the row-state cascade of a body part: the part's own value ([LayoutParts.Part_Alt_Row_Local / Part_Active_Row_Local](LayoutParts.md)), then its part style, then the theme's body rule, otherwise off.
- Classic themes carry no such rule and have no row here — row state off unless the part sets it.
- Read once at import; nothing parses `Theme_XML` at run time. The layout part detail view shows the effective value and where it comes from.

**See also:** [ThemeCatalog](ThemeCatalog.md) · [LayoutParts](LayoutParts.md) · [Layouts](Layouts.md)
