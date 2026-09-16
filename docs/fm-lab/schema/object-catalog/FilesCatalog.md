# FilesCatalog

Part of the [FM-Lab schema](../Schema.md) · Object catalog · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** root attributes of the [FMSaveAsXML document](../../xml/XML.md)

Metadata of all FileMaker files imported into this solution catalog — the anchor of the multi-file support. One row per file, keyed by `File_Name` (the file name without the `.fmp12` suffix), which is also the scoping column that appears in every other catalog table.

## Columns

| Column | Type |
|---|---|
| `File_Name` | `VARCHAR` |
| `File_FullName` | `VARCHAR` |
| `File_UUID` | `VARCHAR` |
| `FileMaker_Version` | `VARCHAR` |
| `Has_DDR_INFO` | `BOOLEAN` |
| `Import_Timestamp` | `TIMESTAMP` |
| `XML_Path` | `VARCHAR` |
| `SaXML_Version` | `VARCHAR` |
| `SaXML_Profile` | `VARCHAR` |

## Notes

- `Has_DDR_INFO` records whether the export was created with the FileMaker 21+ option *Include details for analysis tools*; several tables ([DDR_Calculations](../catalog-tables/DDR_Calculations.md), [DDR_ScriptSteps](../catalog-tables/DDR_ScriptSteps.md)) are only populated when it is true.
- `FileMaker_Version` is the exporting client version string (e.g. "ProAdvanced 22.0.4").
- `SaXML_Version` is the export format version from the root attribute `version` (e.g. `2.2.3.0`, `2.3.0.0`), `SaXML_Profile` the import profile derived from it — `saxml22` for FileMaker 19–22, `saxml23` for FileMaker 26 and later (schema 1.28.0). The profile decides which version-specific extractions run for this file; a catalog may hold files of both profiles. See [the SaXML version notes](../../xml/XML.md#version-notes-saxml-v22-and-v23).

**See also:** [ObjectCatalog](ObjectCatalog.md) · [XMLMetadata](../catalog-tables/XMLMetadata.md)
