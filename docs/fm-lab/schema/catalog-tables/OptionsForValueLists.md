# OptionsForValueLists

Part of the [FM-Lab schema](../Schema.md) · Value lists · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML OptionsForValueLists](../../xml/catalogs/XML%20OptionsForValueLists.md)

The definition details of every value list, one row per list: the literal custom values as an array, the source field and table occurrence for field-based lists (including the optional second field and sort options), and the external source columns for value lists that wrap a list from another file.

## Columns

| Column | Type |
|---|---|
| `VL_ID` | `BIGINT` |
| `VL_Name` | `VARCHAR` |
| `VL_UUID` | `VARCHAR` |
| `Source_Type` | `VARCHAR` |
| `Custom_Values` | `VARCHAR[]` |
| `Field_ID` | `BIGINT` |
| `Field_Name` | `VARCHAR` |
| `Field_UUID` | `VARCHAR` |
| `TO_ID` | `BIGINT` |
| `TO_Name` | `VARCHAR` |
| `TO_UUID` | `VARCHAR` |
| `Field_Sort` | `BOOLEAN` |
| `Secondary_Field_ID` | `BIGINT` |
| `Secondary_Field_Name` | `VARCHAR` |
| `Secondary_Field_UUID` | `VARCHAR` |
| `Secondary_TO_ID` | `BIGINT` |
| `Secondary_TO_Name` | `VARCHAR` |
| `Secondary_TO_UUID` | `VARCHAR` |
| `Secondary_Sort` | `BOOLEAN` |
| `External_DS_ID` | `BIGINT` |
| `External_DS_Name` | `VARCHAR` |
| `External_DS_UUID` | `VARCHAR` |
| `External_VL_ID` | `BIGINT` |
| `External_VL_Name` | `VARCHAR` |
| `ShowRelated` | `BOOLEAN` |
| `ShowRelated_TO_ID` | `BIGINT` |
| `ShowRelated_TO_Name` | `VARCHAR` |
| `ShowRelated_TO_UUID` | `VARCHAR` |
| `File_Name` | `VARCHAR` |

## Notes

- Field-based lists produce `source_field`/`source_table` graph links.
- `ShowRelated = true` is the option "Include only related values starting from": `ShowRelated_TO_*` is the occurrence FileMaker starts from and walks the relationship graph to the source occurrence `TO_*` (→ `related_values_from` link, since schema 1.38.0). With "all values" the columns stay empty.
- External wrappers (`Source_Type='External'`) carry `External_DS_*` (the data source) and `External_VL_*` (the target list). The target UUID is absent in the XML; the import resolves it via data source + list ID and links it as `source_valuelist`.

**See also:** [ValueListCatalog](ValueListCatalog.md) · [ExternalDataSourceCatalog](ExternalDataSourceCatalog.md)
