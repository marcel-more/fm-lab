# CalculationSqlRefs

Part of the [FM-Lab schema](../Schema.md) · Calculations & variables · `db/fm_catalog.duckdb` (solution catalog)
**Source:** derived at import from the formula chunks ([DDR_Calculations](DDR_Calculations.md)) and the formula text of every calculation ([CalculationsCatalog](CalculationsCatalog.md))

The references inside `ExecuteSQL` and `ExecuteSQLe` statements. `ExecuteSQL` receives its query as text; this table takes the text apart and lists every table, column and parameter of a statement with its clause and the object it points to. One row per reference; a formula can hold several statements (`Sql_Index`).

## Columns

| Column | Type |
|---|---|
| `Calculation_UUID` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `Sql_Index` | `BIGINT` |
| `Sql_Function` | `VARCHAR` |
| `Statement_Kind` | `VARCHAR` |
| `Clause` | `VARCHAR` |
| `Column_Pos` | `BIGINT` |
| `Arg_Pos` | `BIGINT` |
| `Alias` | `VARCHAR` |
| `Target_Type` | `VARCHAR` |
| `Target_UUID` | `VARCHAR` |
| `Target_File` | `VARCHAR` |
| `TO_UUID` | `VARCHAR` |
| `Resolution` | `VARCHAR` |
| `Raw_Name` | `VARCHAR` |
| `Low_Confidence` | `BOOLEAN` |
| `Token_Pos` | `BIGINT` |
| `Let_Var` | `VARCHAR` |
| `Parse_Source` | `VARCHAR` |

## Notes

- `Calculation_UUID` leads to the calculation in [CalculationsCatalog](CalculationsCatalog.md) and from there to its owner — script step, field, custom function or layout object.
- `Clause`: `select`, `from`, `join`, `on`, `where`, `group`, `having`, `order`, or `parameter` for the arguments after the separators. `Column_Pos` is the position in the select list, `Arg_Pos` the number of the argument — it fills the `?` with the same number. A statement without any SQL text of its own (the query comes from a variable set elsewhere) has a single row without clause.
- `Resolution`:
  - `reference` — a formula reference, usually inside a name function such as `GetFieldName ( TO::Field )` or a custom function built on it. In `FROM`/`JOIN` it stands for the table occurrence of the reference, elsewhere for the field. FileMaker already tracks these references. `Raw_Name` reads `TO::Field` in every clause — in `FROM`/`JOIN` the field only supplies the table name and is no data the query reads.
  - `name` — a plain name in the SQL text, quoted or not. Table names are table occurrence names of the file; column names resolve against the tables of the statement, through their alias where one is given.
  - `dynamic` — nothing in the catalog to point to: a variable, an expression or a constant as parameter, and every part of the statement built at run time — a table or column name, a value written into the SQL text (`WHERE ID IN (" & $list & ")`), the leading part of the query. `Raw_Name` holds the expression (`$list`, `Substitute ( … )`).
- `Target_Type`: `Field`, `TableOccurrence`, `SystemTable` (`FileMaker_Tables`, `FileMaker_Fields`, `FileMaker_BaseTables`, `FileMaker_BaseTableFields`), or empty when the name points to nothing. An empty target with `Low_Confidence = false` is a broken reference: the table occurrence or field is gone or was renamed, or FileMaker marks it as `<Field Missing>`.
- `Low_Confidence` marks names whose table cannot be determined (dynamic table name, ambiguous column) and statements whose formula chunks are incomplete in the export.
- `Let_Var` names the Let variable that carried the SQL text, when the query is built in a Let of the same formula.
- `Parse_Source`: `ddr` when the formula chunks were read, `text` when the formula text was — in files without DDR info, and where the export dropped a chunk (FileMaker omits the last code chunk before a closing comment).
- **Links:** a field named as plain text (`Resolution = name`) gets a `reads_field` link from the owner of the formula, like every other field the formula reads — fields used only in SQL text no longer look unused. The origin "from SQL text" is recorded only in this table. Table occurrences in `FROM`/`JOIN` count as usage of the table occurrence.
- Not covered: the MBS SQL functions and SQL text assembled in another script step.

**See also:** [CalculationsCatalog](CalculationsCatalog.md) · [DDR_Calculations](DDR_Calculations.md) · [TableOccurrenceCatalog](TableOccurrenceCatalog.md) · [FieldsForTables](FieldsForTables.md)
