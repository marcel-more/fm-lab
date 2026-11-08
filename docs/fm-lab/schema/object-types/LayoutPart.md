# LayoutPart

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **layout part** is a horizontal band (section) of a [layout](Layout.md) — header, body, footer, sub-summaries, grand summaries, navigation parts. Parts determine what repeats per record (Body), what prints once (Title Header/Footer, Grand Summaries), what aggregates per sorted group (Sub-summaries, each breaking on a field) and what stays pinned on screen (Top/Bottom Navigation). Every [layout object](LayoutObject.md) belongs to exactly one part.

LayoutPart is an **exported** type: each `<Part>` element inside a layout's `<PartsList>` becomes a row in [LayoutParts](../catalog-tables/LayoutParts.md) and an [ObjectCatalog](../object-catalog/ObjectCatalog.md) object (named `<Layout> [<Part type>]`, sub-summaries with their break field appended). Parts are sequenced (`Part_Seq`) rather than keyed by type, so several sub-summary parts of the same kind stay distinct. In the frontend a part has a [detail view](#detail-view) of its own; the layout detail view lists the parts and filters the wireframe by part.

## Properties

The tables below list the property surface of the `<Part>` element and where each property lands in the catalog. Properties marked **not extracted** are visible in the raw XML only.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@type` | `Part_Type`, raw in `Definition_Type` | Part type name, canonical English, see [Enumerations](#enumerations) |
| `@kind` | `Part_Kind` | Numeric code — the only locale-independent key of the type |
| `@name` | `Part_Name` | Name FileMaker generates for sub-summary parts (e.g. `Sub-summary by TextField1 (Leading)`); the catalog object name is derived independently |
| position in `<PartsList>` | `Part_Seq` | Band order, top to bottom |
| `<Definition>/@type`, `@kind` | `Definition_Type`, `Definition_Kind` | Repeat the part classification on the definition element |
| `<Definition>/@size` | `Part_Size` | Part height in points |
| `<Definition>/@absolute` | `Part_Absolute` | |
| `<Definition>/@Options` | `Part_Options` | Five options of the *Part Definition* dialog as bits (page breaks, page numbering, breaking across pages) — decoded in [LayoutParts](../catalog-tables/LayoutParts.md#notes) |
| `<Definition>/@restartEachGroup` | `Part_Break_Every` | *n* of *page break after every n occurrences*, present only when that option is set |
| `<Definition>/<LocalCSS>` | `Part_LocalCSS_Name`, `Part_LocalCSS_Type`, `Part_LocalCSS`, `Part_Alt_Row_Local`, `Part_Active_Row_Local` | Part style and local CSS; the row-state options are CSS properties, see [LayoutParts](../catalog-tables/LayoutParts.md#notes) and [ThemePartStyles](../catalog-tables/ThemePartStyles.md) |
| `<Definition>/<FieldReference>` | `Break_Field_ID` / `_Name` / `_UUID`, `Break_TO_Name` / `_UUID` | Sub-summary break field → `breaks_on_field` link |
| `<ObjectList>/@membercount` | `Object_Count` | Quick size measure without touching [LayoutObjects](../catalog-tables/LayoutObjects.md) |
| `<ObjectList>/<LayoutObject>` | — (own objects) | Imported as [LayoutObject](LayoutObject.md) rows, tied to the layout via `parent_layout` and to the part via `Part_Seq` / `Part_Kind` |

Parts have no `@id` and no `<UUID>` of their own in the export; the catalog identifies them by layout + sequence (a synthetic `Object_UUID` is minted for the [ObjectCatalog](../object-catalog/ObjectCatalog.md) row).

## Object hierarchy

Parts sit between the layout and its objects: every part links to its [Layout](Layout.md) via `parent_layout`, and the `Link_Subrole` of that edge carries the part type — the band structure of a layout is readable from the link table alone. The layout objects inside a part do **not** link to the part (their `parent_layout` link goes straight to the layout); the part assignment lives in the `Part_Seq` / `Part_Kind` columns of [LayoutObjects](../catalog-tables/LayoutObjects.md) instead — derived at import from the top edge of each root object, nested objects inheriting the part of their parent.

In the web frontend, parts render as bands of the layout wireframe and have a detail view of their own (see [Detail view](#detail-view)).

## References

Parts carry exactly one usage edge — the sub-summary break field — plus their containment backlink. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (LayoutPart as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `breaks_on_field` | [Field](Field.md) | usage | Sub-summary part breaks on this field (subrole = part type, e.g. `Leading Sub-summary`) — a real field usage that counts for where-used |
| `parent_layout` | [Layout](Layout.md) | containment | The part belongs to the layout (subrole = part type) |

### Incoming links (LayoutPart as target)

No edge targets a LayoutPart — objects inside a part link to the layout, not the part. The references tab still lists the objects of the part under *Contains*: the [References API](../../rest-api/endpoints/References%20API.md) reads them from `LayoutObjects.Part_Seq` as rows with the role `parent_part` (one filter chip per object type). A layout object shows its part the same way under *Contained in*. These rows do not count as usage and do not appear in the graph.

## Enumerations

Part types with their `@kind` codes as observed in the ooe-fm corpus *(corpus)*; the set matches FileMaker's part palette:

| `Part_Type` | `Part_Kind` |
|---|---|
| `Title Header` | 0 |
| `Header` | 1 |
| `Leading Grand Summary` | 2 |
| `Leading Sub-summary` | 3 |
| `Body` | 4 |
| `Trailing Sub-summary` | 5 — FileMaker 22 and older export it as `Trailing Grand Summary`; the import corrects the type by kind |
| `Trailing Grand Summary` | 6 |
| `Footer` | 7 |
| `Title Footer` | 8 |
| `Top Navigation` | 12 |
| `Bottom Navigation` | 13 |

The export writes `@type` in the language of the exporting FileMaker client (`Kopfbereich`, `Datenbereich`, …); `Part_Type` is mapped to English. The web frontend labels parts with the terms of FileMaker's *Part Definition* dialog in the UI language, keyed by `Part_Kind`.

## Schema & tooling

- **XML schema:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md) — `<Part>` elements inside each layout's `<PartsList>`
- **DB schema:** [LayoutParts](../catalog-tables/LayoutParts.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_layoutpart.sql`, served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md); the layout view loads the parts from `display_layout_parts_data.sql` under `rest-api/templates/queries/modules/layout-view/` (see [Detail View Templates](../../templates/Detail%20View%20Templates.md))
- **Frontend:** object list at `http://localhost:5173/?type=LayoutPart`

