# FieldDisplayNames

Part of the [FM-Lab schema](../Schema.md) · Data model · `db/fm_catalog.duckdb` (solution catalog)
**Source:** derived during import (pipeline phase 3) by parsing [FieldsForTables](FieldsForTables.md) `DisplayNames_Calc_Text` — not a branch of the XML export
**Since:** catalog schema 1.29.0 · **SaXML v2.3.0.0 only** (FileMaker 26 and later)

The elements of a field's **customized display names** — FileMaker 26's *Display Names* dialog, where a field can carry a different label per context (the form view, an export, a sort dialog, the table view). One row per element.

FileMaker stores the whole dialog as a single calculation, not as structured data:

```
JSONSetElement ( "{}" ;
    [ "fm_common"     ; "Common"          ; JSONString ] ;
    [ "fm_export"     ; Upper ( Text2 )   ; JSONString ] ;
    [ "fm_sort"       ; "Sort"            ; JSONString ] ;
    [ "fm_table_view" ; "Table View"      ; JSONString ]
)
```

This table is that formula taken apart, so a label can be read, listed and searched without re-parsing the formula at every call site. The formula itself stays in `FieldsForTables.DisplayNames_Calc_Text`, and its references run through the `display_names` calculation instance in [CalculationsCatalog](CalculationsCatalog.md) — this table is **owner inventory only** and carries no where-used edges of its own.

## Columns

| Column | Type |
|---|---|
| `Field_UUID` | `VARCHAR` |
| `File_Name` | `VARCHAR` |
| `Element_Seq` | `BIGINT` |
| `Element_Key` | `VARCHAR` |
| `Value_Text` | `VARCHAR` |
| `Value_Kind` | `VARCHAR` |
| `Json_Type` | `VARCHAR` |

## Notes

- `Element_Key` is the context key FileMaker writes — `fm_common`, `fm_export`, `fm_sort`, `fm_table_view`. The dialog offers those four; the parser does not restrict the set, so a hand-written formula with other keys is inventoried as it stands.
- `Value_Kind` decides how `Value_Text` reads: `literal` is a label the user typed (stored as a string literal and unquoted here), `formula` is an expression that is evaluated at display time — `Value_Text` then holds its raw text. A user interface that lists display names should mark the formula case (the web client prefixes it with "ƒ").
- `Element_Seq` is the 1-based position in the formula, which is the order the elements were written in — not a priority.
- **Only the canonical form is parsed.** The extraction recognizes `JSONSetElement` elements of the shape `[ "<key>" ; <label or formula> ; JSON<type> ]` without nested brackets — exactly what the dialog produces. A field whose display-names formula was written freehand into something else yields **no rows**; the formula is still there, and the detail view falls back to showing it raw. Absence of rows is therefore not absence of display names.
- The table exists only for files imported under the `saxml23` profile: SaXML v2.2.x has no `DisplayNames` element at all, so `DisplayNames_Calc_Text` is `NULL` and nothing is parsed. See [the SaXML version notes](../../xml/XML.md#version-notes-saxml-v22-and-v23).
- A **disabled** display-names definition is still exported by FileMaker 26 and still parsed here; whether it is active is `FieldsForTables.Field_DisplayNames_Enabled`.

```sql
-- Every customized display name of the solution, with its field
SELECT f.File_Name, f.Table_Name, f.Field_Name,
       d.Element_Key, d.Value_Kind, d.Value_Text
FROM FieldDisplayNames d
JOIN FieldsForTables f
  ON f.Field_UUID = d.Field_UUID AND f.File_Name = d.File_Name
ORDER BY f.File_Name, f.Table_Name, f.Field_Name, d.Element_Seq;
```

**See also:** [FieldsForTables](FieldsForTables.md) · [CalculationsCatalog](CalculationsCatalog.md) · [XML FieldsForTables](../../xml/catalogs/XML%20FieldsForTables.md)
