# LayoutTableViewColumns

Part of the [FM-Lab schema](../Schema.md) · Layouts · `db/fm_catalog.duckdb` (solution catalog)
**XML source:** `Layout/TableView/ObjectList/TableViewLayoutObject` — see [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md)
**Since:** catalog schema 1.28.0 · **SaXML v2.3.0.0 only** (FileMaker 26 and later)

The **columns of a layout's table view**: which fields the layout shows when the user switches to *View as Table*, in which order, at which width, and which of them are hidden. One row per (layout, column).

Until FileMaker 26 this configuration was simply not in the export — SaXML v2.2.x writes no `<TableView>` element at all — so a field used *only* as a table-view column was invisible to every dependency analysis. For a file imported under the `saxml22` profile the table therefore stays **empty**; that is the absence of the source data, not a missing field in the solution. See [the SaXML version notes](../../xml/XML.md#version-notes-saxml-v22-and-v23).

## Columns

| Column | Type |
|---|---|
| `L_ID` | `BIGINT` |
| `L_Name` | `VARCHAR` |
| `L_UUID` | `VARCHAR` |
| `Column_Seq` | `BIGINT` |
| `Column_ID` | `BIGINT` |
| `Column_Name` | `VARCHAR` |
| `Is_Hidden` | `BOOLEAN` |
| `Column_Width` | `BIGINT` |
| `Field_ID` | `BIGINT` |
| `Field_Name` | `VARCHAR` |
| `Field_UUID` | `VARCHAR` |
| `Field_Repetition` | `BIGINT` |
| `TO_ID` | `BIGINT` |
| `TO_Name` | `VARCHAR` |
| `TO_UUID` | `VARCHAR` |
| `File_Name` | `VARCHAR` |

## Notes

- The primary key is `(L_UUID, Column_Seq, File_Name)`. `Column_Seq` is **1-based** and is the column order as the user sees it; `Column_ID` is FileMaker's internal `TableViewLayoutObject@id` and does not carry the order.
- **A table-view column is not a [layout object](LayoutObjects.md).** It has no bounds and no UUID of its own, which is why it lives in its own detail table instead of in `LayoutObjects` — and why it does not appear in the layout-object graph or in any object-type filter.
- `Field_UUID` can be `NULL` for a field of an **external** table occurrence. Such a row is kept (the column exists and is visible to the user) but produces no link — the phase-6 check `v_check_table_view_columns` reports the count.
- `Is_Hidden` marks a column FileMaker keeps in the configuration but does not display. A hidden column still resolves its field and still produces a usage link: the reference exists in the file.
- `Column_Width` is in pixels, `Field_Repetition` names the shown repetition of a repeating field (`1` for a plain field).
- `L_UUID` is healed in the [Layouts](Layouts.md) namespace — a layout without a UUID in the export gets the same substitute UUID here as in `Layouts`, so the join never breaks.

## Where-used

Every resolvable column yields an edge **Layout → Field** with role `displays_field` and subrole `table_view_column` in [ObjectLinks](../object-catalog/ObjectLinks.md). The role is the same one the aggregated layout edge uses, so a where-used query on a field finds table-view usage without any special case; the subrole discriminates the source.

```sql
-- Which fields does a layout show only in its table view, nowhere else on it?
SELECT tv.L_Name, tv.Field_Name, tv.TO_Name, tv.Column_Seq
FROM LayoutTableViewColumns tv
WHERE tv.Field_UUID IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM ObjectLinks ol
        WHERE ol.Source_UUID  = tv.L_UUID
          AND ol.Target_UUID  = tv.Field_UUID
          AND ol.Link_Role    = 'displays_field'
          AND ol.Link_Subrole IS DISTINCT FROM 'table_view_column')
ORDER BY tv.L_Name, tv.Column_Seq;
```

**See also:** [Layouts](Layouts.md) · [LayoutObjects](LayoutObjects.md) · [FieldsForTables](FieldsForTables.md) · [ObjectLinks](../object-catalog/ObjectLinks.md) · [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md)
