# ThemeCatalog

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML ThemeCatalog](../../xml/catalogs/XML%20ThemeCatalog.md)

The layout themes of each file, including the raw CSS rule set (`Theme_XML`). Layouts reference their theme via `uses_theme` links — the basis for "which themes are actually in use?" cleanup queries.

## Columns

| Column | Type |
|---|---|
| `Theme_ID` | `BIGINT` |
| `Theme_Name` | `VARCHAR` |
| `Theme_Display` | `VARCHAR` |
| `Theme_Group` | `VARCHAR` |
| `Base_Name` | `VARCHAR` |
| `Base_Version` | `VARCHAR` |
| `Theme_Version` | `VARCHAR` |
| `Theme_Locale` | `VARCHAR` |
| `Theme_Platform` | `VARCHAR` |
| `Is_Default` | `BOOLEAN` |
| `Theme_UUID` | `VARCHAR` |
| `Theme_XML` | `VARCHAR` |
| `Modified_At` | `VARCHAR` |
| `Modified_By` | `VARCHAR` |
| `Modified_Account` | `VARCHAR` |
| `Modifications` | `BIGINT` |
| `File_Name` | `VARCHAR` |

## Notes

- The header columns are the raw `<Theme>` attributes (schema 1.46.0): `Theme_Group` is `Custom` for a custom theme, otherwise the localized family of the built-in theme (e.g. `Apex Blau`, `Klassisch`). `Base_Name` / `Base_Version` name the built-in theme a custom theme derives from (internal name; custom themes only). `Theme_Locale` is the language of the built-in style names, `Theme_Platform` a code whose meaning is undocumented. `Is_Default` marks the default theme for new layouts of the file — at most one per file.
- `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` are the raw change metadata of the object's `<UUID>` element: timestamp as text (local time of the editing client, no time zone), user name, account (empty → `NULL`) and change counter. [ObjectChangeMeta](ObjectChangeMeta.md) collects them across all object types with a typed timestamp.

**See also:** [Layouts](Layouts.md) · [ThemeNamedStyles](ThemeNamedStyles.md) · [ThemePartStyles](ThemePartStyles.md) · [ThemeStyleRules](ThemeStyleRules.md)
