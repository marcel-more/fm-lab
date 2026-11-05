# Folder

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **folder** is an organizational node of the Script Workspace, the layout list or the Manage Custom Functions dialog — pure developer ergonomics, with no runtime behavior of its own. FileMaker has no folder catalog: folders travel inside the script, layout and custom-function catalogs as regular `<Script>` / `<Layout>` / `<CustomFunction>` entries flagged `isFolder`. Folder is therefore a **synthetic** type: the import pipeline promotes those flagged rows to [ObjectCatalog](../object-catalog/ObjectCatalog.md) entries with `Object_Type = 'Folder'`, which is what gives `parent_folder` links a target and makes folder trees walkable in the graph. `Source_Table` distinguishes the three subtypes.

Folders nest to arbitrary depth; separators (`isSeparatorItem`) are related list decorations but stay ordinary rows — they do **not** become Folder objects.

## Properties

A Folder has no XML element of its own — its properties are those of the flagged catalog row it was promoted from. The table shows the script-tree column names ([ScriptCatalog](../catalog-tables/ScriptCatalog.md)); the layout tree ([Layouts](../catalog-tables/Layouts.md)) and the custom-function tree ([CustomFunctionsCatalog](../catalog-tables/CustomFunctionsCatalog.md)) carry the same flags as `Folder_Type` / `Is_Separator` on their `L_*` and `CF_*` rows.

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `Script_ID` / `L_ID` / `CF_ID` | Numeric FileMaker ID of the folder row |
| `@name` | `Script_Name` / `L_Name` / `CF_Name` → `Object_Name` | Folder display name |
| `@isFolder` | `Folder_Type` | `True` = folder row, `Marker` = end-of-folder row (script and custom-function trees) |
| `@isSeparatorItem` | `Is_Separator` | Separator rows — not promoted to Folder objects |
| `<UUID>` (text) | `Script_UUID` / `L_UUID` / `CF_UUID` → `Object_UUID` | Stable identity of the folder |
| `<Options>`, `<UUID>` attributes, `<TagList>` | *(as on the host row)* | Folder rows carry the same option/modification surface as their host type — see [Script](Script.md) and [Layout](Layout.md) |
| tree encoding — script and custom-function trees | — | Flat sequence: `isFolder="True"` opens, `isFolder="Marker"` closes; membership reconstructed at import from `Sequence_ID` (XML order) |
| tree encoding — layout tree | — | Membership carried by `<OwnerID>` on the layout entries ([XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md)) |

The reconstructed tree (nesting level, parent folder, member kind `Folder`/`FolderEnd`/`Item`/`Separator`) is available in the internal `FolderHierarchy` view.

## Object hierarchy

Folders form the only hierarchy in the catalog that is *purely* organizational:

- **Members.** Each [Script](Script.md), [Layout](Layout.md) or [CustomFunction](CustomFunction.md) inside a folder links to it via `parent_folder`.
- **Nesting.** A nested folder links to its parent folder via `parent_folder` as well (Folder → Folder), so a deep tree is a chain of `parent_folder` edges.
- Objects at the root of the Script Workspace or layout list simply have no `parent_folder` edge.

All `parent_folder` edges are structural containment — they never count as usage, so an otherwise unreferenced script is still dead code no matter how neatly it is filed.

## References

Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (Folder as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `parent_folder` | Folder | containment | The folder is nested inside this parent folder |

### Incoming links (Folder as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `parent_folder` | [Script](Script.md) / [Layout](Layout.md) / [CustomFunction](CustomFunction.md) / Folder | containment | The object or subfolder sits in this folder |

## Schema & tooling

- **XML schema:** no catalog of its own — derived from flagged entries in [XML ScriptCatalog](../../xml/catalogs/XML%20ScriptCatalog.md), [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md) and [XML CustomFunctionsCatalog](../../xml/catalogs/XML%20CustomFunctionsCatalog.md)
- **DB schema:** rows in [ScriptCatalog](../catalog-tables/ScriptCatalog.md) / [Layouts](../catalog-tables/Layouts.md) / [CustomFunctionsCatalog](../catalog-tables/CustomFunctionsCatalog.md) (`Folder_Type`, `Is_Separator`); reconstructed tree in the internal `FolderHierarchy` view
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_folder.sql` (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)) — distinguishes the subtype via the source table and labels it *Script Folder* / *Layout Folder* / *CustomFunction Folder*
- **Frontend:** object list at `http://localhost:5173/?type=Folder`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Script](Script.md) · [Layout](Layout.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
