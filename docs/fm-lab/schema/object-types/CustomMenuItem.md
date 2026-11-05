# CustomMenuItem

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **custom menu item** is a single entry of a [custom menu](CustomMenu.md). It comes in three kinds: a **command item** wraps a built-in menu command and may override its title (fixed or calculated), its action (an embedded script step, e.g. *Perform Script*) and its keyboard shortcut; a **separator** is a pure divider line; a **submenu item** points at another custom menu that opens as its submenu. Every item additionally carries its own install condition (a calculation deciding whether the item appears).

CustomMenuItem is an **exported** type: the items live inline inside their menu's `<MenuItemList>` in [XML CustomMenuCatalog](../../xml/catalogs/XML%20CustomMenuCatalog.md), and the importer parses each one into [CustomMenuItemCatalog](../catalog-tables/CustomMenuItemCatalog.md) with its own object identity — that is what lets the item's calculations (install condition, calculated title) resolve to a real source object in the link graph. Since items have no name of their own, the catalog display name follows the convention `<Menu name> › <command name>`, with `(Separator)` for separators. An item whose overridden title is a plain string literal is named after that text (`<Menu name> › Artikel` for the title `"Artikel"`); only a real title formula gets the placeholder `(berechnet)`.

## Properties

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@index` | `Item_Index` | Position within the menu (0-based) |
| `@hash` | `Item_Hash` | Export-internal content hash |
| `@isSubMenuItem` | `Is_SubMenuItem` | Submenu-pointer kind |
| `@isSeparatorItem` | `Is_SeparatorItem` | Separator kind |
| `<UUID>` (text) | `Item_UUID` | Stable identity (no modification metadata on item UUIDs) |
| `<Command>` (`@name`, `@id`) | `Command_Name` / `Command_ID` | The built-in command a command item wraps; command names are localized, the ID is not |
| `<Conditions>/<Install>/<Calculation>` | — | Install condition — no dedicated column; its DDR anchor (`_<UUID>_Install`) resolves via [DDR_Calculations](../catalog-tables/DDR_Calculations.md) into calc-carried links (subrole `Install`) |
| `<Name>/<Calculation>` | — | Overridden item title — **not extracted** as a column; DDR anchor `_<UUID>_Name`. A pure string literal becomes the item's display name |
| `<Override>` (`@name`, `@action`, `@Shortcut`) | — | Which aspects of the base command are overridden — **not extracted** (raw `Item_XML` only) |
| `<Shortcut>` (`@key`, `@modifier`) | — | Overridden keyboard shortcut — **not extracted** (raw `Item_XML` only) |
| `<action>/<Step>` | — | Embedded script step of an overridden action (full step XML incl. parameter values) — **not extracted** into the step tables. A *Perform Script* step becomes the `triggers_script` link (subrole `menu_action`); other object references inside the embedded step are not resolved into links |
| `<CustomMenuReference>` (`@id`, `@name`) | — | Submenu target — carries only a file-local `id` (no UUID); resolved via `(File_Name, Menu_ID)` into the `opens_menu` link |

The owning menu is denormalized onto every row (`Menu_ID` / `Menu_UUID` / `Menu_Name`), and the raw fragment is preserved in `Item_XML`.

## Object hierarchy

Items are the leaves of the custom-menu tree: [CustomMenuSet](CustomMenuSet.md) —`contains_menu`→ [CustomMenu](CustomMenu.md) —(owns)— CustomMenuItem. The item's structural owner edge is `parent_menu` (item → menu); its usage counterpart is `opens_menu`, which a submenu item points at the menu it opens. An item never contains other items — nesting is always expressed by pointing at another menu.

## References

Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (CustomMenuItem as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `parent_menu` | [CustomMenu](CustomMenu.md) | containment | The menu this item belongs to (owner backlink) |
| `opens_menu` | [CustomMenu](CustomMenu.md) | usage | Submenu item opens this menu |
| `triggers_script` | [Script](Script.md) | usage | The item's action performs this script (subrole `menu_action`). Resolved via the target file and the script ID — a cross-file reference carries a proxy UUID that matches no script |
| `calls_function` | [BuiltinFunction](BuiltinFunction.md) | usage | The item's install condition or calculated title calls a built-in function (subrole = calc slot, e.g. `Install`) |
| `has_calculation` | [Calculation](Calculation.md) | containment | Each calculation slot of the item (install condition, calculated name, script parameter) as an addressable instance (subroles `menu_item_install` / `menu_item_name` / `menu_item_parameter`) — never counts as usage |

### Incoming links (CustomMenuItem as target)

*None registered.*

## Schema & tooling

- **XML schema:** [XML CustomMenuCatalog](../../xml/catalogs/XML%20CustomMenuCatalog.md) — `<CustomMenuItem>` elements inside each menu's `<MenuItemList>`
- **DB schema:** [CustomMenuItemCatalog](../catalog-tables/CustomMenuItemCatalog.md) (one row per item, `Item_XML` raw)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_custommenuitem.sql` (+ `object_details_custommenuitem_tokens.sql` for the calculation token view), served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=CustomMenuItem`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [CustomMenu](CustomMenu.md) · [CustomMenuSet](CustomMenuSet.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
