# DDR_Calculations

Part of the [FM-Lab schema](../Schema.md) · Calculations & variables · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md)

Formula chunks for dependency analysis, only populated for files exported with DDR-Info. Every calculation (field calc, auto-enter calc, custom function body, script-step expression, record-access calc, …) is stored as an ordered sequence of typed chunks: plain text interleaved with typed references such as `FieldRef`, `CustomFunctionRef`, `VariableReference` or plugin-function references. The import pipeline resolves these chunks into [ObjectLinks](../object-catalog/ObjectLinks.md) edges.

## Columns

| Column | Type |
|---|---|
| `Calc_UUID` | `VARCHAR` |
| `Calc_Hash` | `VARCHAR` |
| `Chunk_Index` | `BIGINT` |
| `Chunk_Type` | `VARCHAR` |
| `Chunk_Content` | `VARCHAR` |
| `File_Name` | `VARCHAR` |

## Notes

- `Calc_Hash` identifies a calculation; `FieldsForTables.DDR_Hash`, `CustomFunctionsCatalog.DDR_Hash` and other `*_Hash` columns join against it.
- `Chunk_Index` preserves the token order, `Chunk_Type` the token class, `Chunk_Content` the literal content.
- `Chunk_Type` is canonicalized once after extraction (pipeline phase 1c): FileMaker's export tags its **design functions** (`WindowNames`, `DatabaseNames`, `LayoutIDs`, `ValueListItems`, …) as `PluginFunctionRef` — the chunk type otherwise used for plug-in calls — in the language of the client that wrote the formula (`Fensternamen`, `WindowNames`). The importer re-types those chunks to `FunctionRef` by a positive name match against [DesignFunctionNames](DesignFunctionNames.md) (the `type` attribute inside `Chunk_Content` is rewritten as well, the token text stays as exported), so they resolve as `BuiltinFunction` targets of `calls_function`. Genuine plug-in references and unresolvable identifiers keep their type.
- Since schema 1.22.0 every DDR anchor has a catalog object: `Calc_UUID` (the `_<OwnerUUID>_<Suffix>` anchor) is `CalculationsCatalog.DDR_Calc_UUID` — analyses should address calculation *instances* through [CalculationsCatalog](CalculationsCatalog.md) and use this table only for the chunk-level token detail.

**See also:** [CalculationsCatalog](CalculationsCatalog.md) · [FieldsForTables](FieldsForTables.md) · [CustomFunctionsCatalog](CustomFunctionsCatalog.md) · [VariableUsages](VariableUsages.md)
