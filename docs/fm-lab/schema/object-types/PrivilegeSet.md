# PrivilegeSet

Part of the [FileMaker object types](FileMaker%20Object%20Types.md) · semantic object-type reference

A **privilege set** is the central permission object of a FileMaker file: it bundles class-level access switches for records, layouts, value lists and scripts, the extended toggles (printing, exporting, managing the database, accounts or custom menus), password and idle-disconnect policies — and, where a class is switched to *Custom privileges*, a per-object detail tree down to individual tables, fields, layouts, value lists and scripts. Record-level custom privileges can even be decided by calculations, which makes privilege sets calculation carriers like scripts and fields.

PrivilegeSet is an **exported** type: each row of [ObjectCatalog](../object-catalog/ObjectCatalog.md) with `Object_Type = 'PrivilegeSet'` mirrors one `<PrivilegeSet>` element of the export. The class-level surface lands in [PrivilegeSetsCatalog](../catalog-tables/PrivilegeSetsCatalog.md); the custom-privilege detail trees are parsed into three satellite tables — [PrivilegeSetRecordAccess](../catalog-tables/PrivilegeSetRecordAccess.md) (per table × operation), [PrivilegeSetFieldAccess](../catalog-tables/PrivilegeSetFieldAccess.md) (per field) and [PrivilegeSetObjectAccess](../catalog-tables/PrivilegeSetObjectAccess.md) (per layout / value list / script). Important analysis rule: the restriction edges a privilege set produces (`restricts_field`, `restricts_object`) are classified as **restrictions, never as usage** — a privilege set restricting a layout does not make that layout "used".

## Properties

The tables below list the full property surface of the `<PrivilegeSet>` element and where each property lands in the catalog. Properties marked **not extracted** are visible in the raw XML only.

### Identity & class-level access

| Property (XML) | In catalog | Notes |
|---|---|---|
| `@id` | `PrivilegeSet_ID` | Numeric FileMaker ID — unique per file only, join with `File_Name` |
| `@name` | `PrivilegeSet_Name` | Bracketed names (`[Full Access]`, …) are FileMaker's built-in sets |
| `<UUID>` (text) | `PrivilegeSet_UUID` | Stable identity, used for all joins |
| `<UUID>` `@timestamp` / `@userName` / `@accountName` / `@modifications` | `Modified_At` / `Modified_By` / `Modified_Account` / `Modifications` | Change metadata, raw (`Modified_At` as text, empty account → `NULL`); typed per object in [ObjectChangeMeta](../catalog-tables/ObjectChangeMeta.md) |
| `<Description>` | `Description` | Developer description |
| `<access>/@default` | `Is_Default_Access` | Set on FileMaker's built-in default sets |
| `<Records>` `@View` / `@Edit` / `@Create` / `@Delete` | `Records_View` / `Records_Edit` / `Records_Create` / `Records_Delete` | Class-level record access |
| `<Layouts>` `@View` / `@Edit` / `@Create` / `@Delete` / `@Custom` | `Layouts_View` / `Layouts_Edit` / `Layouts_Create` / `Layouts_Delete` / `Layouts_Custom` | Class-level layout access |
| `<ValueLists>` `@View` / `@Edit` / `@Create` / `@Delete` | `ValueLists_View` / `ValueLists_Edit` / `ValueLists_Create` / `ValueLists_Delete` | Class-level value-list access |
| `<Scripts>` `@View` / `@Edit` / `@Create` / `@Delete` | `Scripts_View` / `Scripts_Edit` / `Scripts_Create` / `Scripts_Delete` | Class-level script access |
| `<Records>` / `<ValueLists>` / `<Scripts>` `@Custom` | — | The custom flag itself is a column only for Layouts; for the other classes custom privileges are indicated by rows in the satellite tables |
| `<… ><Custom>` detail trees | satellite tables | See next table — parsed into [PrivilegeSetRecordAccess](../catalog-tables/PrivilegeSetRecordAccess.md) / [PrivilegeSetFieldAccess](../catalog-tables/PrivilegeSetFieldAccess.md) / [PrivilegeSetObjectAccess](../catalog-tables/PrivilegeSetObjectAccess.md) |

When a class carries `Custom="True"`, the class-level attributes no longer reflect real access — always consult the satellite tables in that case.

### Extended toggles (`<Other>`) and password policy

| Property (XML) | In catalog | Notes |
|---|---|---|
| `<Other>/@value` | `Other_Value` | Packed numeric form of the toggle block |
| `@Print` / `@Export` | `Allow_Print` / `Allow_Export` | |
| `@manageDatabase` / `@manageAccounts` / `@manageCustomMenus` / `@manageExtPrivs` | `Manage_Database` / `Manage_Accounts` / `Manage_Custom_Menus` / `Manage_Ext_Privs` | Design-surface management rights |
| `@allowOverride` | `Allow_Override` | Override of data-validation warnings |
| `@allowOpenQuickly` | `Allow_Open_Quickly` | |
| `@disconnectIdle` | `Disconnect_Idle` | Disconnect user when idle |
| `@commands` | `Commands` | Available menu commands (e.g. `All`) |
| `<Password>/@prohibitModification` | `Password_Prohibit_Modification` | |
| `<Password>` `@Minimum` / `@interval` | — | Minimum password length and change interval — **not extracted** |

