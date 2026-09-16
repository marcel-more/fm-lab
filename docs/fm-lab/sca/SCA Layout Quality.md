# SCA Layout Quality

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 17 rules + 1 explorer · `rest-api/templates/dashboards-custom/static-code-analysis/layout_quality/`

Layout-quality rules inspect what the Layout mode inspector won't tell you at scale: objects referencing deleted fields or value lists, objects lost outside their parent or buried behind a portal, calculations that never evaluate, Classic-theme leftovers, and geometry defects like stacked duplicates or off-layout objects. Because the catalog stores every layout object with its type, geometry, nesting and references, these checks run across thousands of layouts in one query.

## When to use it

- UI modernization projects — the Classic-theme, local-CSS and geometry findings together size the real restyling effort.
- "The button does nothing" / "the field is empty" symptom reports: broken references, out-of-range repetitions and occluded objects are the usual suspects.
- After bulk layout edits or copy/paste sessions — lost objects, stacked duplicates and copy-suffix names are classic paste fallout.

## Reading the results

The `error` tier is reference-level breakage: broken field and value-list references (resolved over numeric IDs, never UUIDs — cross-file references routinely carry stale UUIDs while the object is intact), out-of-range repetitions, commented-out and quoted-constant calculations, nested popovers. The `warning` tier is visibility: objects outside their parent, occluded behind containers, off the layout, stacked duplicates, Classic theme. The `info` tier needs human judgment — *Button without action* can hit decorative icons and inactive button-bar segments (roughly 40 % of buttons in a large solution can appear; filter by context before acting), and tiny "degenerate" text objects are often deliberate spacers. The **layout geometry explorer** is not a rule at all: an inventory of every object with sortable geometry columns and a coordinate-window filter, for inspecting specific layout regions.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Broken field reference | error | Objects referencing a field or table occurrence that no longer exists (ID-resolved, cross-file aware) | fmCheckMate |
| Broken value list reference | error | Objects referencing a value list missing from their file | fmCheckMate |
| Field repetition out of range | error | Objects showing a repetition the field no longer has — empty at runtime | fmCheckMate |
| Commented-out layout calculation | error | Hide/field-entry/tooltip/label calculations that are one big comment — behavior silently disabled | fmCheckMate |
| Hide or field-entry condition is a quoted constant | error | Hide or field-entry formulas pasted with their quotes — they evaluate as a constant | fmCheckMate |
| Popover inside a popover | error | Nested popovers — opening the inner closes the outer | fmCheckMate |
| Object outside its parent | warning | Nested objects clipped or invisible beyond their portal/panel/group bounds | fmCheckMate |
| Object hidden behind a container | warning | Objects fully covered by a portal, tab or slide control — unclickable in Browse mode | fmCheckMate |
| Object outside the layout | warning | Top-level objects past the layout width, below the last part, or in negative coordinates (tolerance slider) | fm-lab |
| Stacked duplicate objects | warning | Same-type siblings with identical bounds — typically a double paste | fm-lab |
| Layout uses the Classic theme | warning | Legacy-metric layouts that miss modern style features and slow WebDirect | fmCheckMate |
| Copied object name | warning | Named objects with copy/paste suffixes or duplicate names — name-based references hit the wrong object | fmCheckMate |
| Object name wrapped in quotes | warning | Quoted names that break `GetLayoutObjectAttribute` / Go to Object | fmCheckMate |
| Button without action | info | Buttons with neither a script call nor a single-step action — review by context | fmCheckMate |
| Group with a single object | info | Groups grouping nothing — leftovers after deleting the other members | fmCheckMate |
| Degenerate layout object | info | Empty texts, zero-extent objects, objects below minimum size (sliders; lines excluded) | fm-lab |
| Local CSS overrides | info | The share of objects styled past the theme — a ratio dashboard per layout, not per object | fmCheckMate |
| Layout geometry explorer | — | Inventory: every object with sortable geometry and a coordinate-window filter | fm-lab |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Code Style](SCA%20Code%20Style.md) — heavy layouts, portal and tab counts
- [SCA Error-Prone](SCA%20Error-Prone.md) — the same breakage class on the script and schema side
