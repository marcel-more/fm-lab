# LayoutObjectStyles

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md) — the own `<LocalCSS>` element of a layout object

The style of every layout object: which theme style it uses and what it sets locally. One row per object that carries its own `LocalCSS`. The element is read only at the object itself — a group, portal or tab control never reports the CSS of the objects inside it.

## Columns

| Column | Type |
|---|---|
| `Object_UUID` | `VARCHAR` |
| `Layout_ID` | `BIGINT` |
| `File_Name` | `VARCHAR` |
| `Object_Type` | `VARCHAR` |
| `Style_Name` | `VARCHAR` |
| `Style_Display` | `VARCHAR` |
| `Style_Type` | `VARCHAR` |
| `Local_CSS` | `VARCHAR` |
| `Local_Font_Family` | `VARCHAR` |
| `Local_Font_Size` | `VARCHAR` |
| `Local_Font_Weight` | `VARCHAR` |
| `Local_Font_Style` | `VARCHAR` |

## Notes

- `Style_Name` is the applied style: `FM-<UUID>` for a custom style, otherwise the class of a built-in style (e.g. `footer_text`). Empty means no style. The matching rules are in [ThemeStyleRules](ThemeStyleRules.md) (`Style_Class`).
- `Style_Display` is the name the Inspector shows. `Style_Type` exists in FileMaker 26 exports only; detect a style by `Style_Name`.
- `Local_Font_*` are the values of the object's own normal rule, as written (`-fm-font-family(Courier New,CourierNewPSMT)`, `18pt`, `bold`). Empty means not set locally — the theme decides.
- A local font is not always a deliberate choice. Setting bold on a font with its own bold face also writes the family, with the bold face's PostScript name. Changing the theme resets the family and keeps a local size.
- `Local_CSS` keeps the complete local rule set (all states and elements) for every other analysis.

**See also:** [LayoutObjects](LayoutObjects.md) · [ThemeStyleRules](ThemeStyleRules.md) · [LayoutObjectFontRuns](LayoutObjectFontRuns.md) · [LayoutObjectCssType](LayoutObjectCssType.md)
