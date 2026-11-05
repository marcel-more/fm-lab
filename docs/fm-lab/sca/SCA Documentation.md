# SCA Documentation

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 4 rules · `rest-api/templates/dashboards/static-code-analysis/documentation/`

Documentation rules answer one question: could someone else take this over? They find the non-trivial scripts without a single comment, the custom functions without a documented contract, and the calculated fields whose formula is left to speak for itself — plus a density metric that grades how well-commented the substantial scripts actually are.

## When to use it

- Preparing a handover, an audit or an external review — the findings list is the documentation backlog.
- Team conventions: the density dashboard makes "we comment our scripts" measurable instead of aspirational.
- Picking where to document first: sort the undocumented list by script length and start at the top.

## Reading the results

All rules are `info` — a missing comment is debt, not a defect. The three binary rules carry a deliberate extra: a filter switch flips the table from *items without a comment* to *items with one*, so the well-documented objects double as in-house examples of the house style. The density rule complements the binary check: it separates real comment steps from whitespace-only placeholder comments and computes a per-script density factor, with the minimum script size on a slider (default 10 steps) so trivial scripts stay out of the statistics.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Undocumented Script | info | Non-trivial scripts (10+ steps) without a single comment step | PMD |
| Custom Function without comment | info | Functions whose formula contains no comment — shared functions need documented contracts | PMD |
| Calculated field without comment | info | Calculated fields with an empty field comment | PMD |
| Script comment density | info | Step count vs. real comments vs. whitespace-only comments, with a density factor per script | fm-lab |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Code Style](SCA%20Code%20Style.md) — the size rules that make missing documentation expensive
- [SCA Developer Workflow](SCA%20Developer%20Workflow.md) — TODO/FIXME markers inside the comments that do exist
