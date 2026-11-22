# StepCalculations

Part of the [FM-Lab schema](../Schema.md) · Scripts & script steps · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** derived in phase P3 from the persisted `Step_XML` fragments of [XML StepsForScripts](../../xml/catalogs/XML%20StepsForScripts.md)

One row per **positioned calculation** of a script step, with its slot context. [StepsForScripts](StepsForScripts.md)`.Calculation_Text` carries only the *first* calculation of a step in document order — but many step types carry several (Set Variable: value + repetition; New Window: name + four geometry slots; Insert from URL: URL + cURL options; Show Custom Dialog: title + message + input defaults). This table resolves every `<Calculation @position>` into its own row, so "window name vs. window height" or "dialog title vs. dialog message" become distinguishable.

## Columns

| Column | Type |
|---|---|
| `Step_UUID` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `Script_UUID` | `VARCHAR` |
| `Script_Name` | `VARCHAR` |
| `Script_ID` | `BIGINT` |
| `Step_Index` | `BIGINT` |
| `Step_ID` | `BIGINT` |
| `Step_Name` | `VARCHAR` |
| `Is_Enabled` | `BOOLEAN` |
| `Slot` | `VARCHAR` |
| `Calc_Position` | `BIGINT` |
| `Slot_Seq` | `BIGINT` |
| `Calc_Text` | `VARCHAR` |

## Notes

- **`Slot`** is the parent element of the calculation wrapper (`Name`, `height`, `URL`, `Title`, `value`, `repetition`, …); when the wrapper sits directly under a `<Parameter>`, the slot reads `Parameter:<type>`. `SQL` is the *calculated SQL text* of Execute SQL; it has no position (`Calc_Position` empty). The plain *SQL text* input of that step is sent to the ODBC source as typed and is not a calculation, so it has no row.
- **`Calc_Position`** is the `@position` attribute. It is **not step-unique** — FileMaker restarts numbering in some parameter containers (Data-File steps); uniqueness needs `Slot` + `Slot_Seq` on top.
- **`Slot_Seq`** is the 1-based ordinal *within one slot parent* (e.g. the argument list of Perform JavaScript in Web Viewer — several calculations under a single `<Parameter type="Parameter">`).
- Plain-text layer, no hash column — the rows exist with and without DDR-Info.
- Since schema 1.22.0, [CalculationsCatalog](CalculationsCatalog.md) promotes these rows to addressable `Calculation` objects (`Calc_Role = 'step_parameter'`); the DDR anchor suffix of a step calculation equals its `Calc_Position`, which is the bridge that attaches the formula hash to the instance.

**See also:** [StepsForScripts](StepsForScripts.md) · [CalculationsCatalog](CalculationsCatalog.md) · [DDR_Calculations](DDR_Calculations.md)
