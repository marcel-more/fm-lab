# ExternalDataSource

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

An **external data source** is an entry of *Manage External Data Sources* — a named pointer to another FileMaker file (or, in FileMaker generally, an ODBC source) with its path list. It is the indirection that makes cross-file architectures maintainable: [table occurrences](TableOccurrence.md) of type `External` and external [value lists](ValueList.md) reference the data-source entry by name, and only the entry itself knows the actual file path(s).

ExternalDataSource is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'ExternalDataSource'` mirrors one `<ExternalDataSource>` element of the export, with the detail row in [ExternalDataSourceCatalog](../catalog-tables/ExternalDataSourceCatalog.md).

## Properties

Properties marked **not extracted** are visible in the raw XML only.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `DS_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `DS_Name` | The name occurrences and value lists reference |
| `@type` | `DS_Type` | Source type — see [Enumerations](#enumerations) |
| `<UUID>` (text) | `DS_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<File><UniversalPathList>` | `Path` | The path list, `file:`-prefixed; the fixtures show single-entry lists — FileMaker allows several fallback paths per source |
| ODBC branch (DSN / driver details) | — | Only FileMaker-type sources appear in the fixtures and corpus — the ODBC-side XML structure and its catalog coverage are **undetermined** |
| `<TagList>` | — | Object tags — **not extracted** |

## References

A data source is a pure target: it produces no outgoing edges, while the objects that pull data through it point at it via `data_source`. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (ExternalDataSource as source)

None registered.

### Incoming links (ExternalDataSource as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `data_source` | [TableOccurrence](TableOccurrence.md) / [ValueList](ValueList.md) | usage | The object sources its data from this external data source |

## Enumerations

| Property | Values |
|---|---|
| `DS_Type` | `FileMaker` *(corpus)* — FileMaker also supports ODBC data sources, not observed in the corpus |

## Schema & tooling

> **TBD:** no dedicated detail view in the frontend yet — the generic detail template (`object_details_generic.sql`) is used.

- **XML schema:** [XML ExternalDataSourceCatalog](../../xml/catalogs/XML%20ExternalDataSourceCatalog.md) — `Structure/AddAction` branch, one `<ExternalDataSource>` per entry
- **DB schema:** [ExternalDataSourceCatalog](../catalog-tables/ExternalDataSourceCatalog.md)
- **Detail view template:** generic fallback `rest-api/templates/queries/system/object-details/object_details_generic.sql` (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md))
- **Frontend:** object list at `http://localhost:5173/?type=ExternalDataSource`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [TableOccurrence](TableOccurrence.md) · [ValueList](ValueList.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
