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
| `Theme_UUID` | `VARCHAR` |
| `Theme_XML` | `VARCHAR` |
| `Modified_At` | `VARCHAR` |
| `Modified_By` | `VARCHAR` |
| `Modified_Account` | `VARCHAR` |
| `Modifications` | `BIGINT` |
| `File_Name` | `VARCHAR` |

## Notes

- `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` are the raw change metadata of the object's `<UUID>` element: timestamp as text (local time of the editing client, no time zone), user name, account (empty → `NULL`) and change counter. [ObjectChangeMeta](ObjectChangeMeta.md) collects them across all object types with a typed timestamp.

**See also:** [Layouts](Layouts.md) · [ThemePartStyles](ThemePartStyles.md)
