# BaseDirectory

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **base directory** is a named path anchor of a FileMaker file — a directory definition that container-field storage (external/open storage) and file references resolve their relative paths against. The catalog is small and flat: each entry is little more than a name, a relative-to flag and its identity. Base directories are created implicitly when external container storage is configured, so multiple entries with the same name can coexist.

BaseDirectory is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'BaseDirectory'` mirrors one `<BaseDirectory>` element of the export, with the detail row in [BaseDirectoryCatalog](../catalog-tables/BaseDirectoryCatalog.md).

## Properties

Properties marked **not extracted** are visible in the raw XML only.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `BD_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `BD_Name` | Directory name; the fixture values end with a trailing `/` |
| `@relativeTo` | `BD_RelativeTo` | Relative-to semantics of the definition; only `True` observed *(corpus)* |
| `<UUID>` (text) | `BD_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<TagList>` | — | Object tags — **not extracted** |
| `<BaseDirectoryCatalog>/@generate`, `@temporary` (catalog-level) | — | Flags on the catalog element itself, not on the entries — **not extracted** |

## References

No link roles are registered for BaseDirectory in either direction. The XML place where base directories are actually consumed — the `<BaseDirectoryReference>` inside a container field's external-storage block (`<Storage><Remote>`) — is itself not extracted (see [Field](Field.md)), so the catalog contains no edges to or from base directories; where-used questions for this type currently require the raw XML. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (BaseDirectory as source)

None registered.

### Incoming links (BaseDirectory as target)

None registered.

## Schema & tooling

- **XML schema:** [XML BaseDirectoryCatalog](../../xml/catalogs/XML%20BaseDirectoryCatalog.md) — `Structure/AddAction` branch, one `<BaseDirectory>` per entry
- **DB schema:** [BaseDirectoryCatalog](../catalog-tables/BaseDirectoryCatalog.md)
- **Detail view template:** generic fallback `rest-api/templates/queries/system/object-details/object_details_generic.sql` (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md))
- **Frontend:** object list at `http://localhost:5173/?type=BaseDirectory`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Field](Field.md) · [FileOptionsCatalog](../catalog-tables/FileOptionsCatalog.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
