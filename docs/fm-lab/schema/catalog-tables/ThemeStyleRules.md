# ThemeStyleRules

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**Source:** derived at import from the CSS of [ThemeCatalog](ThemeCatalog.md) (`Theme_XML`)

The CSS of every theme, split into rules and declarations: one row per declaration, with the selector broken into its parts. It answers "what does the theme set for this object type, this style, this layout part?" without parsing CSS at run time — for fonts, colors, borders and every other property.

## Columns

| Column | Type |
|---|---|
| `Theme_UUID` | `VARCHAR` |
| `Theme_Name` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `Rule_Seq` | `INTEGER` |
| `Selector` | `VARCHAR` |
| `Part_Token` | `VARCHAR` |
| `Type_Token` | `VARCHAR` |
| `Style_Class` | `VARCHAR` |
| `State` | `VARCHAR` |
| `Element` | `VARCHAR` |
| `Decl_Seq` | `INTEGER` |
| `Property` | `VARCHAR` |
| `Value` | `VARCHAR` |

## Notes

- Selectors follow the form `[<part> ]<token>[.<class>][:<state>][ .<element>]`:

  | Selector | Meaning |
  |---|---|
  | `text_box:normal .self` | default of an object type |
  | `edit_box.FM-<UUID>:normal .self` | custom style (`Style_Class` = the style name an object carries) |
  | `primary_button` as class | built-in style |
  | `header text_box:normal .self` | default of a type inside a layout part — holds only the deviations |
  | `field:normal .self` | group rule of all field controls; applies when the type rule leaves a property unset |
  | `part.<name>:normal .self` | named part style (`Type_Token = 'part'`) |

- `Rule_Seq` is the position in the CSS; with equal selectors the later rule wins.
- A style without any deviation from its type is written as a bare selector with an empty block (`text_box.FM-<UUID> { }`). It stays as one row with `Property` and `Value` empty, so the style is still visible.
- `Value` is kept as written, e.g. `-fm-font-family(arial,sans-serif,ArialMT;sans-serif)` — the first entry is the family, the PostScript name can name a face (`HelveticaNeue-Light`).
- Themes such as Classic and Minimalist declare no `font-family` at all. The font of their objects is a default of the file, which the export does not contain.
- All properties are kept, not only fonts. Objects reference the rules through [LayoutObjectStyles](LayoutObjectStyles.md) (`Style_Name` = `Style_Class`) and [LayoutObjectCssType](LayoutObjectCssType.md) (object type → `Type_Token`).

**See also:** [ThemeCatalog](ThemeCatalog.md) · [ThemePartStyles](ThemePartStyles.md) · [LayoutObjectStyles](LayoutObjectStyles.md) · [LayoutObjectCssType](LayoutObjectCssType.md)
