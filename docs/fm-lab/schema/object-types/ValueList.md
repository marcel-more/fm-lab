# ValueList

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **value list** is a named list of values used by layout controls (drop-down lists, pop-up menus, radio button and checkbox sets), by field validation ("member of value list") and by custom sort orders. FileMaker distinguishes three source kinds: **custom values** typed literally into the definition, **field-based** lists that read their values from a field (optionally showing/sorting by a second field and restricting to related records), and **external wrappers** that reuse a value list defined in another file via an external data source.

ValueList is an **exported** type spread over two branches: [XML ValueListCatalog](../../xml/catalogs/XML%20ValueListCatalog.md) carries identity plus the source kind, [XML OptionsForValueLists](../../xml/catalogs/XML%20OptionsForValueLists.md) the actual definition. Each list becomes a row in [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'ValueList'`; the definition details land in [OptionsForValueLists](../catalog-tables/OptionsForValueLists.md), one row per list, and the field/table/external references are resolved into graph links at import.

## Properties

### Identity (`<ValueList>` in the value-list catalog)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `VL_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `VL_Name` | |
| `<Source>/@value` | `Source_Type` | Source kind — see [Enumerations](#enumerations) |
| `<UUID>` (text) | `VL_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<TagList>` | — | Tags — **not extracted** |

### Definition (`<ValueList>` in the options branch)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `<ValueListReference>` (`@id`, `@name`, `@UUID`) | `VL_ID` / `VL_Name` / `VL_UUID` | Re-identifies the list in [OptionsForValueLists](../catalog-tables/OptionsForValueLists.md) |
| `<CustomValues>/<Text>` | `Custom_Values` | Literal values split into a `VARCHAR[]` (custom lists) |
| `<Field>/<PrimaryField>/<FieldReference>` (+ nested `<TableOccurrenceReference>`) | `Field_ID`/`Field_Name`/`Field_UUID` · `TO_ID`/`TO_Name`/`TO_UUID` | Value field and its occurrence → `source_field` (subrole `primary`) / `source_table` links |
| `<PrimaryField>/@sort` | `Field_Sort` | Sort by the first field |
| `<PrimaryField>/@show` | — | Display option of the first field — **not extracted** |
| `<Field>/<SecondaryField>` (`@show`, `@sort`, `<FieldReference>` + TO) | `Secondary_Field_*` / `Secondary_TO_*` / `Secondary_Sort` | Second field → `source_field` link (subrole `secondary` / `secondary_sort`); its `@show` is **not extracted** |
| `<Field>/<ShowRelated>` (`@value`, optional `<TableOccurrenceReference>`) | — | "Include only related values starting from" option — **not extracted** |
| `<External>/<DataSourceReference>` (`@id`, `@name`, `@UUID`) | `External_DS_ID` / `External_DS_Name` / `External_DS_UUID` | The external data source → `data_source` link |
| `<External>/<DataSourceReference>/<UniversalPathList>` | — | Path list of the data source — **not extracted** here (lives in [ExternalDataSourceCatalog](../catalog-tables/ExternalDataSourceCatalog.md)) |
| `<External>/<ValueListReference>` (`@id`, `@name`; `@UUID` **empty**) | `External_VL_ID` / `External_VL_Name` | The wrapped list in the target file; its UUID is absent in the XML — the importer resolves it via data source + list ID (name as fallback) into the `source_valuelist` link |

## References

A value list's own definition produces the outgoing edges; controls, validations, sorts and privilege restrictions target it from outside. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (ValueList as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `source_field` | [Field](Field.md) | usage | Field-based list sources its values here (subrole `primary` / `secondary` / `secondary_sort`) |
| `source_table` | [TableOccurrence](TableOccurrence.md) | usage | Field-based list: the source occurrence |
| `source_valuelist` | ValueList | usage | External wrapper sources its values from a list in another file |
| `data_source` | [ExternalDataSource](ExternalDataSource.md) | usage | External wrapper reaches the other file through this data source |

### Incoming links (ValueList as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `uses_valuelist` | [LayoutObject](LayoutObject.md) / [Field](Field.md) | usage | A field control uses the list; field validation by list (subrole `validation`) |
| `sorts_by_valuelist` | [Script](Script.md) / [LayoutObject](LayoutObject.md) / [Relationship](Relationship.md) | usage | Custom sort order by value list (subrole `left`/`right` on relationships, `portal`/`button` on layout objects) |
| `source_valuelist` | ValueList | usage | An external wrapper in another file reuses this list |
| `restricts_object` | [PrivilegeSet](PrivilegeSet.md) | restriction | Value-list-level custom privilege restriction — never counts as usage |

## Enumerations

| Property | Values |
|---|---|
| `Source_Type` | `Custom` (custom values), `FromField` *(corpus — field-based; the XML reference also notes the spelling `Field`)*, `External` (wrapper for a list in another file; documented, not present in the test corpus) |

## Schema & tooling

- **XML schema:** [XML ValueListCatalog](../../xml/catalogs/XML%20ValueListCatalog.md) (identity + source kind) · [XML OptionsForValueLists](../../xml/catalogs/XML%20OptionsForValueLists.md) (definition details) — `Structure/AddAction` branch
- **DB schema:** [ValueListCatalog](../catalog-tables/ValueListCatalog.md) · [OptionsForValueLists](../catalog-tables/OptionsForValueLists.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_valuelist.sql`, served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=ValueList`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Field](Field.md) · [LayoutObject](LayoutObject.md) · [ExternalDataSource](ExternalDataSource.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
