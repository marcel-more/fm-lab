# ExtendedPrivilegesCatalog

Part of the [FM-Lab schema](../Schema.md) · Security · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML ExtendedPrivilegesCatalog](../../xml/catalogs/XML%20ExtendedPrivilegesCatalog.md)

The extended privileges (`fmapp`, `fmwebdirect`, `fmxdbc`, custom keywords, …) of each file, each with the list of privilege sets that grant it — the quick answer to access-audit questions like "who may connect via WebDirect?" (also available as `grants_privilege` graph links).

## Columns

| Column | Type |
|---|---|
| `EP_ID` | `BIGINT` |
| `EP_Name` | `VARCHAR` |
| `EP_Description` | `VARCHAR` |
| `EP_UUID` | `VARCHAR` |
| `PrivilegeSet_IDs` | `BIGINT[]` |
| `PrivilegeSet_Names` | `VARCHAR[]` |
| `Modified_At` | `VARCHAR` |
| `Modified_By` | `VARCHAR` |
| `Modified_Account` | `VARCHAR` |
| `Modifications` | `BIGINT` |
| `File_Name` | `VARCHAR` |

## Notes

- `PrivilegeSet_IDs` / `PrivilegeSet_Names` list the privilege sets that grant the extended privilege, in the same order. An extended privilege that no set grants has an empty list `[]`.
- `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` are the raw change metadata of the object's `<UUID>` element: timestamp as text (local time of the editing client, no time zone), user name, account (empty → `NULL`) and change counter. [ObjectChangeMeta](ObjectChangeMeta.md) collects them across all object types with a typed timestamp.

**See also:** [PrivilegeSetsCatalog](PrivilegeSetsCatalog.md)
