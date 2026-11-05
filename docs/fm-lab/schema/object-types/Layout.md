# Layout

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **layout** is a screen (or print) presentation of records from one table occurrence — the central UI object of a FileMaker solution. Its export element is the root of the deepest branch of the whole XML: the layout header carries the context [table occurrence](TableOccurrence.md), [theme](Theme.md) and menu-set references, the packed view options and the layout-level [script triggers](ScriptTrigger.md); below it, a parts list contains the [parts](LayoutPart.md) which in turn contain all [layout objects](LayoutObject.md). The layout list itself is a tree: folders and separators appear as `<Layout>` entries of their own.

Layout is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'Layout'` mirrors one `<Layout>` element, with the header landing in [Layouts](../catalog-tables/Layouts.md). Folder entries additionally become synthetic [Folder](Folder.md) objects so the tree is walkable via `parent_folder` links. Parts, objects and triggers are imported as objects of their own ([LayoutPart](LayoutPart.md), [LayoutObject](LayoutObject.md), [ScriptTrigger](ScriptTrigger.md)) and tied back with containment links — in the frontend they are *hoisted* into the layout's detail view (wireframe).

## Properties

The tables below list the property surface of the `<Layout>` element (header level — parts and objects have their own pages) and where each property lands in the catalog. Properties marked **not extracted** are visible in the raw XML only.

### Identity & layout list

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `L_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `L_Name` | |
| `@width` | `L_Width` | Layout width in points |
| `@isFolder` | `Folder_Type` | `True` = folder row, `Marker` = folder-closing marker row |
| `@isSeparatorItem` | `Is_Separator` | Separator entry of the layout list |
| `<UUID>` (text) | `L_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<OwnerID>` | — (link) | Folder membership — resolved into the `parent_folder` link, not a column |
| position in the catalog | `Sequence_ID` | Order within the layout list |

### Context & references

