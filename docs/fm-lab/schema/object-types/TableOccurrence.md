# TableOccurrence

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **table occurrence** is a node on the relationship graph — a named instance of a [base table](BaseTable.md) (local, or in another file via an [external data source](ExternalDataSource.md)). Occurrences are FileMaker's unit of *context*: layouts, relationship sides, portals, Go-to-Related-Record steps, lookups and field-based value lists all bind to an occurrence, never to the base table directly. One base table can appear on the graph any number of times under different names, each spanning its own join paths.

Beyond the semantic reference, each occurrence carries the **visual state of its node on the graph canvas** — position rectangle, node color, collapsed/expanded view — so the developer's spatial organization of the graph survives the import and stays analyzable.

TableOccurrence is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'TableOccurrence'` mirrors one `<TableOccurrence>` element of the export, with the detail row in [TableOccurrenceCatalog](../catalog-tables/TableOccurrenceCatalog.md).

## Properties

Properties marked **not extracted** are visible in the raw XML only.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `TO_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `TO_Name` | Unique across the file's graph |
| `@type` | `TO_Type` | `Local` / `External` — see [Enumerations](#enumerations) |
| `@View` | `View_State` | Collapse state of the node on the canvas |
| `@height` | `Box_Height` | Height of the node box |
| `<UUID>` (text) | `TO_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<BaseTableSourceReference>/@type` | — | Discriminator of the source wrapper; `BaseTableReference` / `ExternalDataSourceReference` *(fixture)* — redundant with `@type`, **not extracted** |
| `<BaseTableReference>` `@id` / `@name` / `@UUID` | `BT_ID` / `BT_Name` / `BT_UUID` | The represented base table → `base_table` link |
| Data-source reference (external occurrences) | `DS_ID` / `DS_Name` / `DS_UUID` | The external data source plus remote table → `data_source` link; in the test fixture the external occurrence's wrapper is empty |
| `<CoordRect>` `@top` / `@left` / `@bottom` / `@right` | `Coord_Top` / `Coord_Left` / `Coord_Bottom` / `Coord_Right` | Position rectangle on the graph canvas |
| `<Color>` `@red` / `@green` / `@blue` / `@alpha` | `Color_R` / `Color_G` / `Color_B` / `Color_Alpha` | Node color |
| `<TagList>` | — | Object tags — **not extracted** |
| `<SourceUUID>` | — | Observed in the test fixtures on a SaXML-delivered occurrence only; undocumented — **not extracted** |
| `<TableOccurrenceNotes>` (catalog-level) | — | Free-floating text annotations on the graph canvas, encoded as layout objects — **not extracted** |

## References

Occurrences sit at the hub of the context model: they point down to their base table (and, for external occurrences, their data source), while layouts, relationships, lookups, GTRR steps, portals and value lists all point at them. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (TableOccurrence as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `base_table` | [BaseTable](BaseTable.md) | usage | The base table the occurrence represents |
| `data_source` | [ExternalDataSource](ExternalDataSource.md) | usage | External occurrence sources its table from this data source |

### Incoming links (TableOccurrence as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `context_table` | [Layout](Layout.md) | usage | The layout's context table occurrence |
| `left_table` / `right_table` | [Relationship](Relationship.md) | usage | The occurrence is a side of the relationship |
| `lookup_context` | [Field](Field.md) | usage | The lookup starts from this occurrence ("Starting with table") |
| `lookup_relationship` | [Field](Field.md) | usage | A lookup resolves through this occurrence |
| `navigates_to_to` | [Script](Script.md) / [LayoutObject](LayoutObject.md) | usage | Go to Related Record targets the occurrence |
| `portal_context` | [LayoutObject](LayoutObject.md) | usage | The portal's data-source occurrence |
| `related_values_from` | [ValueList](ValueList.md) | usage | "Include only related values starting from" this occurrence |
| `source_table` | [ValueList](ValueList.md) | usage | Field-based value list sources from this occurrence |

### Usage through fields

Most uses of an occurrence never reach it as a link: a `Table::Field` reference in a formula, a script step or a field on a layout links to the **field**, not to the occurrence. The links above therefore show only part of the picture. The analysis table `v_table_occurrence_usage` collects every usage of an occurrence — the links, plus field references in formulas, script steps, layout fields, table-view columns, sub-summary break fields, record-access formulas of privilege sets and the evaluation context of field formulas — one row per occurrence, using object, category and role. `v_table_occurrence_class` derives one usage class per occurrence from it and from the relationship graph:

| `Usage_Class` | Meaning |
|---|---|
| `used` | At least one usage beyond relationship sides |
| `relationship_bridge` | No own usage, but it lies on the relationship path between two used occurrences (e.g. the join occurrence of a many-to-many relationship), or it is a side of a relationship with cascade delete — needed |
| `dead_branch` | Only a relationship side; no used occurrence lies beyond it — `Anchor_TO_Name` names the used occurrence it hangs on, `Dead_Group_ID` the subtree that is removed together |
| `dead_island` | Part of a relationship group in which no occurrence is used |
| `unused` | No usage and no relationship |

Formula references need DDR info in the export. In files without it the formula text is searched for `Table::` instead (category `calculation_text`); such files carry `Low_Confidence = true`, and their `unused`/`dead_*` classes are unverified. Dynamic references (`GetField`, `Evaluate`, names inside `ExecuteSQL` strings) stay invisible.

The usage feeds the general usage number of fm-lab ([Usage and References](../Usage%20and%20References.md)) and shows up in four places: the detail view of the occurrence (usage class and counts per category, see [Detail view](#detail-view)), the references tab of the occurrence in the web frontend (role `uses_table_occurrence`, grouped by category), the dashboard *Table Occurrence Usage* (rubric Schema) and the rule *Unused Table Occurrence* ([SCA Unused Code](../../sca/SCA%20Unused%20Code.md)). Both tables exist since schema 1.38.0; older catalogs need a re-import.

## Enumerations

Values marked *(corpus)* are the literals observed in the ooe-fm test corpus; the XML literal set beyond them is not independently documented.

| Property | Values |
|---|---|
| `TO_Type` | `Local`, `External` *(corpus)* |
| `View_State` | `Full` *(corpus)* — the collapsed/reduced node states of the graph canvas were not observed |

## Schema & tooling

- **XML schema:** [XML TableOccurrenceCatalog](../../xml/catalogs/XML%20TableOccurrenceCatalog.md) — `Structure/AddAction` branch, one `<TableOccurrence>` per graph node
- **DB schema:** [TableOccurrenceCatalog](../catalog-tables/TableOccurrenceCatalog.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_tableoccurrence.sql` — definition, relationships seen from this occurrence, other occurrences of the base table; the usage profile comes from `object_details_tableoccurrence_usage.sql`, appended only when `v_table_occurrence_usage` and `v_table_occurrence_class` exist (`meta.to_usage.available`); the TO group and context path come from `object_details_tableoccurrence_graph.sql` (relationship and layout-context links only, every schema). All are served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=TableOccurrence`; the header of every occurrence links into the relationship graph with the occurrence preselected

### Detail view

The detail tab is the profile of the occurrence. Name, file, UUID and the change stamp stay in the header above it and are not repeated.

- **Definition** — in the order of FileMaker's *Specify Table* dialog: the data source (*current file*, or the named data source with its path and whether its file is in the catalog), then the base table as a link with the file it lives in (*in this file*, or *in file …* marked *Cross-file*), and the node color and view mode on the relationship graph. The view never says "external": `TO_Type = 'External'` only means the occurrence reaches its base table through a data source, and that data source can point back at the occurrence's own file — the definition then shows *points back at this very file* and the base table *in this file*
- **Usage** — the usage class as a neutral badge, with the reason (`relationship_bridge`), the dead group and its anchor (`dead_branch`), a review hint for `unused`/`dead_*` and a notice for files without DDR info; below it the counts per usage category (objects · references), grouped into context, display, logic, data and graph. Each chip opens the references tab filtered to that category — except *Cascade delete*: the references tab lists the relationship once as its side, so that chip filters the relationship list below instead
- **TO group** — the connected part of the file's relationship graph the occurrence belongs to: its size and the layouts based on any of its TOs; the *anchors* (TOs that layouts are based on, most layouts first, nearer ones first on equal counts — at most three by name, the rest summed up as *+10 more with 1 layout each*, which opens the full list with layouts and distance); and the *layout context* — *is a layout context itself*, or the nearest anchor with the number of relationship steps to it (*nearest: Adressen Konto · 2 steps*). From two steps on, *show path* opens the path as a vertical list: one TO per line, the join fields of each relationship between them, linked to the relationship. FileMaker forbids cycles in the relationship graph, so the path is unique. The view deliberately draws no diagram — the relationship graph is the graphical view
- **Relationships** — one block per relationship with this occurrence always on the left: join fields of both sides (links to the fields), the operator mirrored when the occurrence is the right table in the catalog, the partner occurrence with its base table and, when it is reached through one, its data source, the options of both sides as symbols (＋ create, 🗑 cascade delete, ⇅ sorted) and a link to the relationship. A cascade delete that removes records of this occurrence tints its block. Option chips above the list (*Cascade delete*, *Create allowed*, *sorted*, each with its count) narrow it to the relationships with that option on either side; above eight relationships a filter field appears
- **Other occurrences of the base table** — one table across the solution — occurrence, *defined in* (the file whose relationship graph holds it) and *data source* (*current file* or the data source's name, ↺ when it points back at its own file) — with a filter field, sortable columns and the scope chips *all*, *this file* and *solution-wide* (the other files); the file column stays empty for the occurrence's own file. the heading links to the base table

Both tables always show every row — nothing is cut, the browser's find covers the whole list. The table header stays visible while the page scrolls; the count next to a section heading turns into *12 of 132* while a filter field or chip is active. Above fifteen relationships a jump bar at the top of the tab leads to both sections.

A field of a file that is not imported has no name in the export; the relationship block shows its id (`#24`).

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [BaseTable](BaseTable.md) · [Relationship](Relationship.md) · [ExternalDataSource](ExternalDataSource.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
