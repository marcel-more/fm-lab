# SCA Unused Code

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 14 rules · `rest-api/templates/dashboards/static-code-analysis/unused_code/`

Unused-code rules find the objects nothing points at: scripts never called, fields never read or displayed, layouts never navigated to, value lists attached to nothing. They are powered by the resolved reference graph in [ObjectLinks](../schema/object-catalog/ObjectLinks.md) — "unused" means *no incoming edge of a using kind exists anywhere in the imported catalog*, which is a far stronger statement than a text search could make.

## When to use it

- Sizing a cleanup or a migration: the sum of these lists is the part of the solution you may not have to carry over.
- Before schema changes — an unused field is a free delete; a used one is a project.
- Periodically, as drift control: unused objects accumulate silently, and the count trend over re-imports shows whether the solution is getting cleaner.
- For one object, a module or a list of objects: the analysis test `unused-code` runs the nine *Unused …* rules in that scope ([details](../Wiki/Analysis%20Tests.md#unused-code)).

## Reading the results

All rules here are `info` by design: absence of references is evidence, not proof. The classic escape hatches are listed on each dashboard — scripts started manually or from custom menus, layouts opened by name, value lists used only by an external file that wasn't imported. Delete in review order: empty objects first (no content to lose), then unreferenced ones, and always against a backup. The distinction *empty* vs. *unused* is deliberate — an empty script is a placeholder; an unused script is a decision.

### Unverified findings and entry points

Five rules — *Unused Field*, *Unused Custom Function*, *Unused Value List*, *Unused Script* and *Unused Layout* — mark what they cannot fully judge, the way *Unused Table Occurrence* already does:

- **Unverified.** A file exported without DDR info carries no references from formulas at all, so a field read in a calculation or a custom function called in a formula stays invisible. Findings of such a file stay findings, but the column *Status* reads *Unused (unverified)*, the message says so, and the KPI tile *Without DDR info* filters the list to them (parameter `ddr=without`). Export the file again with DDR info before deleting anything.
- **Entry points.** A script in the Scripts menu or a layout in the layout menu (*Include in menu* checked) can be started or opened by the user even when nothing calls it or navigates to it. *Unused Script* and *Unused Layout* therefore do not report them as findings: the count of findings and the analysis test leave them out, a KPI tile counts them and the table *Entry points* lists them (dataset `entry_points`). Remove such an object from the menu if it is not meant to be reached — then it becomes a finding.

### One definition of usage

The rules for fields, scripts, layouts, custom functions, value lists, base tables, external data sources and privilege sets read their verdict from one analysis table, `v_object_usage` (see [schema 1.40.0](../schema/Schema%20Version%20History.md#1400)). It counts every link role [LinkRoleRegistry](../schema/object-catalog/LinkRoleRegistry.md) marks for where-used — base tables count only their table occurrences — and also feeds the usage counts elsewhere in fm-lab, so *unused* means the same everywhere — how it is counted and what stays invisible (calls from outside, dynamic references) is described in [Usage and References](../schema/Usage%20and%20References.md). *Unused Table Occurrence* reads the usage of occurrences, which that table takes over. A catalog built before schema 1.40.0 has no such table: the rules then report nothing until the next import. The dashboard *Object Usage* (rubric Top) shows the same table as one ranked list across all types — besides the findings also the rarely and heavily used objects and who uses each one.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Unused Script | info | Scripts never called by another script, a button or a custom menu and never started by a trigger; scripts in the Scripts menu are entry points, listed apart | PMD |
| Unused Field | info | Fields with no usage of any kind — every link role [LinkRoleRegistry](../schema/object-catalog/LinkRoleRegistry.md) counts for where-used, including value-list sources, summary fields and sub-summary break fields | PMD |
| Unused Custom Function | info | Functions never called from any calculation, script or other function | PMD |
| Unused Layout | info | Layouts no script, button or file option navigates to; layouts in the layout menu are entry points, listed apart | fm-lab |
| Unused Value List | info | Value lists attached to no field, layout object, sort order or wrapper | fm-lab |
| Unused Table Occurrence | info | Occurrences used nowhere — counting field references in formulas, script steps and on layouts — or used only as a relationship side with no used occurrence beyond them (dead branch or island of the relationship graph); join occurrences between two used ones are kept, findings in files without DDR info are marked unverified ([details](../schema/object-types/TableOccurrence.md#usage-through-fields)) | fm-lab |
| Unused Base Table | info | Base tables with no table occurrence — unreachable in the relationship graph | fm-lab |
| Unused External Data Source | info | External sources referenced by no table occurrence | fm-lab |
| Unused Privilege Set | info | Custom privilege sets assigned to no account | fm-lab |
| Disabled account | info | Accounts that are disabled — stale entries widen the security surface | fm-lab |
| Empty Script | info | Scripts with no steps at all | fm-lab |
| Empty Layout | info | Layouts with no objects at all | fm-lab |
| Script with many disabled steps | info | Five or more disabled steps — commented-out code in script form | fm-lab |
| Variable set but never read | info | Writes with no reader anywhere in the catalog | fmCheckMate |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Error-Prone](SCA%20Error-Prone.md) — the mirror rule: variables *read* but never set
- [ObjectLinks](../schema/object-catalog/ObjectLinks.md) — the reference model behind "unused"