| Property (XML) | In catalog | Notes |
|---|---|---|
| `<TableOccurrenceReference>` | `L_TO_Name`, `L_TO_UUID` | Context occurrence → `context_table` link |
| `<LayoutThemeReference>` `@id` / `@name` / `@UUID` / `@Base` | `L_Theme_ID` / `L_Theme_Name` / `L_Theme_UUID` / `L_Theme_Base` | An *empty* element means the Classic theme — resolved into `L_Theme_Resolved_Name`/`_UUID`, which also feed the `uses_theme` link (see [Layouts](../catalog-tables/Layouts.md)) |
| `<LayoutThemeReference>/@Display` | — | Display name of the theme — **not extracted** here (available via [ThemeCatalog](../catalog-tables/ThemeCatalog.md)`.Theme_Display`) |
| `<MenuSet>/<CustomMenuSetReference>` | `L_MenuSet_ID` / `_Name` / `_UUID` | → `uses_menuset` link |
| `<ScriptTriggers>/<ScriptTrigger>` | — (own objects) | Imported as [ScriptTrigger](ScriptTrigger.md) rows; tied back via `trigger_owner` |
| `<PartsList>/<Part>` | — (own objects) | Imported as [LayoutPart](LayoutPart.md) / [LayoutObject](LayoutObject.md) rows, see [Object hierarchy](#object-hierarchy) |

### Options (`<Options>` — bit-packed)

The layout `<Options>` element packs roughly 30 option bits into one integer. The catalog stores the raw value and decodes the standard-view block; **the majority of the option bits are not extracted** (the raw value is kept in `Options_Raw` for future decoding).

| Property (XML) | In catalog | Notes |
|---|---|---|
| `<Options>` packed value | `Options_Raw` | Raw bitmask |
| `@hidden` | `Is_Hidden` | "Include in layout menus" off |
| view bits (decoded) | `View_Form_Available`, `View_List_Available`, `View_Table_Available`, `Default_View` | Which of form/list/table view are enabled and which is the default; the *table*-view default needs bit calibration and is not decoded |
| further decoded bits | `Auto_Save_Changes`, `Show_Field_Frames`, `Frame_Current_Record_Only`, `Show_Current_Record_List`, `Quick_Find_Enabled` | |
| remaining ~30 option bits | — | Menu-set inheritance, keyboard/resizing behaviors, … — **not extracted** |

### Other header elements

| Property (XML) | In catalog | Notes |
|---|---|---|
| `<GridStyle>` (`<Color>`, `<Style>`) | — | Layout-mode grid color and style — **not extracted** |
| `<ClientType>` | — | Target client hint (numeric; `0`, `3` observed *(corpus)*, meaning undocumented) — **not extracted** |

## Object hierarchy

The layout is the hub of the tightest hierarchy in the catalog:

- **Parts** — every [LayoutPart](LayoutPart.md) links to its layout via `parent_layout`; the `Link_Subrole` carries the part type (`Body`, `Header`, `Leading Sub-summary`, …), so the band structure is readable from the links alone.
- **Objects** — every [LayoutObject](LayoutObject.md) also links to the layout via `parent_layout` (subrole `NULL`). Nesting *among* objects — tab panels, slide panels, groups, popovers, portals — is a separate `parent_object` link chain between layout objects; nesting depth 5 occurs in practice.
- **Triggers** — layout-level [script triggers](ScriptTrigger.md) hang on the layout via `trigger_owner` (subrole = event type, e.g. `OnRecordLoad`); the layout additionally carries the counting `triggers_script · <event>` mirror to each trigger's script.
- **Folder tree** — layouts (and layout folders, which nest) link to their [Folder](Folder.md) via `parent_folder`.

In the web frontend, parts and objects are hoisted into the layout detail view: the wireframe renders the parts as bands and the objects at their real coordinates, so [LayoutPart](LayoutPart.md) and [LayoutObject](LayoutObject.md) have no standalone detail page of their own ambition — the layout view is their home.

## References

The layout header contributes a small, precise set of outgoing edges; the interesting traffic is incoming — navigation targets, containment backlinks and restrictions. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (Layout as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `context_table` | [TableOccurrence](TableOccurrence.md) | usage | The layout's context table occurrence |
| `uses_theme` | [Theme](Theme.md) | usage | The layout uses this theme (built from the resolved theme UUID, so Classic layouts link too) |
| `uses_menuset` | [CustomMenuSet](CustomMenuSet.md) | usage | Layout-bound menu set |
| `displays_field` | [Field](Field.md) | usage | Merge field (`<<Field>>` in text) displayed at layout level |
| `triggers_script` | [Script](Script.md) | usage | Counting mirror of every layout-level trigger (subrole = event) — the where-used truth for trigger-fired scripts |
| `reads_field` / `reads_variable` | [Field](Field.md) / [Variable](Variable.md) | usage | Reference inside a layout-level script-trigger parameter calc (subrole `ScriptTrigger_<id>`) |
| `calls_function` / `calls_customfunction` / `calls_pluginfunction` | [BuiltinFunction](BuiltinFunction.md) / [CustomFunction](CustomFunction.md) / [PluginFunction](PluginFunction.md) | usage | Function call inside a layout-level trigger parameter calc (same subrole) |
| `has_calculation` | [Calculation](Calculation.md) | containment | Trigger-parameter calc instances of the layout as addressable objects — never counts as usage |
| `parent_folder` | [Folder](Folder.md) | containment | The layout sits in this layout folder |

### Incoming links (Layout as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `navigates_to_layout` | [Script](Script.md) / [LayoutObject](LayoutObject.md) | usage | Go to Layout / GTRR target layout (incl. button-embedded steps) |
| `default_layout` | [File](File.md) | usage | Start layout from the file options |
| `parent_layout` | [LayoutObject](LayoutObject.md) / [LayoutPart](LayoutPart.md) | containment | Object or part belongs to this layout (subrole = part type for parts) |
| `trigger_owner` | [ScriptTrigger](ScriptTrigger.md) | containment | Layout-level trigger hangs here (subrole = event type) |
| `restricts_object` | [PrivilegeSet](PrivilegeSet.md) | restriction | Layout-level custom privilege restriction — never counts as usage |

`displays_field` distinguishes the carrier by source type: a field *control* carries it as a [LayoutObject](LayoutObject.md), a merge field embedded in layout text carries it at layout level.

## Enumerations

| Property | Values |
|---|---|
| `Default_View` | `Form`, `List` (decoded from the bitmask; the table-view default is not decoded — needs calibration). Corpus shows `Form` only *(corpus)* |
| `Folder_Type` | `True` (folder), `Marker` (folder-end marker), `NULL` (regular layout) |
| trigger events (via `trigger_owner` subrole) | the 12 layout-level events (slot IDs 101–113), authoritatively enumerated in the [script_triggers](../fm-spec-tables/script_triggers.md) reference table — see [ScriptTrigger](ScriptTrigger.md) |

## Schema & tooling

- **XML schema:** [XML LayoutCatalog](../../xml/catalogs/XML%20LayoutCatalog.md) — `<LayoutCatalog>` branch, one `<Layout>` per layout/folder/separator entry
- **DB schema:** [Layouts](../catalog-tables/Layouts.md) · parts in [LayoutParts](../catalog-tables/LayoutParts.md) · objects in [LayoutObjects](../catalog-tables/LayoutObjects.md) · triggers in [ScriptTriggers](../catalog-tables/ScriptTriggers.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_layout.sql` — renders the layout as an SVG wireframe (served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)); the interactive frontend panels load `display_layout_objects_data.sql`, `display_layout_parts_data.sql`, `display_layout_triggers.sql` and `display_layout_meta.sql` from `rest-api/templates/queries/modules/layout-view/` (see [Detail View Templates](../../templates/Detail%20View%20Templates.md))
- **Frontend:** object list at `http://localhost:5173/?type=Layout`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [LayoutPart](LayoutPart.md) · [LayoutObject](LayoutObject.md) · [Theme](Theme.md) · [ScriptTrigger](ScriptTrigger.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
