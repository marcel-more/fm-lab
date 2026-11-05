# SCA Developer Workflow

**Rubric:** [Static Code Analysis (neighboring rubric)](../Wiki/Static%20Code%20Analysis.md) · 6 rules + 1 explorer · `rest-api/templates/dashboards/developer-workflow/`

The developer-workflow rubric surfaces the open work that lives in the code instead of the tracker: TODO and FIXME markers in script comments, on layout objects, and inside calculation comments. The two marker classes are deliberately kept apart — a **FIXME** states a known defect that was shipped (`warning`), a **TODO** describes planned work (`info`) — so a fixable defect never hides inside a pile of nice-to-haves.

## When to use it

- Sprint or release planning: the FIXME lists are shipped defects by the author's own admission — the most honest bug backlog a solution has.
- Taking over a solution — the markers are the previous developer's notes to their future self, now addressed to you.
- Before a customer demo or handover: FIXMEs on layout objects are often visible to end users.

## Reading the results

Matching is case-insensitive and tolerates separators, and covers the common notations (FIXME, FIX ME, FIX IT; TODO, TO DO, TBD, "to be done"…). For calculations, all five calculation slots are scanned (custom-function bodies, field calculations, auto-enter, validation, script-step calculations) — and a marker only counts **inside a comment segment**: a string literal `"TODO"` in a `Substitute()` is not a finding. The *TO-DOs in scripts* explorer complements the counting rules: an inventory across three notations with click-to-filter counts, deliberately without a result value so it stays out of the health check.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| FIXME marker in a script comment | warning | Comment steps carrying a FIXME-class marker | fm-lab |
| FIXME marker on a layout object | warning | Layout text or button label, tooltip, label or panel-title calculation with a FIXME — often user-visible | fmCheckMate |
| FIXME marker in a calculation comment | warning | FIXMEs inside comments across all five calculation slots | fm-lab |
| TODO marker in a script comment | info | Comment steps carrying a TODO-class marker | fm-lab |
| TODO marker on a layout object | info | Layout text or button label, tooltip, label or panel-title calculation with a TODO | fmCheckMate |
| TODO marker in a calculation comment | info | TODOs inside comments across all five calculation slots | fm-lab |
| TO-DOs in scripts (explorer) | — | Inventory across three notations with click-to-filter counts | fm-lab |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Documentation](SCA%20Documentation.md) — whether there are comments to carry markers at all
- [SCA Error-Prone](SCA%20Error-Prone.md) — where a shipped FIXME usually points
