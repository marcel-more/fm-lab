# LayoutParts

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md)

The parts (sections) of every layout — header, body, footer, sub-summaries and so on — one row per part, ordered by `Part_Seq`. Because parts are sequenced rather than keyed by type, multiple sub-summary parts of the same kind stay distinct.

## Columns

| Column | Type |
|---|---|
| `Layout_ID` | `BIGINT` |
| `Layout_Name` | `VARCHAR` |
| `Part_Seq` | `BIGINT` |
| `Part_Type` | `VARCHAR` |
| `Part_Kind` | `BIGINT` |
| `Definition_Type` | `VARCHAR` |
| `Definition_Kind` | `BIGINT` |
| `Part_Size` | `BIGINT` |
| `Part_Absolute` | `BIGINT` |
| `Part_Options` | `BIGINT` |
| `Object_Count` | `BIGINT` |
| `Break_Field_ID` | `BIGINT` |
| `Break_Field_Name` | `VARCHAR` |
| `Break_Field_UUID` | `VARCHAR` |
| `Break_TO_Name` | `VARCHAR` |
| `Break_TO_UUID` | `VARCHAR` |
| `Part_Name` | `VARCHAR` |
| `Part_Break_Every` | `BIGINT` |
| `Part_LocalCSS_Name` | `VARCHAR` |
| `Part_LocalCSS_Type` | `VARCHAR` |
| `Part_LocalCSS` | `VARCHAR` |
| `Part_Alt_Row_Local` | `BOOLEAN` |
| `Part_Active_Row_Local` | `BOOLEAN` |
| `File_Name` | `VARCHAR` |

## Notes

- `Part_Type` is canonical English and follows `Part_Kind`: localized type names are mapped at import, and kind 5 is always `Trailing Sub-summary` — FileMaker 22 and older export it as `Trailing Grand Summary`. The raw type stays in `Definition_Type`.
- Sub-summary parts name their break field in the `Break_Field_*`/`Break_TO_*` columns (→ `breaks_on_field` link — a real field usage). Some existing files reference the break field through another table occurrence with a UUID that is in no catalog; the import then resolves the field through `Break_TO_UUID` and `Break_Field_ID`, so the link exists for these parts too.
- `Part_Name` is the name FileMaker generates for sub-summaries (`Sub-summary by Text1 (Leading)`), `NULL` for every other kind.
- **Part definition options.** `Part_Options` packs five options of FileMaker's *Part Definition* dialog as bits: bit 0 *page break before each occurrence*, bit 1 *page break after every n occurrences* (n in `Part_Break_Every`, present only when the option is set), bit 2 *restart page numbers after each occurrence*, bit 6 *allow part to break across page boundaries*, bit 8 *discard remainder of part before new page* (only together with bit 6). Bits 7 and 10 occur in older files and are no dialog options.
- **Row state.** *Use alternate row state* and *Use active row state* are CSS properties, not bits. `Part_Alt_Row_Local` / `Part_Active_Row_Local` hold the value set on the part itself (body parts only, `NULL` = not set there). The effective value follows a cascade: the part's own value, then its part style (`Part_LocalCSS_Name`), then the theme's body rule — both in [ThemePartStyles](ThemePartStyles.md) —, otherwise off. Classic themes set neither. FileMaker 22 writes the part's local CSS without `@type`, so a part style is recognized by `Part_LocalCSS_Name`.
- `Object_Count` gives a quick size measure per part without touching [LayoutObjects](LayoutObjects.md) (root objects only); the objects of a part across all nesting levels are the rows of [LayoutObjects](LayoutObjects.md) with the same `Part_Seq`.

**See also:** [Layouts](Layouts.md) · [LayoutObjects](LayoutObjects.md) · [ThemePartStyles](ThemePartStyles.md) · [LayoutPart](../object-types/LayoutPart.md) · [FieldsForTables](FieldsForTables.md)
