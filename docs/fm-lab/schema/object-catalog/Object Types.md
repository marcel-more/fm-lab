# Object Types

Part of the [FM-Lab schema](../Schema.md) · Object catalog · enumeration of [ObjectCatalog](ObjectCatalog.md)`.Object_Type`

> Enumeration state: **schema version 1.27.0** (2026-09-02) — see [Schema Version History](../Schema%20Version%20History.md). Which types actually occur in a given catalog depends on the imported solution; the pipeline reports unknown types via the P6 check views instead of dropping them.

`Object_Type` classifies every row of [ObjectCatalog](ObjectCatalog.md). This page is the *enumeration* reference; the semantic description of each type — properties, hierarchies, reference vocabulary — lives in [FileMaker Object Types](../object-types/FileMaker%20Object%20Types.md), one page per type. Two groups exist: **exported types** mirror an XML catalog of the [FileMaker export](../../xml/XML.md) one-to-one, while **synthetic types** are derived by the import pipeline for things FileMaker has no catalog of its own for (variables, called functions, plugin components) — deriving them is what makes these objects addressable in the [ObjectLinks](ObjectLinks.md) graph at all.

## Exported object types

| Object_Type | Detail table | Description |
|---|---|---|
| `Account` | [AccountsCatalog](../catalog-tables/AccountsCatalog.md) | User account |
| `BaseDirectory` | [BaseDirectoryCatalog](../catalog-tables/BaseDirectoryCatalog.md) | Named base directory for external paths |
| `BaseTable` | [BaseTableCatalog](../catalog-tables/BaseTableCatalog.md) | Schema-level base table |
| `CustomFunction` | [CustomFunctionsCatalog](../catalog-tables/CustomFunctionsCatalog.md) | Custom function |
| `CustomMenu` | [CustomMenuCatalog](../catalog-tables/CustomMenuCatalog.md) | Custom menu |
| `CustomMenuItem` | [CustomMenuItemCatalog](../catalog-tables/CustomMenuItemCatalog.md) | Single item of a custom menu |
| `CustomMenuSet` | [CustomMenuSetCatalog](../catalog-tables/CustomMenuSetCatalog.md) | Menu set |
| `ExtendedPrivilege` | [ExtendedPrivilegesCatalog](../catalog-tables/ExtendedPrivilegesCatalog.md) | Extended privilege keyword |
| `ExternalDataSource` | [ExternalDataSourceCatalog](../catalog-tables/ExternalDataSourceCatalog.md) | External data source |
| `Field` | [FieldsForTables](../catalog-tables/FieldsForTables.md) | Field of a base table |
| `Layout` | [Layouts](../catalog-tables/Layouts.md) | Layout |
| `LayoutObject` | [LayoutObjects](../catalog-tables/LayoutObjects.md) | Object on a layout (subtypes below) |
| `LayoutPart` | [LayoutParts](../catalog-tables/LayoutParts.md) | Part (section) of a layout |
| `PrivilegeSet` | [PrivilegeSetsCatalog](../catalog-tables/PrivilegeSetsCatalog.md) | Privilege set |
| `Relationship` | [RelationshipCatalog](../catalog-tables/RelationshipCatalog.md) | Relationship on the graph |
| `Script` | [ScriptCatalog](../catalog-tables/ScriptCatalog.md) | Script |
| `ScriptStep` | [StepsForScripts](../catalog-tables/StepsForScripts.md) | Single script step |
| `ScriptTrigger` | [ScriptTriggers](../catalog-tables/ScriptTriggers.md) | Script trigger (file, layout or object level) |
| `TableOccurrence` | [TableOccurrenceCatalog](../catalog-tables/TableOccurrenceCatalog.md) | Table occurrence on the relationship graph |
| `Theme` | [ThemeCatalog](../catalog-tables/ThemeCatalog.md) | Layout theme |
| `ValueList` | [ValueListCatalog](../catalog-tables/ValueListCatalog.md) | Value list |

## Synthetic object types

| Object_Type | Derived from | Description |
|---|---|---|
| `File` | [FilesCatalog](FilesCatalog.md) | The FileMaker file itself — owner anchor for file-level options and triggers (UUID = the export's root UUID) |
| `Folder` | [ScriptCatalog](../catalog-tables/ScriptCatalog.md), [Layouts](../catalog-tables/Layouts.md), [CustomFunctionsCatalog](../catalog-tables/CustomFunctionsCatalog.md) | Folder of the script, layout or custom-function tree (entries flagged `isFolder`), target of `parent_folder` links |
| `Variable` | [VariablesCatalog](../catalog-tables/VariablesCatalog.md) | Script variable (`$`, `$$`, `$$$`); UUID derived from scope + anchor + name |
| `BuiltinFunction` | [DDR_Calculations](../catalog-tables/DDR_Calculations.md) | Built-in FileMaker function referenced by a calculation, target of `calls_function` links — including the design functions (`WindowNames`, `DatabaseNames`, `ValueListItems`, …), which the export tags as plug-in references and the importer re-types via [DesignFunctionNames](../catalog-tables/DesignFunctionNames.md); localized spellings (`Fensternamen`) stay as written and resolve through the reference at query time |
| `PluginFunction` | [PluginFunctionUsages](../catalog-tables/PluginFunctionUsages.md) | External plugin function (qualified as `MBS:<Component.Function>`), target of `calls_pluginfunction`; never a design function (see `BuiltinFunction`) |
| `PluginComponent` | [PluginFunctionUsages](../catalog-tables/PluginFunctionUsages.md) | Plugin component aggregating its functions via `groups_into` |
| `ScriptStepType` | [StepsForScripts](../catalog-tables/StepsForScripts.md) | Step *type* (e.g. "Set Variable") as a catalog object — one per step ID in use, incl. button-embedded steps |
| `Calculation` | [CalculationsCatalog](../catalog-tables/CalculationsCatalog.md) | One calculation **instance** per owner slot (field calc, step parameter, hide condition, …) — identity Owner × role × index, exists also without DDR-Info; anchored via `has_calculation` (schema 1.22.0) |
| `PasteIndexObject` | [XML PasteIndexList](../../xml/catalogs/XML%20PasteIndexList.md) | Copy/paste index entry (bookkeeping, no analytical role) |

## LayoutObject subtypes

`LayoutObjects.Object_Type` refines layout objects further. The type attribute is **localized** in SaXML exports; the import canonicalizes it to the English names via locale-independent signals (`@kind`, wrapper element names), so analyses can rely on this list:

| Group | Types |
|---|---|
| Input | `Edit Box`, `Concealed Edit Box`, `Drop-down List`, `Pop-up Menu`, `Radio Button Set`, `Checkbox Set`, `Drop-down Calendar` |
| Display | `Text`, `Graphic`, `Container`, `Web Viewer`, `Chart` |
| Action | `Button`, `Grouped Button`, `Button Bar`, `Popover Button` |
| Container | `Portal`, `Group`, `Tab Control`, `Panel`, `Slide Control`, `PopoverPanel` |
| Shape | `Rectangle`, `Rounded Rectangle`, `Oval`, `Line` |

An unrecognized raw type (new FileMaker version, unknown `@kind`) is kept as-is and reported by the P6 check `v_check_unknown_object_types` for curation — never silently dropped.

**See also:** [FileMaker Object Types](../object-types/FileMaker%20Object%20Types.md) · [ObjectCatalog](ObjectCatalog.md) · [ObjectLinks](ObjectLinks.md) · [Link Roles and Subroles](Link%20Roles%20and%20Subroles.md)
