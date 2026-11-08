# Usage and References

Part of the [FM-Lab schema](Schema.md) · analysis table `v_object_usage` · since schema 1.40.0

fm-lab shows two numbers for an object: how many objects **use** it, and how many **references** point at it. They answer different questions, are counted from the same links in [ObjectLinks](object-catalog/ObjectLinks.md), and both cover only what can be read from inside the imported solution. This page says how each number is counted and what neither of them can see.

## Two numbers, two questions

| Term | Definition | Question it answers |
|---|---|---|
| **Usage (internal)** | The number of distinct objects of the solution that use the object at least once. A layout counts once, however many of its objects show the field; a script counts once, in however many steps it reads the field. | In how many places do I have to check or follow up if I rename, change or delete it? `0` = nothing inside the solution points at it |
| **References** | Every place where an object refers to the target in a given role — a field on a layout, a field in a formula, a *Set Field* step. Identical places of one object are one row in the list, marked ×N. | How often does the object occur? (scope of a refactoring, search and replace) |

Example: the field `Invoices::InvoiceID` sits on three layouts — five times on *Invoice Detail*, once each on *Invoice List* and *Print* — and two scripts read it, one of them in four steps. Usage: **5** objects (three layouts, two scripts). References: **12** (seven placements, five script references).

The web frontend writes both the same way everywhere: *Used internally by 5 objects · 12 references*. In the search the column is **Usage (internal)**.

## How usage is counted

Usage counts the incoming links whose role [LinkRoleRegistry](object-catalog/LinkRoleRegistry.md) marks for where-used (`Counts_For_Where_Used`). One type has an exception: a base table counts only its table occurrences.

