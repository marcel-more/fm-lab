# CustomMenu

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **custom menu** is one menu of FileMaker's *Manage Custom Menus* system: a named menu derived from a built-in base menu (File, Edit, Scripts, …), with an install condition (a calculation deciding whether the menu appears), per-mode options (Browse/Find/Preview) and an ordered list of menu items. Custom menus never appear on their own — they are grouped into [menu sets](CustomMenuSet.md), which layouts bind or scripts install. FileMaker also ships bracket-named stock menus (`[File]`, `[Scripts]`, `[Manage]`, …) that appear in the export like ordinary custom menus.

CustomMenu is an **exported** type: each `<CustomMenu>` element of [XML CustomMenuCatalog](../../xml/catalogs/XML%20CustomMenuCatalog.md) becomes a row in [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'CustomMenu'`. The importer keeps the complete menu definition as a raw XML fragment (`Menu_XML`) and additionally parses the item list into [CustomMenuItemCatalog](../catalog-tables/CustomMenuItemCatalog.md) — each item gets its own object identity (see [CustomMenuItem](CustomMenuItem.md)).

## Properties

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `Menu_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `Menu_Name` | Stock menus use bracket names, e.g. `[Scripts]` |
| `<UUID>` (text) | `Menu_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<Base>` (`@name`, `@value`) | — | The built-in base menu the custom menu derives from — **not extracted** (raw `Menu_XML` only) |
| `<Comment>` | — | Developer comment — **not extracted** (raw `Menu_XML` only) |
| `<Conditions>/<Install>/<Calculation>` | — | Install condition — no dedicated column; its DDR anchor (`_<UUID>_Install`) resolves via [DDR_Calculations](../catalog-tables/DDR_Calculations.md) |
| `<Options>` (`@browseMode`, `@findMode`, `@previewMode`) | — | Per-mode availability — **not extracted** (raw `Menu_XML` only) |
| `<MenuItemList>` (`@membercount`) | → [CustomMenuItemCatalog](../catalog-tables/CustomMenuItemCatalog.md) | Items parsed into their own catalog, ordered by `Item_Index` |
| `<TagList>` | — | Tags — **not extracted** |

The whole element is preserved verbatim in `Menu_XML`, so the non-extracted properties remain inspectable in the raw fragment.

## Object hierarchy

The custom-menu system is a three-level tree: a [CustomMenuSet](CustomMenuSet.md) lists its member menus (`contains_menu`, resolved from the set's `CustomMenuReference` entries by `(File_Name, Menu_ID)`), each menu owns its items ([CustomMenuItem](CustomMenuItem.md) → `parent_menu`, ordered by `Item_Index`), and a submenu item points back at the menu it opens (`opens_menu` — a *usage* edge, deliberately distinct from the structural owner backlink, so that a menu reachable only as a submenu still counts as used). Menus themselves are file-local; built-in member menus referenced by a set are not catalog objects.

## References

Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (CustomMenu as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `has_calculation` | [Calculation](Calculation.md) | containment | The menu-level install condition as an addressable instance (subrole `menu_install`, schema 1.22.0) — never counts as usage |

*No usage edges registered.* The install condition is a calculation anchored at `_<Menu_UUID>_Install`; in the test corpus these conditions are constants (`1`), so no calc-carried usage edges with a CustomMenu source are observed — calculation references inside items resolve with the *item* as source instead.

### Incoming links (CustomMenu as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `contains_menu` | [CustomMenuSet](CustomMenuSet.md) | containment | The menu set lists this menu as a member |
| `parent_menu` | [CustomMenuItem](CustomMenuItem.md) | containment | The item belongs to this menu (owner backlink) |
| `opens_menu` | [CustomMenuItem](CustomMenuItem.md) | usage | A submenu item opens this menu — keeps submenu-only menus out of dead-code results |

## Schema & tooling

- **XML schema:** [XML CustomMenuCatalog](../../xml/catalogs/XML%20CustomMenuCatalog.md) — `Structure/AddAction` branch, items inline per menu
- **DB schema:** [CustomMenuCatalog](../catalog-tables/CustomMenuCatalog.md) (raw definition) · [CustomMenuItemCatalog](../catalog-tables/CustomMenuItemCatalog.md) (parsed items)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_custommenu.sql` (+ `object_details_custommenu_tokens.sql` for the calculation token view), served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=CustomMenu`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [CustomMenuItem](CustomMenuItem.md) · [CustomMenuSet](CustomMenuSet.md) · [Layout](Layout.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
