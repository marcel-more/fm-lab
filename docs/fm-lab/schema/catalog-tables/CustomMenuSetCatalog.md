# CustomMenuSetCatalog

Part of the [FM-Lab schema](../Schema.md) · Custom menus · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML CustomMenuSetCatalog](../../xml/catalogs/XML%20CustomMenuSetCatalog.md)

The custom menu sets of each file with their member menus as ID and name arrays. Layouts bind a menu set via `uses_menuset` links; scripts install one via `installs_menuset`.

## Columns

| Column | Type |
|---|---|
| `MenuSet_ID` | `BIGINT` |
| `MenuSet_Name` | `VARCHAR` |
| `Comment` | `VARCHAR` |
| `MenuSet_UUID` | `VARCHAR` |
| `Member_Menu_IDs` | `BIGINT[]` |
| `Member_Menu_Names` | `VARCHAR[]` |
| `Modified_At` | `VARCHAR` |
| `Modified_By` | `VARCHAR` |
| `Modified_Account` | `VARCHAR` |
| `Modifications` | `BIGINT` |
| `File_Name` | `VARCHAR` |

## Notes

- `Member_Menu_IDs` / `Member_Menu_Names` list the custom menus of the set, in the same order. A set without member menus has an empty list `[]`.
- `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` are the raw change metadata of the object's `<UUID>` element: timestamp as text (local time of the editing client, no time zone), user name, account (empty → `NULL`) and change counter. [ObjectChangeMeta](ObjectChangeMeta.md) collects them across all object types with a typed timestamp.

**See also:** [CustomMenuCatalog](CustomMenuCatalog.md) · [Layouts](Layouts.md)
