# ImportStepSources

Part of the [FM-Lab schema](../Schema.md) · Scripts & script steps · `db/fm_catalog.duckdb` (solution catalog)
**Source:** derived at import from the data source of every *Import Records* step ([StepsForScripts](StepsForScripts.md), `Parameters_XML`)

Where an *Import Records* step takes its data from. One row per step that names a data source — its kind, the path list or formula as written, the XSL of an XML import, and for a FileMaker source the file of the solution the path points to. The target fields of the import are not repeated here: they are the step's `imports_to_field` links (see `v_script_step_links`).

## Columns

| Column | Type |
|---|---|
| `Step_UUID` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `Script_UUID` | `VARCHAR` |
| `Step_Index` | `INTEGER` |
| `Source_Kind` | `VARCHAR` |
| `File_Type_Code` | `VARCHAR` |
| `Source_Value` | `VARCHAR` |
| `Source_Location` | `VARCHAR` |
| `Source_Formula` | `VARCHAR` |
| `XSL_Location` | `VARCHAR` |
| `XSL_Formula` | `VARCHAR` |
| `Source_File` | `VARCHAR` |

## Notes

- `Source_Kind`: `filemaker`, `tab`, `csv`, `merge`, `xml`, or `unspecified` when the step names no source (the dialog asks at run time); other kinds appear as their lowercased file-type code. `File_Type_Code` keeps the raw code of the export (`FMPR`, `TABS`, `COMS`, `MRGE`, `XML`).
- `Source_Location` holds the path list as written, one path per line; `Source_Formula` the calculation when the source is given as one. The same pair exists for the stylesheet of an XML import (`XSL_Location`, `XSL_Formula`).
- `Source_File` is set only for a FileMaker source whose path list names a file of the solution: protocol prefix (`file:`, `filemac:`, …), folders and the `.fmp12` extension are removed, the comparison ignores case, and the first matching path wins — the same rule as for external data sources. A path in a variable or a file outside the solution stays empty. With it, a data path can be followed from one file of the solution into another.
- `Step_Index` is 0-based; FileMaker counts steps from 1. A step is identified by `Step_UUID` together with `File_Name` — copies of the same file share step UUIDs.
- Read once at import; nothing parses the step XML at run time.

**See also:** [StepsForScripts](StepsForScripts.md) · [ScriptCatalog](ScriptCatalog.md) · [ExternalDataSourceCatalog](ExternalDataSourceCatalog.md)
