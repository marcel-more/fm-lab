# FieldsForTables

Part of the [FM-Lab schema](../Schema.md) · Data model · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML FieldsForTables](../../xml/catalogs/XML%20FieldsForTables.md)

All fields of all base tables, with the complete field definition: data type, storage and indexing options, the full auto-enter block (serial numbers, lookups, calculated values, constant data), the validation block (including validate-by-calculation and custom messages) and summary-field definitions. With 57 columns this is the widest type-specific table in the catalog.

## Columns

| Column | Type |
|---|---|
| `Table_ID` | `BIGINT` |
| `Table_Name` | `VARCHAR` |
| `Table_UUID` | `VARCHAR` |
| `Field_ID` | `BIGINT` |
| `Field_Name` | `VARCHAR` |
| `Field_Type` | `VARCHAR` |
| `Data_Type` | `VARCHAR` |
| `Field_Comment` | `VARCHAR` |
| `Field_UUID` | `VARCHAR` |
| `Is_Global` | `BOOLEAN` |
| `Max_Repetitions` | `BIGINT` |
| `DDR_Hash` | `VARCHAR` |
| `Calculation_Text` | `VARCHAR` |
| `AutoEnter_Type` | `VARCHAR` |
| `AutoEnter_ProhibitMod` | `BOOLEAN` |
| `Lookup_Field_Name` | `VARCHAR` |
| `Lookup_Field_UUID` | `VARCHAR` |
| `Lookup_TO_Name` | `VARCHAR` |
| `Lookup_TO_UUID` | `VARCHAR` |
| `Lookup_DontCopyIfEmpty` | `BOOLEAN` |
| `Lookup_NoMatchOption` | `VARCHAR` |
| `AE_Calc_Text` | `VARCHAR` |
| `AE_Calc_Hash` | `VARCHAR` |
| `AE_Calc_OverwriteExisting` | `BOOLEAN` |
| `AE_Calc_AlwaysEvaluate` | `BOOLEAN` |
| `AE_ConstantData` | `VARCHAR` |
| `Validation_Type` | `VARCHAR` |
| `Validation_AllowOverride` | `BOOLEAN` |
| `Validation_NotEmpty` | `BOOLEAN` |
| `Validation_Unique` | `BOOLEAN` |
| `Validation_Existing` | `BOOLEAN` |
| `Validation_VL_ID` | `BIGINT` |
| `Validation_VL_Name` | `VARCHAR` |
| `Validation_VL_UUID` | `VARCHAR` |
| `Storage_AutoIndex` | `BOOLEAN` |
| `Storage_Index` | `VARCHAR` |
| `Storage_StoreCalcResults` | `BOOLEAN` |
| `Serial_Increment` | `VARCHAR` |
| `Serial_NextValue` | `VARCHAR` |
| `Serial_Generate` | `VARCHAR` |
| `Summary_Operation` | `VARCHAR` |
| `Summary_Field_Name` | `VARCHAR` |
| `Summary_Field_UUID` | `VARCHAR` |
| `Validation_AlwaysValidate` | `BOOLEAN` |
| `Validation_StrictType` | `VARCHAR` |
| `Validation_MaxChars` | `BIGINT` |
| `Validation_Range_From` | `VARCHAR` |
| `Validation_Range_To` | `VARCHAR` |
| `Validation_Calc_Text` | `VARCHAR` |
| `Validation_Calc_Hash` | `VARCHAR` |
| `Validation_Message` | `VARCHAR` |
| `Validation_Message_Calc_Hash` | `VARCHAR` |
| `Storage_IndexLanguage` | `VARCHAR` |
| `Storage_IndexLanguage_ID` | `BIGINT` |
| `Summary_RestartEachGroup` | `BOOLEAN` |
| `Summary_RepetitionMode` | `VARCHAR` |
| `Field_Annotation` | `VARCHAR` |
| `Field_DisplayNames_Enabled` | `BOOLEAN` |
| `DisplayNames_Calc_Text` | `VARCHAR` |
| `DisplayNames_Calc_Hash` | `VARCHAR` |
| `AE_Calc_Enabled` | `BOOLEAN` |
| `Lookup_Enabled` | `BOOLEAN` |
| `Validation_Calc_Enabled` | `BOOLEAN` |
| `Validation_Message_Calc_Enabled` | `BOOLEAN` |
| `Lookup_Context_TO_ID` | `BIGINT` |
| `Lookup_Context_TO_Name` | `VARCHAR` |
| `Lookup_Context_TO_UUID` | `VARCHAR` |
| `Modified_At` | `VARCHAR` |
| `Modified_By` | `VARCHAR` |
| `Modified_Account` | `VARCHAR` |
| `Modifications` | `BIGINT` |
| `File_Name` | `VARCHAR` |

## Notes

- `Calculation_Text`/`DDR_Hash` belong to true Calculated fields (`Field_Type='Calculated'`); `AE_Calc_Text`/`AE_Calc_Hash` belong to Normal fields with an auto-enter calculation. A field never has both populated.
- Lookup fields carry their source field and relationship in the `Lookup_*` columns (→ `lookup_source` / `lookup_relationship` links). `Lookup_Context_TO_*` is the occurrence the lookup starts from ("Starting with table"); FileMaker walks the relationship graph from there to `Lookup_TO_*` (→ `lookup_context` link, since schema 1.38.0).
- Validation by value list is captured in `Validation_VL_*` (→ `uses_valuelist` link with subrole `validation`); validation by calculation in `Validation_Calc_*` (→ `validates_by_calc` link).
- `Validation_MaxChars` is sentinel-normalized at import: FileMaker serializes "no character limit" as `4294967295` (UINT32_MAX, the unsigned form of an internal `-1`); the importer stores it as `NULL` — the same state as validation without a configured maximum. Real limits import verbatim. A guard check (`v_check_numeric_sentinels`) warns if a future export ships an unrecognized implausible value (> 10⁹) instead.
- Summary fields describe their operation and target in the `Summary_*` columns (→ `summarizes_field` link).
- `DDR_Hash`-family columns join to [DDR_Calculations](DDR_Calculations.md) via `Calc_Hash`.
- `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` are the raw change metadata of the object's `<UUID>` element: timestamp as text (local time of the editing client, no time zone), user name, account (empty → `NULL`) and change counter. [ObjectChangeMeta](ObjectChangeMeta.md) collects them across all object types with a typed timestamp.
- The per-table field catalog carries a stamp of its own (deleting a field updates it); it is in [CatalogChangeMeta](CatalogChangeMeta.md) with `Catalog = 'FieldCatalog'` and the base table in `Scope_UUID`.

**See also:** [BaseTableCatalog](BaseTableCatalog.md) · [DDR_Calculations](DDR_Calculations.md) · [ValueListCatalog](ValueListCatalog.md)