### Detail view

The heading names the part like the dialog does, sub-summaries with break field and position (*Sub-summary when sorted by ‹Ship via› (trailing)*). *Show in layout* opens the layout with this part as section filter.

- **General** — part type and position, the exported type when it differs (localized, or the kind-5 mislabel), the internal name of sub-summaries, the position among the layout's parts with links to the previous and next part, height, top and bottom edge, and the number of objects (all nesting levels and directly in the part). The number opens the references tab, which lists the objects
- **Part definition** — the seven options of the dialog as check boxes: *discard remainder* indented under *allow part to break*, *page break after every n occurrences* with its n. The two row-state options apply to body parts only and name where their value comes from: set on the part, part style, theme, or not set (Classic: off)
- **Sorting** — sub-summaries only: the break field as a link, with a note when it is reached through another table occurrence than the layout's
- **Context** — layout, its table occurrence and base table, file
- **Technical** — raw option value (with the bits that are no dialog option), `Part_Kind` · `Part_Seq`, part style

Next to the dialog options on wide screens, below them on narrow ones. Name, file and the change stamp (inherited from the layout) stay in the header.

The layout detail view lists the parts in its properties panel (height, number of objects, break field) and offers a **Layout part** menu above the wireframe: objects outside the chosen part turn grey, search, type chips and counters work inside it, *Esc* clears it. The choice is kept in the URL (`?part=<Part_Seq>`).

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Layout](Layout.md) · [LayoutObject](LayoutObject.md) · [Field](Field.md) · [ThemePartStyles](../catalog-tables/ThemePartStyles.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