| Object type | Roles that count | Incoming links that do not count |
|---|---|---|
| Field | `breaks_on_field`, `displays_field`, `exports_from_field`, `finds_in_field`, `imports_to_field`, `inputs_to_field`, `left_field`, `lookup_source`, `navigates_to_field`, `reads_field`, `references_field`, `right_field`, `sets_field`, `sort_field`, `sorts_by_field`, `source_field`, `summarizes_field`, `validates_by_calc` | `restricts_field` (privilege restriction), `has_calculation` (containment) |
| Script | `calls_script`, `triggers_script` | `trigger_script` — the trigger node's own link; the same trigger is counted as `triggers_script` from the object that carries it |
| Layout | `navigates_to_layout`, `default_layout` | `parent_layout` (its own layout objects), `restricts_object` |
| Custom function | `calls_customfunction`, `validates_by_calc` (field validation) | — |
| Value list | `uses_valuelist`, `sorts_by_valuelist`, `source_valuelist` | — |
| Base table | `base_table` (table occurrence → base table) | `parent_table` — its fields belong to it, they do not use it |
| External data source | `data_source` | — |
| Privilege set | `privilege_set` | — |
| Table occurrence | `context_table`, `portal_context`, `navigates_to_to`, `source_table`, `lookup_context`, `lookup_relationship`, `related_values_from`, plus every `Table::Field` reference in formulas, script steps and on layouts (see [usage through fields](object-types/TableOccurrence.md#usage-through-fields)); a relationship with cascade delete counts for the occurrence whose records it deletes | `left_table`, `right_table` — being a relationship side alone is no usage |
| Relationship | derived: a relationship is dead when one of its occurrences is (`dead_island`, `dead_branch`), otherwise `used`; no number | — |

The registry also marks roles toward types that have no usage number of their own: `calls_function` and `displays_symbol` (built-in functions), `calls_pluginfunction` (plug-in functions), `reads_variable`, `sets_variable` and `displays_variable` (variables), `opens_menu` (custom menus), `installs_menuset` and `uses_menuset` (custom menu sets), `uses_theme` (themes), `grants_privilege` (extended privileges), `auto_login_account` (accounts) and `left_table` / `right_table` for the relationship graph. Built-ins, plug-in functions and step types show their own usage count from the aggregate lists.

### Which object counts as the user

| Source of the link | Counts as |
|---|---|
| Layout object, layout part | its layout |
| Script step | its script — script links are already recorded on the script |
| anything else | the source object itself |

### Usage classes

`v_object_usage.Usage_Class` turns the number into a verdict without a threshold:

| Class | Meaning |
|---|---|
| `used` | at least one usage |
| `unused` | no usage — a finding of the unused-code rules ([SCA Unused Code](../sca/SCA%20Unused%20Code.md)) |
| `entry_point` | no usage, but a script in the Scripts menu or a layout in the layout menu: the user can start or open it |
| `builtin` | no usage, but a built-in privilege set (present in every file, cannot be deleted) |
| `relationship_bridge`, `dead_branch`, `dead_island` | table occurrences only, from the relationship graph (see [TableOccurrence](object-types/TableOccurrence.md#usage-through-fields)) |

`Low_Confidence` marks objects in files exported without DDR info: references from formulas are missing there, so a `0` is unverified.

## How references are counted

A reference is one link per place: each layout object that shows the field, each formula slot, each script that reads it in a step. A script that sets the same field in four steps carries four links; the references tab shows them as one row with ×4, and every counter of the tab — section heading, direction buttons, type and role chips — adds up the ×N, so it matches the header.

Two kinds of link are not references of their own:

- **The layout's summary link to its fields.** Besides the link from every layout object to its field, the catalog keeps one `displays_field` link without subrole per layout and field, so that a layout can list *its* fields in its references tab. It duplicates the layout-object links and does not count; on a field's page it is hidden. The table-view column of a layout (`displays_field` with subrole `table_view_column`) stays a reference of its own.
- **Containment.** A field belongs to its base table (`parent_table`), a layout object to its layout (`parent_layout`). The tab lists these under *Structurally contained by* / *Structurally contains*, not under *Used by* / *Uses*.

## What is not counted

Both numbers see only what the imported files say about each other. Two kinds of use stay invisible, and a `0` is therefore a review candidate, not a delete recommendation.

**A. Use from outside the solution**

- Scripts started by a server schedule, the Data API, OData, an `fmp://` URL, AppleScript or ActiveX, a plug-in or another application, or from a file that was not imported.
- Fields read or written through the Data API or OData, changed by a plug-in, filled by an import from outside.
- Layouts used as the context of a Data API request, or opened by WebDirect or a URL.
- Table occurrences queried through OData, ODBC or JDBC.

**B. Dynamic references inside the solution**

- *Perform Script* by name, *Go to Layout* by a calculated name, `GetField`, `Evaluate`, *Set Field by Name*.
- Names inside `ExecuteSQL` strings.
- References from formulas in a file exported without DDR info (see `Low_Confidence` above).

## Where the numbers appear

- **Search** — the column *Usage (internal)* on every row (a click opens the incoming references grouped by object), the sort option and the filter *Usage ≤ / ≥ n* ([Search API](../rest-api/endpoints/Search%20API.md#usage)).
- **References tab** — the header *Used internally by n objects · m references*; the two numbers switch between the view **by object** (one row per using object, its references folded out) and **all references** ([References API](../rest-api/endpoints/References%20API.md), `meta.usage` and `Counts_As_Usage`).
- **Analysis test *Unused Code*** — the unused-code rules read the class from the same table ([SCA Unused Code](../sca/SCA%20Unused%20Code.md)).
- **Dashboard *Object Usage*** (rubric Top, `rest-api/templates/dashboards/top/object_usage/`) — one list across all types, sorted by usage with the unused and rarely used objects first: tiles *used*, *rarely used* (at most n using objects, slider, default 2), *heavily used* (top 5 % of the type), *entry points (menu)*, *unused* (the unused-code findings plus the dead relationships) and *without DDR info*, a multi-select type filter and the app-level file filter. A row opens *Who uses the selected object* — one row per using object, so its row count is the usage and its reference sum the references; a table occurrence links on to the path analysis of *Table Occurrence Usage*, a relationship lists its two occurrences with their class.

## In the catalog

| Column of `v_object_usage` | Content |
|---|---|
| `Usage_Owners` | usage (internal) — the number shown everywhere |
| `Usage_Refs` | references |
| `Usage_Users` | distinct source objects before the layout-object → layout folding (used only in the calculation) |
| `Usage_Roles`, `Usage_Files`, `Cross_File` | counting roles, number of source files, used from another file |
| `Entry_Point`, `Key_Field`, `Low_Confidence`, `Usage_Class` | menu entry point, match field of a relationship, file without DDR info, verdict |

```sql
-- Rarely used fields, with both numbers
SELECT Object_Name, File_Name, Usage_Owners AS usage, Usage_Refs AS refs
FROM v_object_usage
WHERE Object_Type = 'Field' AND Usage_Class = 'used' AND Usage_Owners <= 2
ORDER BY Usage_Owners, Object_Name;
```
