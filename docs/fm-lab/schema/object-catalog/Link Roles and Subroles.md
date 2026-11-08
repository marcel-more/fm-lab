# Link Roles and Subroles

Part of the [FM-Lab schema](../Schema.md) · Object catalog · enumerations of [ObjectLinks](ObjectLinks.md)

> Enumeration state: **schema version 1.27.0** (2026-09-02) — see [Schema Version History](../Schema%20Version%20History.md). The authoritative runtime source is the [LinkRoleRegistry](LinkRoleRegistry.md) table; new schema versions may add roles.

Every edge in [ObjectLinks](ObjectLinks.md) is classified by three values: `Link_Type` (the coarse class), `Link_Role` (the specific relation — a closed vocabulary of 60 registered roles) and `Link_Subrole` (an optional, role-specific qualifier). This page enumerates all three. `Link_Role` and `Link_Subrole` live on one page deliberately: a subrole has no meaning of its own — it always qualifies a specific role.

## Link_Type

| Value | Description |
|---|---|
| `operational` | A functional dependency: the source *uses* the target (calls, reads, writes, displays, navigates, restricts). Where-used and dead-code analyses walk these edges. |
| `structural` | A containment relation: the source *belongs to* the target (a step to its script, an object to its layout, an item to its menu). These edges model hierarchy, never usage. |

## Link_Role

Roles are registered in [LinkRoleRegistry](LinkRoleRegistry.md) with their kind (`usage` / `containment` / `restriction`) and the `Counts_For_Where_Used` flag. 51 of the 52 usage roles count for where-used — the exception is `trigger_script`, whose counting truth is the owner mirror `triggers_script` (see the two rows below); the 9 containment and 2 restriction roles never count — a privilege set restricting a layout does not make that layout "used".

The *Source → Target* column lists the documented carrier types; a role can have several (e.g. `reads_field` is carried by scripts, calculated fields, custom functions, layout objects and privilege sets alike).

### Usage roles (52)

