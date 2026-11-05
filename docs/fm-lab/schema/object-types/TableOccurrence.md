# TableOccurrence

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **table occurrence** is a node on the relationship graph — a named instance of a [base table](BaseTable.md) (local, or in another file via an [external data source](ExternalDataSource.md)). Occurrences are FileMaker's unit of *context*: layouts, relationship sides, portals, Go-to-Related-Record steps, lookups and field-based value lists all bind to an occurrence, never to the base table directly. One base table can appear on the graph any number of times under different names, each spanning its own join paths.

Beyond the semantic reference, each occurrence carries the **visual state of its node on the graph canvas** — position rectangle, node color, collapsed/expanded view — so the developer's spatial organization of the graph survives the import and stays analyzable.

TableOccurrence is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'TableOccurrence'` mirrors one `<TableOccurrence>` element of the export, with the detail row in [TableOccurrenceCatalog](../catalog-tables/TableOccurrenceCatalog.md).

## Properties

Properties marked **not extracted** are visible in the raw XML only.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `TO_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `TO_Name` | Unique across the file's graph |
| `@type` | `TO_Type` | `Local` / `External` — see [Enumerations](#enumerations) |
| `@View` | `View_State` | Collapse state of the node on the canvas |
| `@height` | `Box_Height` | Height of the node box |
| `<UUID>` (text) | `TO_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<BaseTableSourceReference>/@type` | — | Discriminator of the source wrapper; `BaseTableReference` / `ExternalDataSourceReference` *(fixture)* — redundant with `@type`, **not extracted** |
| `<BaseTableReference>` `@id` / `@name` / `@UUID` | `BT_ID` / `BT_Name` / `BT_UUID` | The represented base table → `base_table` link |
| Data-source reference (external occurrences) | `DS_ID` / `DS_Name` / `DS_UUID` | The external data source plus remote table → `data_source` link; in the test fixture the external occurrence's wrapper is empty |
| `<CoordRect>` `@top` / `@left` / `@bottom` / `@right` | `Coord_Top` / `Coord_Left` / `Coord_Bottom` / `Coord_Right` | Position rectangle on the graph canvas |
| `<Color>` `@red` / `@green` / `@blue` / `@alpha` | `Color_R` / `Color_G` / `Color_B` / `Color_Alpha` | Node color |
| `<TagList>` | — | Object tags — **not extracted** |
| `<SourceUUID>` | — | Observed in the test fixtures on a SaXML-delivered occurrence only; undocumented — **not extracted** |
| `<TableOccurrenceNotes>` (catalog-level) | — | Free-floating text annotations on the graph canvas, encoded as layout objects — **not extracted** |

## References

Occurrences sit at the hub of the context model: they point down to their base table (and, for external occurrences, their data source), while layouts, relationships, lookups, GTRR steps, portals and value lists all point at them. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (TableOccurrence as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `base_table` | [BaseTable](BaseTable.md) | usage | The base table the occurrence represents |
| `data_source` | [ExternalDataSource](ExternalDataSource.md) | usage | External occurrence sources its table from this data source |

### Incoming links (TableOccurrence as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `context_table` | [Layout](Layout.md) | usage | The layout's context table occurrence |
| `left_table` / `right_table` | [Relationship](Relationship.md) | usage | The occurrence is a side of the relationship |
| `lookup_relationship` | [Field](Field.md) | usage | A lookup resolves through this occurrence |
| `navigates_to_to` | [Script](Script.md) / [LayoutObject](LayoutObject.md) | usage | Go to Related Record targets the occurrence |
| `portal_context` | [LayoutObject](LayoutObject.md) | usage | The portal's data-source occurrence |
| `source_table` | [ValueList](ValueList.md) | usage | Field-based value list sources from this occurrence |

## Enumerations

Values marked *(corpus)* are the literals observed in the ooe-fm test corpus; the XML literal set beyond them is not independently documented.

| Property | Values |
|---|---|
| `TO_Type` | `Local`, `External` *(corpus)* |
| `View_State` | `Full` *(corpus)* — the collapsed/reduced node states of the graph canvas were not observed |

## Schema & tooling

> **TBD:** no dedicated detail view in the frontend yet — the generic detail template (`object_details_generic.sql`) is used.

- **XML schema:** [XML TableOccurrenceCatalog](../../xml/catalogs/XML%20TableOccurrenceCatalog.md) — `Structure/AddAction` branch, one `<TableOccurrence>` per graph node
- **DB schema:** [TableOccurrenceCatalog](../catalog-tables/TableOccurrenceCatalog.md)
- **Detail view template:** generic fallback `rest-api/templates/queries/system/object-details/object_details_generic.sql` (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md))
- **Frontend:** object list at `http://localhost:5173/?type=TableOccurrence`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [BaseTable](BaseTable.md) · [Relationship](Relationship.md) · [ExternalDataSource](ExternalDataSource.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
