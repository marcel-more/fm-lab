# Theme

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **theme** is a named set of layout styles — FileMaker ships built-in themes (`com.filemaker.theme.*`) and every styling change on top of one creates a custom theme derived from a base theme. In the export, a theme is essentially a **raw CSS rule set**: rich identity attributes (base name and version, platform, locale, group) plus the complete CSS text and a theme-internal metadata block with named styles.

Theme is an **exported** type: each `<Theme>` element becomes a row in [ThemeCatalog](../catalog-tables/ThemeCatalog.md) and in [ObjectCatalog](../object-catalog/ObjectCatalog.md). The catalog keeps identity columns plus the complete raw definition in `Theme_XML`; the CSS itself is not parsed further. Every [layout](Layout.md) references its theme via a `uses_theme` link — the basis for "which themes are actually in use?" cleanup queries.

## Properties

The tables below list the property surface of the `<Theme>` element and where each property lands in the catalog. Properties marked **not extracted** have no dedicated column — note that `Theme_XML` stores the **complete raw `<Theme>` element**, so everything below remains accessible as raw XML.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `Theme_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `Theme_Name` | Internal theme identifier (`com.filemaker.theme.…`; custom themes get a generated suffix) |
| `@Display` | `Theme_Display` | Human-readable display name (localized for built-in themes) |
| `@Group` | — | Theme group (`Custom`, `Basic` observed *(corpus)*) — **not extracted** |
| `@baseName`, `@baseVersion` | — | Base theme a custom theme derives from — **not extracted** |
| `@defaultTheme` | — | Marks the file's default theme — **not extracted** |
| `@version`, `@locale`, `@platform` | — | Theme version, locale and platform code (`1`, `2` observed *(corpus)*, meaning undocumented) — **not extracted** |
| `<UUID>` (text) | `Theme_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<CSS>` (CDATA) | — | The complete CSS rule set — **not extracted** as a column of its own (contained in `Theme_XML`) |
| `<Image>` | — | Theme image resource — **not extracted** |
| `<Metadata>` (`<namedstyles>`, part paddings/min-sizes, color scheme, charting defaults, `<layoutbuilder>`) | — | Theme-internal named styles and layout-builder defaults — **not extracted**; unrelated to the file-level [XML Metadata](../../xml/catalogs/XML%20Metadata.md) branch |
| `<TagList>` | — | **not extracted** |
| whole element | `Theme_XML` | Complete raw `<Theme>` definition, CSS included — the last-resort source for all of the above |

## References

Themes are pure targets: they carry no outgoing edges, and exactly one role points at them. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (Theme as source)

No documented roles originate from a Theme.

### Incoming links (Theme as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `uses_theme` | [Layout](Layout.md) | usage | The layout uses this theme |

A theme with no incoming `uses_theme` edge is dead weight in the file — the classic cleanup query for this type. Note that SaXML writes the **Classic** theme as an *empty* `<LayoutThemeReference/>` on the layout; the edge is therefore built from the resolved theme columns (`Layouts.L_Theme_Resolved_*`, schema 1.21.0), so Classic layouts link correctly too.

## Schema & tooling

- **XML schema:** [XML ThemeCatalog](../../xml/catalogs/XML%20ThemeCatalog.md) — `<ThemeCatalog>` branch, one `<Theme>` per theme
- **DB schema:** [ThemeCatalog](../catalog-tables/ThemeCatalog.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_theme.sql`, served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=Theme`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Layout](Layout.md) · [LayoutObject](LayoutObject.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