### Custom-privilege detail (satellite tables)

| XML detail | Lands in | Notes |
|---|---|---|
| `<Records><Custom>` → `<Table>` with `<View>`/`<Edit>`/`<Create>`/`<Delete>` `@access` | [PrivilegeSetRecordAccess](../catalog-tables/PrivilegeSetRecordAccess.md) | One row per set × base table × operation; `Table type="New"` = default rule for future tables |
| Operation with `access="Calculation"` → `<Calculation>` (formula text, `DDRREF` hash, context table occurrence) | [PrivilegeSetRecordAccess](../catalog-tables/PrivilegeSetRecordAccess.md) (`Calculation_Text`, `DDR_Hash`, `Context_TO_*`) | Calc-based record access; references inside the formula become graph links |
| `<Fields access="Custom">` → `<Field>` per field | [PrivilegeSetFieldAccess](../catalog-tables/PrivilegeSetFieldAccess.md) | Per-field access mode; restrictions become `restricts_field` links |
| `<Layouts>` / `<ValueLists>` / `<Scripts>` `<Custom>` → per-object entries (`@access`, layouts also `@records`) | [PrivilegeSetObjectAccess](../catalog-tables/PrivilegeSetObjectAccess.md) | Unified table with `Object_Class` discriminator; restrictions become `restricts_object` links |

## References

Privilege sets produce three kinds of edges: grants (extended privileges), restrictions (custom-privilege limits — never usage) and genuine usage edges carried by their record-access calculations. Full role definitions: [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md).

### Outgoing links (PrivilegeSet as source)

| Link_Role | Target | Kind | Description |
|---|---|---|---|
| `grants_privilege` | [ExtendedPrivilege](ExtendedPrivilege.md) | usage | The privilege set grants this extended privilege |
| `restricts_field` | [Field](Field.md) | restriction | Field-level custom privilege restriction (subrole = access mode) |
| `restricts_object` | [Layout](Layout.md) / [ValueList](ValueList.md) / [Script](Script.md) | restriction | Object-level custom privilege restriction (subrole = access mode) |
| `reads_field` | [Field](Field.md) | usage | Record-access calculation reads the field |
| `reads_variable` | [Variable](Variable.md) | usage | Record-access calculation reads a global variable |
| `calls_customfunction` | [CustomFunction](CustomFunction.md) | usage | Record-access calculation calls a custom function |
| `calls_pluginfunction` | [PluginFunction](PluginFunction.md) | usage | Record-access calculation calls a plugin function |
| `has_calculation` | [Calculation](Calculation.md) | containment | Each record-access calculation as an addressable instance (subrole `record_access`) — never counts as usage |

### Incoming links (PrivilegeSet as target)

| Link_Role | Source | Kind | Description |
|---|---|---|---|
| `privilege_set` | [Account](Account.md) | usage | An account is assigned this privilege set |

Restriction edges are emitted only for actual restrictions (`Access_Mode <> 'ReadWrite'`) and carry the access mode as subrole (`NoAccess`, `ReadOnly`, `Calculation`, …). The calc-carried usage roles carry the subrole pattern `<Operation>:<Table>` (e.g. `Delete:Contacts`) naming the Custom-Record-Privilege rule that contains the reference — these edges close the where-used gap for objects referenced only inside access calculations.

## Enumerations

| Property | Values |
|---|---|
| Access mode (`Access_Mode`, class-level `@View`/`@access` attributes) | `NoAccess`, `ReadOnly`, `ReadWrite`, `Calculation` (record access only) — kept as plain text so unknown modes survive |
| `Operation` (record access) | `View`, `Edit`, `Create`, `Delete` |
| `Object_Class` (object access) | `Layout`, `ValueList`, `Script` |
| `Table_Type` / entry `@type` | `existing`, `New` (`New` = default rule for future objects) |

## Schema & tooling

- **XML schema:** [XML PrivilegeSetsCatalog](../../xml/catalogs/XML%20PrivilegeSetsCatalog.md) — `<PrivilegeSetsCatalog>` branch, one `<PrivilegeSet>` with its `<access>` tree
- **DB schema:** [PrivilegeSetsCatalog](../catalog-tables/PrivilegeSetsCatalog.md) · satellites [PrivilegeSetRecordAccess](../catalog-tables/PrivilegeSetRecordAccess.md), [PrivilegeSetFieldAccess](../catalog-tables/PrivilegeSetFieldAccess.md), [PrivilegeSetObjectAccess](../catalog-tables/PrivilegeSetObjectAccess.md) · access calcs tokenized in [DDR_Calculations](../catalog-tables/DDR_Calculations.md)
- **Detail view template:** `rest-api/templates/queries/system/object-details/object_details_privilegeset.sql`, served via the [/api/get-details endpoint](../../rest-api/endpoints/Objects%20API.md)
- **Frontend:** object list at `http://localhost:5173/?type=PrivilegeSet`

**See also:** [Object Types](../object-catalog/Object%20Types.md) · [Account](Account.md) · [ExtendedPrivilege](ExtendedPrivilege.md) · [Field](Field.md) · [Link Roles and Subroles](../object-catalog/Link%20Roles%20and%20Subroles.md)
