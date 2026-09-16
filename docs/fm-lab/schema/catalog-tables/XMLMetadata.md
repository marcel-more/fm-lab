# XMLMetadata

Part of the [FM-Lab schema](../Schema.md) · File level · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** root attributes of the [FMSaveAsXML document](../../xml/XML.md)

The root attributes of each imported XML export: SaXML format version, exporting FileMaker version, source file name and UUID, export locale, the DDR-Info flag and the import profile derived from the format version. One row per imported file — the low-level counterpart of [FilesCatalog](../object-catalog/FilesCatalog.md).

## Columns

| Column | Type |
|---|---|
| `Has_DDR_INFO` | `VARCHAR` |
| `XML_Version` | `VARCHAR` |
| `FileMaker_Version` | `VARCHAR` |
| `Filename` | `VARCHAR` |
| `File_UUID` | `VARCHAR` |
| `Locale` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `SaXML_Profile` | `VARCHAR` |

## Notes

- `Has_DDR_INFO = 'True'` gates the population of [DDR_ScriptSteps](DDR_ScriptSteps.md) and [DDR_Calculations](DDR_Calculations.md).
- `XML_Version` is the raw root attribute `version`; `SaXML_Profile` is the import profile derived from it — `saxml22` (FileMaker 19–22) or `saxml23` (FileMaker 26 and later), schema 1.28.0. It governs which version-specific extractions run for the file; see [the SaXML version notes](../../xml/XML.md#version-notes-saxml-v22-and-v23).
- `Locale` documents the export language — the reason step and object names are localized and analyses must key on numeric IDs.

**See also:** [FilesCatalog](../object-catalog/FilesCatalog.md) · [DDR_Calculations](DDR_Calculations.md)
