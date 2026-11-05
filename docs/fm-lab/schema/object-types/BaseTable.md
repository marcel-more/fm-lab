# BaseTable

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **base table** is a schema-level table of a FileMaker file — an entry of *Manage Database → Tables*, independent of how often (or whether) it appears on the relationship graph. The base table itself is a thin object: it carries little more than name, comment and identity. Its substance lives in its [fields](Field.md), and everything context-related — layouts, relationships, portals, value lists — binds not to the base table but to its [table occurrences](TableOccurrence.md) on the graph.

BaseTable is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'BaseTable'` mirrors one `<BaseTable>` element of the export, with the detail row in [BaseTableCatalog](../catalog-tables/BaseTableCatalog.md) — deliberately one of the smallest type-specific tables in the catalog.

## Properties

The `<BaseTable>` element is flat; the field definitions follow separately in the [XML FieldsForTables](../../xml/catalogs/XML%20FieldsForTables.md) branch. Properties marked **not extracted** are visible in the raw XML only.

| Property (XML)                                                     | In catalog | Notes                                                                                           |
| ------------------------------------------------------------------ | ---------- | ----------------------------------------------------------------------------------------------- |
| `@id`                                                              | `BT_ID`    | Numeric FileMaker ID — unique per file only, join with `File_Name`                              |
| `@name`                                                            | `BT_Name`  |                                                                                                 |
| `@comment`                                                         | —          | Developer comment on the table — **not extracted**                                              |
| `<UUID>` (text)                                                    | `BT_UUID`  | Stable identity, used for all joins                                                             |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<TagList>`                                                        | —          | Object tags — **not extracted**                                                                 |
| `<SourceUUID>`, `<OwnerID>`                                        | —          | Observed in the test fixtures on a SaXML-delivered table only; undocumented — **not extracted** |

## Object hierarchy

A base table **owns its fields**: every [Field](Field.md) points to its table via an incoming `parent_table` link, and [FieldsForTables](../catalog-tables/FieldsForTables.md) groups the field definitions per base table. On the relationship graph the base table never appears directly — it is **represented by its table occurrences**, each of which points back via a `base_table` link. A base table with no occurrence is invisible to layouts and relationships; a base table with many occurrences appears once per occurrence.

In the frontend, the base-table detail view renders this hierarchy directly: it lists the table's fields and its occurrences on the graph.

## References

Base tables produce no outgoing edges of their own — they are pure targets, anchoring fields and occurrences. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (BaseTable as source)

None registered.

### Incoming links (BaseTable as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `parent_table` | [Field](Field.md) | usage | The field belongs to this base table |
| `base_table` | [TableOccurrence](TableOccurrence.md) | usage | The occurrence represents this base table on the graph |

## Schema & tooling

- **XML schema:** [XML BaseTableCatalog](../../xml/catalogs/XML%20BaseTableCatalog.md) — `Structure/AddAction` branch, one `<BaseTable>` per table
- **DB schema:** [BaseTableCatalog](../catalog-tables/BaseTableCatalog.md) · field definitions in [FieldsForTables](../catalog-tables/FieldsForTables.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_basetable.sql` (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md))
- **Frontend:** object list at `http://localhost:5173/?type=BaseTable`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Field](Field.md) · [TableOccurrence](TableOccurrence.md) · [Relationship](Relationship.md)
