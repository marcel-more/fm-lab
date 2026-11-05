# SCA Code Style

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 17 rules · `rest-api/templates/dashboards/static-code-analysis/code_style/`

Code-style rules measure size, shape and naming: scripts and formulas that have outgrown readability, tables and layouts that carry too much, names that betray a paste accident or a forgotten duplicate. Nothing here is broken — these are the maintainability signals that predict where the *next* defect will be written.

## When to use it

- Estimating maintenance risk: the intersection of *long*, *deeply branched* and *undocumented* is where changes are expensive.
- Onboarding a new developer — the findings map the hairy corners before they stumble into them.
- Naming hygiene sweeps: whitespace, quote and copy-suffix findings are quick, low-risk fixes with real payoff for name-based references.

## Reading the results

All rules are `info` except *Object name with leading or trailing whitespace* (`warning` — the whitespace is invisible in FileMaker's own lists but part of the name, so name-based access breaks in ways that are miserable to debug). The size rules are threshold-based and honest about it: the thresholds are exposed as sliders in the dashboard header (long script default 150 steps, long calculation 2000 characters, wide table 100 fields, …), so "too long" is your call, not the rule's. The copy-suffix rule separates the certain class (` Copy`, ` Kopie`) from the ambiguous numeric class (`Name 2`), which is also how countless deliberate names are built — the latter is a chip, not a default finding.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Object name with leading or trailing whitespace | warning | Invisible spaces/tabs that are part of the name — lookalike names sort and resolve apart | fmCheckMate |
| Long Script | info | Scripts above the step threshold (slider, default 150) | PMD |
| Long Calculation field | info | Formulas above the length threshold (slider, default 2000 chars) | PMD |
| Custom Function with many parameters | info | Five or more parameters — hard to call correctly | PMD |
| Table with many fields | info | Base tables above the field threshold (slider, default 100) | PMD |
| Base Table with many Occurrences | info | More than eight occurrences — a tangled relationship graph | fm-lab |
| Multi-predicate relationship | info | Joins on three or more field predicates | fm-lab |
| Layout with many objects | info | Layouts above the object threshold (slider, default 250) | fm-lab |
| Layout with many portals | info | More than six portals, each pulling a related found set (slider) | fm-lab |
| Tab control with many tabs | info | More than six tab panels (slider) | fm-lab |
| If/Else block asymmetry | info | Long If branches with trivial Else branches — guard-clause candidates (sliders) | fm-lab |
| Global variable used in one script only | info | `$$` variables set and read in a single script — a `$` local says it better | PMD |
| Set Field By Name (dynamic target) | info | Runtime-computed field targets that static analysis and refactoring cannot follow | fm-lab |
| Value list with hard-coded values | info | Custom-values lists that drift out of date | fm-lab |
| Name still carries a duplicate suffix | info | Leftover ` Copy`/` Kopie` names; the numeric suffix class is a separate chip | fmCheckMate |
| Object name wrapped in quotes | info | Names pasted straight out of a calculation, quotes included | fmCheckMate |
| Overlong object name | info | Names above the readability threshold, or at FileMaker's 100-character ceiling (truncation, reported as warning) | fmCheckMate |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Documentation](SCA%20Documentation.md) — the other maintainability axis: comments
- [SCA Layout Quality](SCA%20Layout%20Quality.md) — the layout-object twin of the naming rules
