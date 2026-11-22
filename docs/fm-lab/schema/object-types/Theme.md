# Theme

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **theme** is a named set of layout styles — FileMaker ships built-in themes (`com.filemaker.theme.*`) and every styling change on top of one creates a custom theme derived from a base theme. In the export, a theme is essentially a **raw CSS rule set**: rich identity attributes (base name and version, platform, locale, group) plus the complete CSS text and a theme-internal metadata block with named styles.

Theme is an **exported** type: each `<Theme>` element becomes a row in [ThemeCatalog](../catalog-tables/ThemeCatalog.md) and in [ObjectCatalog](../object-catalog/ObjectCatalog.md). The catalog keeps identity and header columns plus the complete raw definition in `Theme_XML`; the CSS is split into declarations in [ThemeStyleRules](../catalog-tables/ThemeStyleRules.md), the named styles are listed in [ThemeNamedStyles](../catalog-tables/ThemeNamedStyles.md). Every [layout](Layout.md) references its theme via a `uses_theme` link — the basis for "which themes are actually in use?" cleanup queries.

## Properties

The tables below list the property surface of the `<Theme>` element and where each property lands in the catalog. Properties marked **not extracted** have no dedicated column — note that `Theme_XML` stores the **complete raw `<Theme>` element**, so everything below remains accessible as raw XML.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `Theme_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `Theme_Name` | Internal theme identifier (`com.filemaker.theme.…`; custom themes get a generated suffix) |
| `@Display` | `Theme_Display` | Human-readable display name (localized for built-in themes) |
| `@Group` | `Theme_Group` | `Custom` for a custom theme, otherwise the localized family of the built-in theme (e.g. `Apex Blau`, `Klassisch`) |
| `@baseName`, `@baseVersion` | `Base_Name`, `Base_Version` | Base theme a custom theme derives from (internal name; custom themes only) |
| `@defaultTheme` | `Is_Default` | Default theme for new layouts of the file (`BOOLEAN`, at most one per file) |
| `@version`, `@locale`, `@platform` | `Theme_Version`, `Theme_Locale`, `Theme_Platform` | Theme version, language of the built-in style names, platform code (`1`, `2`, `3` observed *(corpus)*, meaning undocumented) — raw |
| `<UUID>` (text) | `Theme_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<CSS>` (CDATA) | [ThemeStyleRules](../catalog-tables/ThemeStyleRules.md) | The complete CSS rule set, one row per declaration (raw CSS contained in `Theme_XML`) |
| `<Image>` | — | Theme image resource — **not extracted** |
| `<Metadata>` `<namedstyles>` | [ThemeNamedStyles](../catalog-tables/ThemeNamedStyles.md) | Every named style with its Inspector name (`<class>Name</class>`), unused ones included |
| `<Metadata>` (part paddings/min-sizes, color scheme, charting defaults, `<layoutbuilder>`) | — | Layout-builder and charting defaults — **not extracted**; unrelated to the file-level [XML Metadata](../../xml/catalogs/XML%20Metadata.md) branch |
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
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_theme.sql` — names and the number of layouts (base columns, every schema); the header attributes and the style list come from `object_details_theme_styles.sql`, appended only when [ThemeNamedStyles](../catalog-tables/ThemeNamedStyles.md) exists (`meta.theme_styles.available`, schema 1.46.0). Both are served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md). The layouts of one style come from the module template `display_theme_style_layouts.sql` when its row is expanded ([Detail View Templates](../../templates/Detail%20View%20Templates.md))
- **Frontend:** object list at `http://localhost:5173/?type=Theme`; the theme row of a layout's properties links here

### Detail view

The detail tab shows what the theme is and which styles it holds. Name, file, UUID and the change stamp stay in the header above it and are not repeated.

- **Properties** — the name; the kind (*custom theme* with its base theme, or *built-in theme* with its family) — the base theme is a link when it is imported in the same file, otherwise its internal name; the internal name; *default theme* when new layouts of the file get this theme; version, language and platform code; the number of layouts using the theme (opens the references tab); the number of custom styles, used and unused, and of built-in styles.
- **Custom styles** — one row per custom style with its Inspector name, the object type (from the type tokens of its rules, translated; a style can name several types, e.g. *Button bar, Button bar segment*), and how many objects and layouts of the theme's file use it. Chips *All*, *Used*, *Unused* with their counts and a search field narrow the list. A used style opens to its layouts with the number of objects each, most objects first; a layout link opens the layout canvas filtered by the style (`style=<class>`), the objects with that style highlighted. The layouts load only when the row opens, so the view stays light in a file whose styles sit on thousands of objects. Above 25 layouts the row shows the first 25, a search field over all of them and *Show all*.
- **Built-in styles** — the same table, collapsed below the custom styles; the filter and search apply to it as well.

Built-in style names stay in the language the theme was created in, like in FileMaker. A theme cloned into several files has the same styles in each, but its own usage per file. Classic and Minimalist have no named styles — the view says so instead of showing a list. On a catalog older than schema 1.46.0 the view shows the names and the layouts and a notice that the style list appears after a re-import.

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Layout](Layout.md) · [LayoutObject](LayoutObject.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
