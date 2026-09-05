# FileMaker Object Types

Part of the [FM-Lab schema](../Schema.md) · semantic object-type reference

This section describes the FileMaker object types **semantically** — what each object *is* in a FileMaker solution, which properties it carries in the `SaveCopyAsXML` export, how it nests into object hierarchies, and which references connect it to the rest of the solution. It complements the data-schema documentation: the [Object Types](../object-catalog/Object%20Types.md) page enumerates the `Object_Type` values of [ObjectCatalog](../object-catalog/ObjectCatalog.md), the [XML reference](../../xml/XML.md) documents the export structure, and the [schema reference](../Schema.md) documents the DuckDB tables. The pages here tie those three views together, one page per object type.

Each type page follows the same layout:

- **Properties** — the full property surface from the XML export, including attributes the catalog deliberately does *not* extract (marked "not extracted"), so the coverage boundary is visible at a glance.
- **Object hierarchy** — for types that live inside a tight containment hierarchy (layout parts and objects, script steps, menu trees), an explicit description of parent/child semantics beyond the bare link roles.
- **References** — the type's link-role vocabulary from [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md), split into outgoing (the type as source) and incoming (the type as target) edges.
- **Enumerations** — value tables for enum-typed properties, where applicable.
- **Schema & tooling** — pointers to the XML branch, the catalog table(s), the detail-view SQL template behind the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md), and the object list in the web frontend (`http://localhost:5173/?type=<TypeName>`).

Some types are **hoisted** in the frontend — they have no standalone detail view because they render inside their parent's view (script steps inside the script detail, parts and objects inside the layout wireframe). They still get full pages here: they are core building blocks of a FileMaker solution, and their properties and hierarchies are essential reference material. Types for which a dedicated detail view is still missing carry a visible **TBD** note.

## Exported object types

These types mirror an XML catalog of the [FileMaker export](../../xml/XML.md) one-to-one.

| Type | What it is | Detail view |
|---|---|---|
| [Account](Account.md) | User account with privilege-set assignment | TBD (generic) |
| [BaseDirectory](BaseDirectory.md) | Named base directory for external container paths | generic |
| [BaseTable](BaseTable.md) | Schema-level base table owning fields and records | ✓ |
| [CustomFunction](CustomFunction.md) | User-defined calculation function | ✓ |
| [CustomMenu](CustomMenu.md) | Custom menu, container of menu items | ✓ |
| [CustomMenuItem](CustomMenuItem.md) | Single item of a custom menu | ✓ |
| [CustomMenuSet](CustomMenuSet.md) | Named set of custom menus | TBD (generic) |
| [ExtendedPrivilege](ExtendedPrivilege.md) | Extended privilege keyword granted by privilege sets | generic |
| [ExternalDataSource](ExternalDataSource.md) | Reference to another FileMaker file or ODBC source | TBD (generic) |
| [Field](Field.md) | Field of a base table — the richest object definition in the export | ✓ |
| [Layout](Layout.md) | Layout: context, theme, menu set, parts and objects | ✓ |
| [LayoutObject](LayoutObject.md) | Object on a layout (26 subtypes, arbitrarily nested) | hoisted into the layout view |
| [LayoutPart](LayoutPart.md) | Part (band) of a layout | hoisted into the layout view |
| [PrivilegeSet](PrivilegeSet.md) | Privilege set with class-level and custom privileges | ✓ |
| [Relationship](Relationship.md) | Relationship between two table occurrences | ✓ |
| [Script](Script.md) | Script: the step sequence plus folder tree and options | ✓ |
| [ScriptStep](ScriptStep.md) | Single script step, ordered within its script | hoisted into the script view |
| [ScriptTrigger](ScriptTrigger.md) | Script trigger at file, layout or object level | ✓ |
| [TableOccurrence](TableOccurrence.md) | Table occurrence on the relationship graph | TBD (generic) |
| [Theme](Theme.md) | Layout theme incl. its CSS rule set | ✓ |
| [ValueList](ValueList.md) | Value list (custom values, field-based or external) | ✓ |

## Synthetic object types

The import pipeline derives these for things FileMaker has no catalog of its own for — deriving them is what makes the objects addressable in the [ObjectLinks](../object-catalog/ObjectLinks.md) graph.

| Type | What it is | Detail view |
|---|---|---|
| [File](File.md) | The FileMaker file itself — owner anchor for file-level options and triggers | generic |
| [Folder](Folder.md) | Folder of the script or layout tree | ✓ |
| [Variable](Variable.md) | Script variable (`$`, `$$`, `$$$`) as an addressable object | ✓ |
| [BuiltinFunction](BuiltinFunction.md) | Built-in FileMaker function referenced by calculations | ✓ |
| [PluginFunction](PluginFunction.md) | External plugin function (e.g. MBS) referenced by calculations | ✓ |
| [PluginComponent](PluginComponent.md) | Plugin component aggregating its functions | ✓ |
| [ScriptStepType](ScriptStepType.md) | Script-step *type* (e.g. "Set Variable") as a catalog object | ✓ |
| [Calculation](Calculation.md) | One calculation *instance* per owner slot (field calc, step parameter, hide condition, …) — schema 1.22.0 | ✓ |
| [PasteIndexObject](PasteIndexObject.md) | Copy/paste index entry (bookkeeping, no analytical role) | generic |

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [ObjectCatalog](../object-catalog/ObjectCatalog.md) · [ObjectLinks](../object-catalog/ObjectLinks.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md) · [Schema](../Schema.md)
