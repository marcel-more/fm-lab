# LayoutObjectFontRuns

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md) — `CharacterStyle` of formatted text, font elements of charts

Fonts that a layout object stores as XML elements instead of CSS: formatted parts of a text (`rich_text`) and the fixed font of every text area of a chart (`chart`).

## Columns

| Column | Type |
|---|---|
| `Object_UUID` | `VARCHAR` |
| `Layout_ID` | `BIGINT` |
| `File_Name` | `VARCHAR` |
| `Object_Type` | `VARCHAR` |
| `Source` | `VARCHAR` |
| `Slot` | `VARCHAR` |
| `Slot_Index` | `INTEGER` |
| `Run_Start` | `BIGINT` |
| `Run_End` | `BIGINT` |
| `Run_Text` | `VARCHAR` |
| `Font_Family` | `VARCHAR` |
| `Font_PostScript` | `VARCHAR` |
| `Font_Size` | `DOUBLE` |
| `Face` | `BIGINT` |
| `Style_Mask` | `BIGINT` |

## Notes

- **rich_text:** a part of a text or button label formatted with the text cursor. `Run_Start`/`Run_End` are character positions, `Run_End = 4294967295` means "to the end". `Style_Mask` tells what the run sets: 1 family, 2 size, 16 face. A run that only changes size or face has no `Font_Family`.
- FileMaker stores a format applied to the whole text as local CSS ([LayoutObjectStyles](LayoutObjectStyles.md)), not as a run. Runs are always partial — the object's base font still comes from its style and theme.
- **chart:** one row per text area, `Slot` = `title`, `series_x_title` … `series_z_title`, `legend`, `x_axis_title`, `x_axis_label`, `y_axis_title`, `y_axis_label`, `data_label`. The chart dialog's standard font goes into title, legend, axes and data labels; series titles keep the theme font.
- Only the object's own elements count — a group never reports the runs of the texts inside it.

**See also:** [LayoutObjects](LayoutObjects.md) · [LayoutObjectStyles](LayoutObjectStyles.md)
