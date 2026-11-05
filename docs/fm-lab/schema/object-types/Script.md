# Script

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **script** is the procedural unit of FileMaker business logic: an ordered sequence of [script steps](ScriptStep.md) created in the Script Workspace. Scripts are called from other scripts (Perform Script), fired by [script triggers](ScriptTrigger.md), attached to buttons, listed in the Scripts menu, and can run with elevated privileges (*run with full access*). The Script Workspace also maintains a folder tree — and the export models that tree with the same element: folders and separators are `<Script>` entries too, flagged by `isFolder`/`isSeparatorItem`.

Script is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'Script'` mirrors one `<Script>` element of the [ScriptCatalog branch](../../xml/catalogs/XML%20ScriptCatalog.md) and lands in [ScriptCatalog](../catalog-tables/ScriptCatalog.md). The steps live in a separate branch ([XML StepsForScripts](../../xml/catalogs/XML%20StepsForScripts.md)) and land in [StepsForScripts](../catalog-tables/StepsForScripts.md); folder rows are additionally registered as synthetic [Folder](Folder.md) objects so the folder tree is addressable in the graph.

## Properties

The tables below list the property surface of the `<Script>` element in the XML export and where each property lands in the catalog. Properties marked **not extracted** are visible in the raw XML only.

### Identity & tree position

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `Script_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `Script_Name` | |
| `@isFolder` | `Folder_Type` | `True` = folder row, `Marker` = end-of-folder row (see [Object hierarchy](#object-hierarchy)) |
| `@isSeparatorItem` | `Is_Separator` | Separator line of the Scripts menu |
| `<UUID>` (text) | `Script_UUID` | Stable identity, used for all joins |
| document order | `Sequence_ID` | Display order of the Script Workspace — derived at import, not an XML attribute |

### Modification metadata (`<UUID>` attributes)

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@modifications` | `Modifications` | Modification count |
| `@userName` | `Modified_By` | FileMaker user name of the last editor |
| `@timestamp` | `Modified_At` | Raw text, local time of the editing client; typed in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `@accountName` | `Modified_Account` | Empty account → `NULL` |

### Options & the rest

| Property (XML) | In catalog | Notes |
|---|---|---|
| `<Options>` (text content) | `Option_Bitmask` | Raw numeric option bitmask |
| `<Options>/@hidden` | `Is_Hidden` | Excluded from the Scripts menu |
| `<Options>/@runwithfullaccess` | `Full_Access` | Runs with full access privileges |
| `<Options>/@access` | — | Access marker (`ReadWrite` observed) — **not extracted** |
| `<Options>/@compatibility` | — | Compatibility flag — **not extracted** |
| `<Options>/@SiriShortcutVisible` | — | Siri-shortcut visibility — **not extracted** |
| `<TagList>` | — | Script tags — **not extracted** |
| `<SourceUUID>` | — | Undocumented; observed on individual scripts in the test corpus (presumably copy provenance) — **not extracted** |

## Object hierarchy

Two containment axes meet in the Script type:

- **Steps.** Every step of the script is its own [ScriptStep](ScriptStep.md) object, linked to the script via `parent_script` and ordered by `Step_Index`. The script detail view renders the full step list, so steps are hoisted into the script's page rather than browsed standalone.
- **Folders.** The Script Workspace folder tree is encoded *flat* in the export: a `<Script isFolder="True">` entry opens a folder, the following entries are its members, and a `<Script isFolder="Marker">` entry closes it (folders nest). The import reconstructs the tree and links each script (and each nested folder) to its [Folder](Folder.md) via `parent_folder`.

## References

Scripts are the busiest link *sources* of the catalog — every resolved step parameter becomes an outgoing edge — and they are targeted by callers, triggers, buttons and privilege restrictions. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (Script as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `calls_script` | Script | usage | Perform Script (incl. Perform Script on Server) target |
| `sets_field` | [Field](Field.md) | usage | Set-Field-class steps write the field |
| `reads_field` | [Field](Field.md) | usage | A step or step calculation reads the field |
| `references_field` | [Field](Field.md) | usage | Fallback role for field references of uncurated step types |
| `inputs_to_field` | [Field](Field.md) | usage | Insert-class steps target the field |
| `imports_to_field` | [Field](Field.md) | usage | Import-class steps write the field |
| `exports_from_field` | [Field](Field.md) | usage | Export-class steps read the field |
| `finds_in_field` | [Field](Field.md) | usage | Find-class steps constrain on the field |
| `navigates_to_field` | [Field](Field.md) | usage | Go-to-Field-class steps target the field |
| `navigates_to_layout` | [Layout](Layout.md) | usage | Go to Layout / GTRR target layout |
| `navigates_to_to` | [TableOccurrence](TableOccurrence.md) | usage | Go to Related Record target occurrence |
| `sorts_by_field` | [Field](Field.md) | usage | Sort Records sort field |
| `sorts_by_valuelist` | [ValueList](ValueList.md) | usage | Custom sort order by value list |
| `sets_variable` | [Variable](Variable.md) | usage | Set Variable step writes the variable |
| `reads_variable` | [Variable](Variable.md) | usage | A step calculation reads the variable |
| `installs_menuset` | [CustomMenuSet](CustomMenuSet.md) | usage | Install Menu Set step |
| `calls_function` | [BuiltinFunction](BuiltinFunction.md) | usage | A step calculation calls a built-in function |
| `calls_customfunction` | [CustomFunction](CustomFunction.md) | usage | A step calculation calls a custom function |
| `calls_pluginfunction` | [PluginFunction](PluginFunction.md) | usage | A step calculation calls a plugin function |
| `parent_folder` | [Folder](Folder.md) | containment | The script sits in this Script Workspace folder |

### Incoming links (Script as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `calls_script` | Script | usage | Another script performs this script |
| `trigger_script` | [ScriptTrigger](ScriptTrigger.md) | usage | A trigger fires this script |
| `triggers_script` | [LayoutObject](LayoutObject.md) | usage | A button (or trigger-carrying object) performs this script |
| `triggers_script` | [CustomMenuItem](CustomMenuItem.md) | usage | A custom-menu item performs this script (subrole `menu_action`) |
| `restricts_object` | [PrivilegeSet](PrivilegeSet.md) | restriction | Script-level custom privilege restriction — never counts as usage |
| `parent_script` | [ScriptStep](ScriptStep.md) | containment | A step belongs to this script |

Edges produced by calculations *inside* steps carry the step index as `Link_Subrole` (`0`, `1`, …) — they attach to the Script, not to the individual [ScriptStep](ScriptStep.md) object, so the where-used answer stays at script granularity while remaining step-exact.

## Enumerations

| Property | Values |
|---|---|
| `Folder_Type` (`@isFolder`) | empty (regular script), `True` (folder row), `Marker` (end-of-folder row) *(corpus)* |

## Schema & tooling

- **XML schema:** [XML ScriptCatalog](../../xml/catalogs/XML%20ScriptCatalog.md) — `Structure/AddAction` branch; steps separately in [XML StepsForScripts](../../xml/catalogs/XML%20StepsForScripts.md)
- **DB schema:** [ScriptCatalog](../catalog-tables/ScriptCatalog.md) · steps in [StepsForScripts](../catalog-tables/StepsForScripts.md) · human-readable step text in [DDR_ScriptSteps](../catalog-tables/DDR_ScriptSteps.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_script.sql` (+ `object_details_script_tokens.sql` for the calculation token view and `queries/system/references/object_references_script.sql` for the per-line references view), served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=Script`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [ScriptStep](ScriptStep.md) · [ScriptTrigger](ScriptTrigger.md) · [Folder](Folder.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
