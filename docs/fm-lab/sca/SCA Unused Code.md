# SCA Unused Code

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 14 rules · `rest-api/templates/dashboards/static-code-analysis/unused_code/`

Unused-code rules find the objects nothing points at: scripts never called, fields never read or displayed, layouts never navigated to, value lists attached to nothing. They are powered by the resolved reference graph in [ObjectLinks](../schema/object-catalog/ObjectLinks.md) — "unused" means *no incoming edge of a using kind exists anywhere in the imported catalog*, which is a far stronger statement than a text search could make.

## When to use it

- Sizing a cleanup or a migration: the sum of these lists is the part of the solution you may not have to carry over.
- Before schema changes — an unused field is a free delete; a used one is a project.
- Periodically, as drift control: unused objects accumulate silently, and the count trend over re-imports shows whether the solution is getting cleaner.

## Reading the results

All rules here are `info` by design: absence of references is evidence, not proof. The classic escape hatches are listed on each dashboard — scripts started manually or from custom menus, layouts opened by name, value lists used only by an external file that wasn't imported. Delete in review order: empty objects first (no content to lose), then unreferenced ones, and always against a backup. The distinction *empty* vs. *unused* is deliberate — an empty script is a placeholder; an unused script is a decision.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Unused Script | info | Scripts never called by another script and never started by a trigger | PMD |
| Unused Field | info | Fields not read, displayed, set, found, sorted, imported or exported anywhere | PMD |
| Unused Custom Function | info | Functions never called from any calculation, script or other function | PMD |
| Unused Layout | info | Layouts no script ever navigates to | fm-lab |
| Unused Value List | info | Value lists attached to no field, layout object, sort order or wrapper | fm-lab |
| Unused Table Occurrence | info | Occurrences serving as no layout context, portal source, GTRR target or relationship side | fm-lab |
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
