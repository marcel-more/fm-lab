# LayoutPart

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **layout part** is a horizontal band (section) of a [layout](Layout.md) — header, body, footer, sub-summaries, grand summaries, navigation parts. Parts determine what repeats per record (Body), what prints once (Title Header/Footer, Grand Summaries), what aggregates per sorted group (Sub-summaries, each breaking on a field) and what stays pinned on screen (Top/Bottom Navigation). Every [layout object](LayoutObject.md) belongs to exactly one part.

LayoutPart is an **exported** type: each `<Part>` element inside a layout's `<PartsList>` becomes a row in [LayoutParts](../catalog-tables/LayoutParts.md) and an [ObjectCatalog](../object-catalog/ObjectCatalog.md) object (named `<Layout> [<Part type>]`, sub-summaries with their break field appended). Parts are sequenced (`Part_Seq`) rather than keyed by type, so several sub-summary parts of the same kind stay distinct. In the frontend, parts are **hoisted** into the layout detail view — the wireframe renders them as bands, which is their natural home rather than a standalone page.

## Properties

The tables below list the property surface of the `<Part>` element and where each property lands in the catalog. Properties marked **not extracted** are visible in the raw XML only.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@type` | `Part_Type` | Part type name, see [Enumerations](#enumerations) |
| `@kind` | `Part_Kind` | Numeric code paired with the type |
| `@name` | — | Display name of sub-summary parts (e.g. `Sub-summary by TextField1 (Leading)`) — **not extracted** as a column; the catalog object name is derived independently |
| position in `<PartsList>` | `Part_Seq` | Band order, top to bottom |
| `<Definition>/@type`, `@kind` | `Definition_Type`, `Definition_Kind` | Repeat the part classification on the definition element |
| `<Definition>/@size` | `Part_Size` | Part height in points |
| `<Definition>/@absolute` | `Part_Absolute` | |
| `<Definition>/@Options` | `Part_Options` | Packed part options (page-break behavior, …) — stored raw, **bits not decoded** |
| `<Definition>/<FieldReference>` | `Break_Field_ID` / `_Name` / `_UUID`, `Break_TO_Name` / `_UUID` | Sub-summary break field → `breaks_on_field` link |
| `<ObjectList>/@membercount` | `Object_Count` | Quick size measure without touching [LayoutObjects](../catalog-tables/LayoutObjects.md) |
| `<ObjectList>/<LayoutObject>` | — (own objects) | Imported as [LayoutObject](LayoutObject.md) rows, tied to the layout via `parent_layout` and to the part via the `Part_Type` column |

Parts have no `@id` and no `<UUID>` of their own in the export; the catalog identifies them by layout + sequence (a synthetic `Object_UUID` is minted for the [ObjectCatalog](../object-catalog/ObjectCatalog.md) row).

## Object hierarchy

Parts sit between the layout and its objects: every part links to its [Layout](Layout.md) via `parent_layout`, and the `Link_Subrole` of that edge carries the part type — the band structure of a layout is readable from the link table alone. The layout objects inside a part do **not** link to the part (their `parent_layout` link goes straight to the layout); the part assignment lives in the `Part_Type` column of [LayoutObjects](../catalog-tables/LayoutObjects.md) instead.

In the web frontend, parts render as bands of the layout wireframe (layout detail view) — they are hoisted, not orphaned.

## References

Parts carry exactly one usage edge — the sub-summary break field — plus their containment backlink. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (LayoutPart as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `breaks_on_field` | [Field](Field.md) | usage | Sub-summary part breaks on this field (subrole = part type, e.g. `Leading Sub-summary`) — a real field usage that counts for where-used |
| `parent_layout` | [Layout](Layout.md) | containment | The part belongs to the layout (subrole = part type) |

### Incoming links (LayoutPart as target)

No documented roles target a LayoutPart — objects inside a part link to the layout, not the part.

## Enumerations

Part types with their `@kind` codes as observed in the ooe-fm corpus *(corpus)*; the set matches FileMaker's part palette:

| `Part_Type` | `Part_Kind` |
|---|---|
| `Title Header` | 0 |
| `Header` | 1 |
| `Leading Grand Summary` | 2 |
| `Leading Sub-summary` | 3 |
| `Body` | 4 |
| `Trailing Sub-summary` | *not observed in the corpus* — part of FileMaker's set, expected between Body and Trailing Grand Summary |
| `Trailing Grand Summary` | 6 |
| `Footer` | 7 |
| `Title Footer` | 8 |
| `Top Navigation` | 12 |
| `Bottom Navigation` | 13 |

## Schema & tooling

- **XML schema:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md) — `<Part>` elements inside each layout's `<PartsList>`
- **DB schema:** [LayoutParts](../catalog-tables/LayoutParts.md)
- **Detail view:** hoisted — parts render as bands inside the layout wireframe (`display_layout_parts_data.sql` under `rest-api/templates/queries/modules/layout-view/`, see [Detail View Templates](../../templates/Detail%20View%20Templates.md)); for the standalone object, the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md) falls back to the generic detail template (`object_details_generic.sql`)
- **Frontend:** object list at `http://localhost:5173/?type=LayoutPart`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Layout](Layout.md) · [LayoutObject](LayoutObject.md) · [Field](Field.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
