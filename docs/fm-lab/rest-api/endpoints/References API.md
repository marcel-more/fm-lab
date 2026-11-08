# References API

Dependency lookups over the resolved link graph (`ObjectLinks`): what an object uses and where it is used (`/references`), which references an object could have but does not (`/references/candidates`), and which objects inside an open container reference a given origin (`/back-references`).

All endpoints are clone-aware — see [Clone disambiguation](../REST%20API%20Conventions.md#clone-disambiguation-file-ambiguous_uuid).

---

## GET /api/references

Inbound and outbound references of one object.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `uuid` | string | — | **Required.** Object UUID |
| `file` | string | — | Clone scoping of the focus object |
| `direction` | enum | `all` | `all` · `parent` (who uses this object) · `child` (what this object uses) · `recursive` |
| `link_type` | enum | `operational` | `operational` · `structural` · `all` |
| `origin` | string | — | Origin object UUID (`?ref=` cross-reference); for pseudo aggregate types the reachable rows are flagged with `Origin_Hit` |
| `limit` | integer | `100` | |
| `format` / `meta` / `debug` | | | Standard ([REST API Output Formats](../REST%20API%20Output%20Formats.md)) |

**Response `data`** is a **flat row list**; the column set depends on `direction`. The default `direction=all` gives every row a `direction` field (`child` / `parent`) plus neutral identity columns, while `direction=child` / `parent` return the directed `Target_*` / `Source_*` column names instead:

```json
[
  { "direction": "parent", "uuid": "…", "Object_Type": "LayoutObject", "Object_Name": "Button @ (8,598)",
    "File_Name": "Contacts", "Link_Role": "triggers_script",
    "Subrole_Class": "button_action", "Subrole_Detail": "button_action", "Is_Cross_File": false,
    "Container_UUID": "…", "Container_Type": "Layout", "Container_Name": "Order Entry", "Container_File": "Contacts",
    "Trigger_UUID": null, "navigable": true, "Call_Count": 1 },
  { "direction": "child", "uuid": "…", "Object_Type": "Field", "Object_Name": "Order_Total",
    "File_Name": "Contacts", "Link_Role": "sets_field",
    "Subrole_Class": null, "Subrole_Detail": null, "Is_Cross_File": false,
    "Container_UUID": null, "Container_Type": null, "Container_Name": null, "Container_File": null,
    "Trigger_UUID": null, "navigable": true, "Call_Count": 1 }
]
```

Link roles (`calls_script`, `sets_field`, `displays_field`, …) describe *how* an object is referenced. `link_type=operational` (the default) covers actual usage; `structural` adds containment/organizational links. Pseudo aggregate types (`ScriptStepType`, `BuiltinFunction`, …) are supported through a dedicated resolver.

**Slot classes (`Subrole_Class` / `Subrole_Detail`, additive).** Where the underlying edge carries a subrole (the calc slot the reference lives in), each row also reports:

- `Subrole_Class` — the slot class, normalized onto the calc_kind vocabulary of the calculation catalog: `hide`, `conditional_format`, `tooltip`, `button_action`, `portal_filter`, `web_viewer_url`, `placeholder`, `popover_title`, `active_segment` (button-bar active-segment formula), `script_trigger_parameter`, `auto_enter`, `validation`, `on_server` (Perform Script on Server), `mbs_runscript`, `menu_install`, `menu_action` (custom-menu item performs the script). `Condition_N` collapses into `conditional_format`; unknown subroles pass through raw (never swallowed). Positional script-slot indices (and `XML`/`XSL`) are suppressed to `null`, so script rows keep their aggregated form — a script that reads a field in N steps stays **one** row with `Call_Count` = N.
- `Subrole_Detail` — the raw value(s) behind the class: for `direction=all` the aggregated distinct raw subroles of the row (e.g. `Condition_1, Condition_2`), in the ungrouped `child`/`parent` branches the single raw value. `null` whenever `Subrole_Class` is `null` (direction=all).
- `Subrole_Event` — additive on rows of class `script_trigger_parameter`: the `ScriptTrigger_<id>` slot(s) resolved to canonical trigger event names via the curated reference database (fm_spec ≥ 1.18.0), e.g. `OnObjectValidate`; aggregated rows yield a distinct list in `Subrole_Detail` order. Complete-or-absent contract: the field is omitted when the reference database is not attached, predates 1.18.0, or any slot of the list cannot be resolved — clients degrade to the class label.

This distinguishes e.g. a field that *hides* 52 layout objects (`reads_field` + `hide`) from one that *colors* 16 (`reads_field` + `conditional_format`). Structural rows benefit too: `has_calculation` children report their calc_kind, `trigger_owner` the event name, `parent_layout` the part type — passed through raw.

**Trigger vs. button action on `triggers_script`.** The `triggers_script` edge (owner → Script; the owner is a layout object, a layout or the file) carries a subrole: the canonical trigger event (e.g. `OnObjectSave`, raw source passthrough), or `button_action` for Button/GroupedButton/PopoverButton actions. A custom-menu item that performs the script carries `menu_action` (source type `CustomMenuItem`). On the script's reference list the aggregate decomposes into named event rows plus separate `button_action` rows, each filterable via the role chips. The attribution is reconstructed per (owner, script) group as a multiset, not per individual edge; catalogs whose mirrors carry no subrole render unfiltered until re-imported.

**Trigger mirror consolidation (caller direction).** A trigger is stored twice in the link graph: as the granular `trigger_script` edge of its ScriptTrigger sub-node and as the `triggers_script · <event>` mirror edge of its owner — a deliberate two-layer model in which **only the owner mirror counts for where-used** (the granular `trigger_script` edge never does). To keep caller lists free of that duplication, the references endpoint suppresses the granular row whenever its mirror is visible in the list. Display layer only — `ObjectLinks` and the graph are untouched. Consolidated mirror rows carry `Trigger_UUID`: the address of the ScriptTrigger sub-node, so clients can still jump to the trigger's detail view (`null` on `button_action` and `menu_action` rows and every other role).

**Usage of the object (`meta.usage`).** With `meta=true` the response meta carries `usage` = `{ owners, users, refs, class }` — the object's usage as the [search column](Search%20API.md#usage) shows it (`v_object_usage`, schema 1.40.0+). `owners` counts using objects with a layout object counted as its layout, `refs` the references. Each incoming row then carries `Counts_As_Usage`: the counting rows add up (Σ `Call_Count`) to `refs` and their using objects to `owners`; rows that are no usage (containment, privilege restrictions, the granular `trigger_script` edge) carry `false`. Absent for types without a usage notion and on older catalogs. Definitions and limits: [Usage and References](../../schema/Usage%20and%20References.md).

**Layout → field summary link.** Besides the link from each layout object to its field, the catalog keeps one `displays_field` link without subrole per layout and field. It is listed on the layout (outgoing — the layout's fields) and omitted on the field (incoming), where it would duplicate every placement.

**Rows without an edge of their own (read paths).** Two relations live in catalog tables, not in `ObjectLinks`; the endpoint appends them as rows with a role that has no registry entry and never counts for where-used:

- `uses_table_occurrence` — on a table occurrence, the usages a `Table::Field` reference creates (it links only the field), grouped by category in `Subrole_Class` (operational rows; meta `to_usage`). See [TableOccurrence](../../schema/object-types/TableOccurrence.md).
- `parent_part` — on a [layout part](../../schema/object-types/LayoutPart.md) the objects of the part (`direction` `parent`, `Subrole_Class` = object type, container = the layout), on a layout object its part (`direction` `child`). Read from `LayoutObjects.Part_Seq` — every layout object already hangs on its layout through `parent_layout`, an edge to the part would double it. Structural rows (`link_type=structural` or `all`); meta `part_members` = `{ available, rows, total, truncated }`, `available: false` on catalogs that predate the part assignment (no rows, re-import).

Both respect `limit` and `file` like the edge rows; graph, reference counts and candidates do not see them.

`format=mermaid` / `mermaid-raw` render the reference set as a diagram — see [mermaid](../REST%20API%20Output%20Formats.md#mermaid-mermaid-raw).

## GET /api/references/candidates

The reference types an object **could** have but does not — the "not referenced" row of the references tab. The endpoint evaluates a curated candidate matrix for the focus object and returns one status per candidate, so the web frontend, other clients and agents share the same answer.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `uuid` | string | — | **Required.** Object UUID |
| `file` | string | — | Clone scoping of the focus object |

**Candidate.** A candidate is a direction (`in` = the counterpart references the focus, `out` = the focus references the counterpart), a **type group** (one or more counterpart types that answer the same question) and a **role set**. It is met as soon as one edge in that direction connects the focus with a type of the group through one of the roles. Matching is role-exact, not type-exact: a layout's own layout objects reach it through `parent_layout` (containment), which never meets the candidate "something navigates to this layout" (`navigates_to_layout`).

**Response `data`** — one entry per active candidate:

```json
[
  { "direction": "in", "types": ["Script", "LayoutObject"], "roles": ["navigates_to_layout"],
    "status": "present", "direct": 5, "indirect": 0 },
  { "direction": "out", "types": ["Variable"], "roles": ["reads_variable", "displays_variable"],
    "status": "missing", "direct": 0, "indirect": 0, "aggregate": true },
  { "direction": "out", "types": ["ValueList"], "roles": ["uses_valuelist", "sorts_by_valuelist"],
    "status": "indirect", "direct": 0, "indirect": 2, "aggregate": true, "via": "LayoutObject" }
]
```

| Field | Meaning |
|---|---|
| `status` | `present` = a direct reference with a candidate role exists · `indirect` = met only through aggregate members (a layout's own layout objects) · `missing` = neither |
| `direct` / `indirect` | Number of **distinct counterpart objects**, not edges — directly and through the aggregate members |
| `aggregate` | `true` when the candidate also evaluates the aggregate members |
| `via` | Aggregate member type, present when `indirect` > 0 |
| `caveat` | Known blind spot: `scriptCallers` (incoming script candidates — dynamic calls such as Perform Script by name, fmp URLs and external calls are not resolved) · `toFieldAccess` (table occurrence ← layout — field access through a table occurrence creates no edge to the occurrence) |

**Response `meta`** is always included:

| Field | Meaning |
|---|---|
| `focus_type` / `focus_subtype` | Object type of the focus; subtype used for gating (layout object control type, variable scope) or `null` |
| `aggregate` / `aggregate_members` | Aggregate member type (`LayoutObject` for layouts) and how many members were evaluated |
| `suppressed[]` | Candidates that were dropped, each with `direction`, `types` and `reason`: `subtype` (gated out by the focus subtype), `not_in_solution` (none of the counterpart types exists in the solution), `roles_unregistered` (no candidate role is a registered where-used usage role) |
| `execution_time_ms` | Total evaluation time |

**Which object types have candidates.** Script, Layout, LayoutObject, Field, TableOccurrence, BaseTable, ValueList, CustomFunction, BuiltinFunction, PluginFunction, Variable, Theme, CustomMenuSet, CustomMenu, PrivilegeSet, ExtendedPrivilege and ExternalDataSource. All other types (Relationship, Account, File, Folder, LayoutPart, ScriptStep, ScriptTrigger, Calculation, CustomMenuItem, PluginComponent) return an empty list — they are structural sub-nodes or always carry their references. Outgoing candidates exist only for the logic carriers Script, Layout and LayoutObject; for every other type "no outgoing reference" is the normal case.

**Rules behind the matrix.**

- **Usage roles only.** Candidate roles are usage roles that count for where-used (`LinkRoleRegistry`); containment (`parent_*`, `has_calculation`, `trigger_owner`, …), restriction (`restricts_*`), singletons (`default_layout`, `auto_login_account`) and the satellite `trigger_script` are never candidates. The one marked exception is `contains_menu` for custom menus, which is containment but the actual use of a menu. Each role is checked against the solution's registry at runtime; a role missing there is dropped and logged.
- **Type groups.** Counterpart types that answer the same question form one group, e.g. the surface entries of a script (layout object button, layout or file trigger, custom-menu item) — one hit meets the whole group.
- **Layout aggregate.** For layouts, the outgoing candidates evaluate the layout plus its own layout objects (sources of `parent_layout` edges onto the layout, same file). Variables, custom functions and value lists of a layout live on its layout objects, so "this layout uses no variables" refers to the layout as a whole.
- **Subtype gating.** A layout object gets `→ Field` only as a field control (Edit Box, Drop-down List, Pop-up Menu, Checkbox Set, Radio Button Set, Drop-down Calendar, Container, Concealed Edit Box) and `→ ValueList` only as a list control (Drop-down List, Pop-up Menu, Checkbox Set, Radio Button Set) — then "missing" is a real finding. A local `$` variable gets only `← Script`; global and superglobal variables also `← LayoutObject`. When the subtype source is absent from an older catalog, gating is skipped and the candidate stays active.
- **Existence filter.** A candidate is dropped when none of its counterpart types exists in the solution (no plugin functions, no custom menu sets, …); it then appears in `meta.suppressed`.
- **Pseudo types.** `BuiltinFunction` and `PluginFunction` have no file; for these foci the file scoping does not apply.

"Missing" always means **no statically resolvable reference**, never "unused" — dead-code verdicts stay with the Analysis Tests ([Tests API](Tests%20API.md)).

The matrix lives in `rest-api/src/config/reference-candidates.js`; adding or removing a candidate is a configuration change. The unit test `reference-candidates-config.test.js` checks it against the registry and the coverage fixtures and fails on usage roles that appear for a candidate pair without being listed (new converter roles).

## GET /api/back-references

Given an open destination container (a Layout, Script or Custom Function) and an origin object, return every object *inside the destination* that references the origin. Frontends use this to pre-seed cross-reference highlights when navigating with `?ref=`.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `destination` | string | — | **Required.** Container UUID (real or synthetic sub-object UUID) |
| `origin` | string | — | **Required.** Origin UUID **or** object name |
| `mode` | enum | `auto` | `uuid` · `name` · `auto` (UUID first, then name lookup) |
| `dest_file` / `origin_file` | string | — | Clone disambiguation per side |

**Response `data`:** `destination` and `origin` descriptors, `matches[]` (the referencing objects inside the container) and `match_strategy` (`uuid` · `name` · `name-fallback` · `unresolved`). An unresolvable origin is not an error: the response is `200` with `origin: null` and empty `matches`, so clients can show a "not found" state.

**ScriptTrigger origins.** A synthetic script-trigger sub-node (`trig_<slot>_…`) is referenced by nothing inside its layout, so the standard lookup would always come back empty for the "open container with `?ref=`" navigation. When the origin is a ScriptTrigger whose owner is a LayoutObject inside the destination layout, the owner object is therefore returned as the match (role `trigger_owner`) — the canvas highlights the object carrying the trigger. Layout- and file-level triggers are deliberately excluded and keep their empty match list (the layout's properties panel highlights those trigger rows directly via the trig-UUID).

---

See also: [Graph API](Graph%20API.md) (visual/graph traversal of the same links), [Objects API](Objects%20API.md).
