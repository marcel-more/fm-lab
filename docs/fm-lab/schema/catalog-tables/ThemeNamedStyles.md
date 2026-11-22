# ThemeNamedStyles

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**Source:** derived at import from the `<Metadata><namedstyles>` block of [ThemeCatalog](ThemeCatalog.md) (`Theme_XML`)

Every named style of a theme: built-in styles and custom styles, each with the name the Inspector shows. Unlike `v_layout_object_style`, which sees only the styles objects actually use, this table also lists the **unused** styles — the basis for "which custom styles of this theme does no layout use?".

## Columns

| Column | Type |
|---|---|
| `File_Name` | `VARCHAR` |
| `Theme_UUID` | `VARCHAR` |
| `Theme_Name` | `VARCHAR` |
| `Style_Seq` | `INTEGER` |
| `Style_Class` | `VARCHAR` |
| `Style_Display` | `VARCHAR` |
| `Is_Custom` | `BOOLEAN` |

## Notes

- One row per style and theme of a file. `Style_Seq` keeps the order of the `namedstyles` block.
- `Style_Class` is the style's CSS class — the same value as `ThemeStyleRules.Style_Class` and `v_layout_object_style.Style_Name`. Custom styles have a class `FM-<UUID>` (`Is_Custom = true`), built-in styles a readable class such as `title_text_1`.
- `Style_Display` is the Inspector name in the language the theme was created in (`ThemeCatalog.Theme_Locale`); built-in names are not translated. Older exports write umlauts as character references (`Wei&#xDF;`) — the import decodes them.
- Usage of a style is counted in the theme's own file: a theme cloned into several files (same `Theme_UUID`) has the same style list in each, but its own usage per file.
- The object type of a style comes from the `Type_Token` of its rules in [ThemeStyleRules](ThemeStyleRules.md); a style can carry several tokens (e.g. button bar and segment).
- Themes without `namedstyles` — Classic and Minimalist — have no rows. The built-in class `navigation_button` has CSS rules but no entry here.
- Read once at import; nothing parses `Theme_XML` at run time. The import check reports duplicate classes per theme (warning) and classes with a rule but no name, or a name without a rule (information).

**See also:** [ThemeCatalog](ThemeCatalog.md) · [ThemeStyleRules](ThemeStyleRules.md) · [Layouts](Layouts.md) · [LayoutObjects](LayoutObjects.md)
