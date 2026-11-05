# Relationship

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **relationship** is an edge of the relationship graph, connecting two [table occurrences](TableOccurrence.md) through one or more **join predicates** — each predicate compares a field of the left side with a field of the right side under an operator. Per side, the relationship additionally carries the cascade options (*allow creation of related records*, *delete related records*) and an optional **sort definition** that orders the related set, including the *custom sort by value list* case.

Relationship is an **exported** type with two catalog particularities. First, [RelationshipCatalog](../catalog-tables/RelationshipCatalog.md) stores **one row per join predicate**, numbered by `Predicate_Index` — a multi-field join therefore spans several rows, and counting relationships means grouping by `Rel_ID` and `File_Name`. Second, the export's `<Relationship>` has no name, so the importer composes `Object_Name` as `<left occurrence> → <right occurrence>`. The identity is the export's own `<UUID>`: [ObjectCatalog](../object-catalog/ObjectCatalog.md) registers the relationship under that native UUID (`Rel_UUID`), unique per `(Object_UUID, File_Name)` like every native type. Only an export without `<UUID>` falls back to the composite key `rel_<id>_<file>`.

## Properties

Properties marked **not extracted** are visible in the raw XML only.

### Identity

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `Rel_ID` | Shared by all predicate rows of the relationship; unique per file only |
| `<UUID>` (text) | `Rel_UUID` | Native FileMaker UUID, shared by all predicate rows; the `Object_UUID` in [ObjectCatalog](../object-catalog/ObjectCatalog.md). A duplicate inside one file is re-keyed (see [UUID Healing and Duplicate Census](../UUID%20Healing%20and%20Duplicate%20Census.md)) |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata of the relationship, raw (`Modified_At` as text, empty account → `NULL`); typed per relationship in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<TagList>` | — | Object tags — **not extracted** |

### Sides (`<LeftTable>` / `<RightTable>`)

Every side-level property lands in a `Left_*` or `Right_*` column of the same predicate rows.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@type` | — | Side type (e.g. `Local`) — **not extracted** |
| `@cascadeCreate` | `Left_Create` / `Right_Create` | *Allow creation of records via this relationship* |
| `@cascadeDelete` | `Left_Delete` / `Right_Delete` | *Delete related records when a record is deleted* |
| `<TableOccurrenceReference>` `@id` / `@name` / `@UUID` | `Left_TO_ID` / `Left_TO_Name` / `Left_TO_UUID` (resp. `Right_*`) | → `left_table` / `right_table` links |

### Sort definition (`<SortSpecification>` per side, optional)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@value` | `Left_Sort_Enabled` / `Right_Sort_Enabled` | `NULL` when the side has no sort specification |
| `@maintain` | — | **Not extracted** |
| `<Sort>/@type` | — | Sort direction (`Ascending`, …; `Custom` = by value list) — **not extracted** as such, see below |
| `<PrimaryField><FieldReference>` (per `<Sort>`) | `Left_Sort_Fields` (comma-separated names) + `Left_Sort_Field_UUIDs` / `_Field_IDs` / `_Field_TO_UUIDs` arrays (resp. `Right_*`) | → `sort_field` links (subrole `left` / `right`) |
| `<ValueListReference>` (inside a `Custom` sort) | `Left_Sort_ValueList_UUIDs` / `Right_Sort_ValueList_UUIDs` | → `sorts_by_valuelist` links (subrole `left` / `right`) |

### Join predicates (`<JoinPredicateList>`)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@membercount` | — | Derivable as `max(Predicate_Index)` per relationship |
| `<JoinPredicate>/@type` | `Operator` | Comparison operator — see [Enumerations](#enumerations) |
| Predicate order | `Predicate_Index` | 1-based document order |
| `<LeftField><FieldReference>` `@id` / `@name` / `@UUID` | `Left_Field_ID` / `Left_Field_Name` / `Left_Field_UUID` | → `left_field` link |
| `<LeftField>…<TableOccurrenceReference>` | `Left_Field_TO_Name` / `Left_Field_TO_UUID` | The occurrence context of the compared field |
| `<RightField>` (same structure) | `Right_Field_*` | → `right_field` link |

## References

A relationship is a pure source: it references its two occurrences, the compared fields and any sort fields/value lists — nothing in the catalog points at a relationship (lookups, GTRR and portals reference the [TableOccurrence](TableOccurrence.md), not the edge). Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (Relationship as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `left_table` / `right_table` | [TableOccurrence](TableOccurrence.md) | usage | The occurrences forming the two sides |
| `left_field` / `right_field` | [Field](Field.md) | usage | Join-predicate field of the respective side (one pair per predicate) |
| `sort_field` | [Field](Field.md) | usage | Sort field of a relationship side (subrole `left` / `right`) |
| `sorts_by_valuelist` | [ValueList](ValueList.md) | usage | Custom sort order by value list (subrole `left` / `right`) |

### Incoming links (Relationship as target)

None registered.

## Enumerations

Values marked *(corpus)* are the literals observed in the ooe-fm test corpus; the XML literal set beyond them is not independently documented.

| Property | Values |
|---|---|
| `Operator` (`JoinPredicate/@type`) | `Equal` *(corpus)* — FileMaker's operator set additionally covers the not-equal, less/greater(-or-equal) comparisons and the Cartesian cross join |
| `Sort/@type` | `Ascending` *(corpus)*; `Custom` carries the sort-by-value-list case — the descending literal was not observed |

## Schema & tooling

- **XML schema:** [XML RelationshipCatalog](../../xml/catalogs/XML%20RelationshipCatalog.md) — `Structure/AddAction` branch, one `<Relationship>` per graph edge
- **DB schema:** [RelationshipCatalog](../catalog-tables/RelationshipCatalog.md) (one row per join predicate)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_relationship.sql` (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md))
- **Frontend:** object list at `http://localhost:5173/?type=Relationship`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [TableOccurrence](TableOccurrence.md) · [BaseTable](BaseTable.md) · [Field](Field.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