| Role                   | Source → Target                                                               | Description                                                     |
| ---------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `auto_login_account`   | File → Account                                                                | Auto-login account from the file options (security-relevant)    |
| `base_table`           | TableOccurrence → BaseTable                                                   | The base table the occurrence represents                        |
| `breaks_on_field`      | LayoutPart → Field                                                            | Sub-summary part breaks on this field                           |
| `calls_customfunction` | Script/Field/LayoutObject/ CustomFunction/ PrivilegeSet → CustomFunction      | A calculation calls the custom function                         |
| `calls_function`       | Script/Field/LayoutObject/ CustomFunction/ CustomMenuItem/… → BuiltinFunction | A calculation calls a built-in FileMaker function               |
| `calls_pluginfunction` | Script/Field/LayoutObject/ CustomFunction/ PrivilegeSet → PluginFunction      | A calculation calls an external plugin function (e.g. MBS)      |
| `calls_script`         | Script → Script                                                               | Perform Script target — incl. Perform Script on Server, marked by the [subrole](#link_subrole) `on_server`/`on_server_callback` (since schema 1.20.0) |
| `context_table`        | Layout → TableOccurrence                                                      | The layout's context table occurrence                           |
| `data_source`          | TableOccurrence/ValueList → ExternalDataSource                                | Object sources its data from this external data source          |
| `default_layout`       | File → Layout                                                                 | Start layout from the file options                              |
| `displays_field`       | LayoutObject/Layout → Field                                                   | The field is displayed (field control, merge field in a text object or button label, table-view column) |
| `displays_symbol`      | LayoutObject → BuiltinFunction                                                | A valid `{{…}}` symbol of a text object displays the value of `Get(<Symbol>)` |
| `displays_variable`    | LayoutObject → Variable                                                       | A merge variable is displayed on the layout                     |
| `exports_from_field`   | Script → Field                                                                | Export-class steps read the field                               |
| `finds_in_field`       | Script → Field                                                                | Find-class steps constrain on the field                         |
| `grants_privilege`     | PrivilegeSet → ExtendedPrivilege                                              | The privilege set grants this extended privilege                |
| `imports_to_field`     | Script → Field                                                                | Import-class steps write the field                              |
| `inputs_to_field`      | Script → Field                                                                | Insert-class steps target the field                             |
| `installs_menuset`     | Script → CustomMenuSet                                                        | Install Menu Set step                                           |
| `left_field`           | Relationship → Field                                                          | Join-predicate field of the left side (one pair per predicate)  |
| `left_table`           | Relationship → TableOccurrence                                                | Left table occurrence of the relationship                       |
| `lookup_context`       | Field → TableOccurrence                                                       | The occurrence a lookup starts from ("Starting with table") — the path from there to the lookup occurrence runs through the relationship graph (since schema 1.38.0) |
| `lookup_relationship`  | Field → TableOccurrence                                                       | The lookup resolves through this relationship                   |
| `lookup_source`        | Field → Field                                                                 | The lookup copies from this source field                        |
| `navigates_to_field`   | Script/LayoutObject → Field                                                   | Go-to-Field-class steps target the field                        |
| `navigates_to_layout`  | Script/LayoutObject → Layout                                                  | Go to Layout / GTRR target layout (incl. button-embedded steps) |
| `navigates_to_to`      | Script/LayoutObject → TableOccurrence                                         | Go to Related Record target occurrence (GTRR only)              |
| `opens_menu`           | CustomMenuItem → CustomMenu                                                   | Submenu item opens this menu                                    |
| `parent_table`         | Field → BaseTable                                                             | The base table the field belongs to                             |
| `portal_context`       | LayoutObject → TableOccurrence                                                | The portal's data-source occurrence                             |
| `privilege_set`        | Account → PrivilegeSet                                                        | The account is assigned this privilege set                      |
| `reads_field`          | Script/Field/CustomFunction/ LayoutObject/Layout/File/ ScriptTrigger/PrivilegeSet → Field | A step or calculation reads the field (Layout/File: layout-/file-level trigger parameter calcs; ScriptTrigger: the OnWindowTransaction parameter-field candidates) |
| `reads_variable`       | Script/Field/CustomFunction/ LayoutObject/PrivilegeSet → Variable             | A step or calculation reads the variable                        |
| `references_field`     | Script/LayoutObject → Field                                                   | Field reference whose direction is not differentiated (see below) |
| `related_values_from`  | ValueList → TableOccurrence                                                   | "Include only related values starting from": the occurrence a field-based value list starts from (since schema 1.38.0) |
| `right_field`          | Relationship → Field                                                          | Join-predicate field of the right side                          |
| `right_table`          | Relationship → TableOccurrence                                                | Right table occurrence of the relationship                      |
| `sets_field`           | Script/LayoutObject → Field                                                   | Set-Field-class steps write the field                           |
| `sets_variable`        | Script/CustomFunction → Variable                                              | Set Variable step / Let assignment writes the variable          |
| `sort_field`           | Relationship → Field                                                          | Sort field of a relationship side                               |
| `sorts_by_field`       | Script/LayoutObject → Field                                                   | Sort Records / portal sort / button-embedded sort field         |
| `sorts_by_valuelist`   | Script/LayoutObject/Relationship → ValueList                                  | Custom sort order by value list                                 |
| `source_field`         | ValueList → Field                                                             | Field-based value list: the value field                         |
| `source_table`         | ValueList → TableOccurrence                                                   | Field-based value list: the source occurrence                   |
| `source_valuelist`     | ValueList → ValueList                                                         | External wrapper sources its values from a list in another file |
| `summarizes_field`     | Field → Field                                                                 | Summary field aggregates this field                             |
| `trigger_script`       | ScriptTrigger → Script                                                        | The script the trigger fires — granular navigation edge; **does not count for where-used** (the owner mirror `triggers_script` does) |
| `triggers_script`      | LayoutObject/Layout/File/CustomMenuItem → Script                              | The owner performs the script — button actions, custom-menu actions and the counting mirror of every script trigger (subrole = event, `button_action` or `menu_action`) |
| `uses_menuset`         | Layout → CustomMenuSet                                                        | Layout-bound menu set                                           |
| `uses_theme`           | Layout → Theme                                                                | The layout uses this theme                                      |
| `uses_valuelist`       | LayoutObject/Field → ValueList                                                | Field control uses the list; field validation by list           |
| `validates_by_calc`    | Field → Field/CustomFunction                                                  | A field-validation calculation references the target            |

**On `references_field`.** A script step's field role comes from an internal map keyed by step ID. Two kinds of reference end up in the undifferentiated bucket. A step type that is not in the map at all falls back to it — where-used stays intact, only the role is coarse; a pipeline check reports such step types so they can be curated. And a handful of steps carry a source field *and* a target field at once (the AI steps around embeddings and model responses): one role per step ID cannot express both directions, and field references are extracted without the option they came from, so those steps are mapped to `references_field` deliberately rather than to a misleading `sets_field` or `reads_field`.

Reading a role off a step's option type is unreliable in the other direction, too: in the [fm-spec](../../Wiki/fm-spec.md) reference, `target` describes the XML shape of an option, not the direction of the data. Write to Data File carries its field as a `target` option although the field is read from — hence its `reads_field` role.

### Containment roles (9)

Structural owner relations (`Link_Type = 'structural'`); never counted as usage.

| Role | Source → Target | Description |
|---|---|---|
| `contains_menu` | CustomMenuSet → CustomMenu | The menu set contains the menu as a member |
| `groups_into` | PluginFunction → PluginComponent | Plugin functions aggregate into their component |
| `has_calculation` | owner → [Calculation](../object-types/Calculation.md) | Every calculation instance hangs on its owner (field, step, layout object, layout, file, CF, menu (item), privilege set). The usage semantics stay on the owner-projected edges — *Calculation → target* exists only as the derived view `v_calculation_links` |
| `parent_folder` | Script/Layout/Folder → Folder | The object sits in this folder (script/layout folder trees; folders nest) |
| `parent_layout` | LayoutObject/LayoutPart → Layout | The object or part belongs to the layout |
| `parent_menu` | CustomMenuItem → CustomMenu | The item belongs to the menu (owner backlink — the *usage* counterpart is `opens_menu`) |
| `parent_object` | LayoutObject → LayoutObject | A nested object's container parent (tab panel, group, popover, …) |
| `parent_script` | ScriptStep → Script | The step belongs to the script |
| `trigger_owner` | ScriptTrigger → Layout/LayoutObject/File | The trigger hangs on this owner |

### Restriction roles (2)

Access limitations from Custom Privileges (`Access_Mode <> 'ReadWrite'` only). A restriction is **not** a usage — these edges never make an object appear "used".

| Role | Source → Target | Description |
|---|---|---|
| `restricts_field` | PrivilegeSet → Field | Field-level custom privilege restriction |
| `restricts_object` | PrivilegeSet → Layout/ValueList/Script | Object-level custom privilege restriction |

## Link_Subrole

`Link_Subrole` is **not a closed enum**: its value set depends on the role, and some patterns are dynamic (they embed object names or indexes). NULL when a role needs no qualifier.

| Role(s) | Subrole values | Meaning |
|---|---|---|
| `calls_script` | `on_server`, `on_server_callback` (since schema 1.20.0) · `MBS:FM.RunScript` | The call's execution context: the target of a *Perform Script on Server* step (164) / *… with Callback* (210) runs **server-side** — this is the platform-binding evidence for FileMaker Server. `MBS:FM.RunScript` marks plugin-mediated calls; `NULL` = ordinary Perform Script. "By name" callsites (runtime-computed target) have no static target and no edge |
| `trigger_owner` | `OnFirstWindowOpen`, `OnRecordLoad`, `OnLayoutEnter`, `OnObjectSave`, … | The trigger event type |
| `triggers_script` | canonical event name (`OnObjectSave`, …) · `button_action` · `menu_action` | Trigger mirror vs. Button/GroupedButton/PopoverButton action vs. custom-menu item that performs the script (converter 2.35.0) |
| `reads_field` (ScriptTrigger-carried) | `transaction_parameter_field` | OnWindowTransaction parameter-field candidate (name-resolved, file-local) |
| `parent_layout` (LayoutPart) | `Body`, `Header`, `Footer`, `Title Header`, `Leading Sub-summary`, `Trailing Grand Summary`, `Top Navigation`, … | The part type |
| `breaks_on_field` | part type (e.g. `Leading Sub-summary`) | Which part breaks on the field |
| `sort_field` | `left`, `right` | Which relationship side sorts |
| `sorts_by_valuelist` | `left`, `right` (relationship) · `portal`, `button` (layout object) | Which carrier defines the custom sort |
| `sorts_by_field` | `portal`, `button` | Portal sort vs. button-embedded sort step |
| `restricts_field`, `restricts_object` | `NoAccess`, `ReadOnly`, `Calculation`, … | The access mode of the restriction |
| PrivilegeSet-carried `reads_field`, `reads_variable`, `calls_customfunction`, `calls_pluginfunction` | `<Operation>:<Table>` (e.g. `Delete:Contacts`) | Which Custom-Record-Privilege rule carries the reference |
| calculation-carried roles (`reads_field`, `calls_function`, …) | step calc position (`0`, `1`, …) or calc slot (`Hide`, `Tooltip`, `Condition_1`, `Filter`, `Install`, `Placeholder`, `ScriptTrigger_<id>`, `DisplayCalculations_<i>`, `LabelText_<i>`, chart series keys, …); field slots also `auto_enter` | Which calculation of the owner contains the reference — the DDR calc-anchor suffix (see [XML DDR_INFO](../../xml/catalogs/XML%20DDR_INFO.md)); the slot key that `v_calculation_links` joins on |
| `displays_field` | `table_view_column` · `label_text` | A column of the layout's table view · a merge field typed into a button or popover-button label (FileMaker writes no `FieldList` there; resolved from the label text, counts for where-used like any `displays_field`; on an external table occurrence the edge points into the file that holds the base table) |
| `uses_valuelist`, `validates_by_calc` | `validation` · `validation_message` (message calc) | The reference comes from a field validation (check calc vs. custom-message calc) |
| `has_calculation` | `<Calc_Role>[:<Calc_Index>]` (e.g. `hide`, `conditional_format:2`, `display_calculation:1`, `script_trigger_parameter:2`) | Which slot of the owner the calculation instance is |
| `source_field` | `primary`, `secondary`, `secondary_sort` | Which value-list field slot |
| `summarizes_field` | `List`, `Total`, `Average`, … | The summary operation |

**See also:** [ObjectLinks](ObjectLinks.md) · [LinkRoleRegistry](LinkRoleRegistry.md) · [Object Types](Object%20Types.md)
