# SCA Best Practices

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 10 rules · `rest-api/templates/dashboards/static-code-analysis/best_practices/`

Best-practice rules flag settings and constructs that are legal, sometimes even useful — but risky enough that each occurrence deserves a conscious decision: user abort disabled, finds without error capture, sorted relationships, repeating fields, global storage, deprecated plug-in functions. The rubric is the "worth a second look" tier between hard error checks and pure style.

## When to use it

- Periodic hygiene reviews — these findings age well as a checklist, because every entry is either "intended, documented, keep" or a small fix.
- Before performance work: the auto-index and sorted-relationship findings are cheap wins that don't need profiling.
- Tracking modernization debt: the deprecated plug-in rule carries the vendor's documented replacement per finding.

## Reading the results

Most rules are `info` — inventories of decisions, not defects. Two are warnings: *Auto-index field* (indexing "None" with automatic creation still on — the first find silently triggers an uninterruptible index build) and *Deprecated plug-in function call* (still runs today, but the vendor documents a successor, listed in the `replacement` column). *Lookup field* is explicitly an awareness inventory: a lookup snapshots a value at set time, which is often exactly right (freezing a price or address on a document) — it is listed so the intent is on record, not to be "fixed".

*Relationship with sorted records* makes the community recommendation "sort at the portal, not the relationship" decidable per row: a relationship-level sort runs for **every** consumer of the relation, a portal-level sort only where it is displayed. The two consumer columns show how many portals sit on the sorted table occurrence and how many of those carry their own sort anyway; the filter chips isolate the interesting classes — relationships with portal consumers, and the strongest move-the-sort candidates where the portals already sort themselves. A sorted relationship with zero portal consumers pays its sort for nothing visible.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Auto-index field | warning | Indexing set to None with "automatically create indexes" still enabled — a latent index build on first find | fm-lab |
| Deprecated plug-in function call | warning | Calls to functions the vendor documentation marks deprecated, with the documented replacement per row | fm-lab |
| Allow User Abort [Off] | info | Abort disabled — a runaway loop cannot be cancelled | fm-lab |
| Perform Find without Set Error Capture | info | Scripts where a "no records" dialog can interrupt the user mid-script | fm-lab |
| Relationship with sorted records | info | Sorts that run on every relation evaluation — with consumer analysis: how many portals use the relation, and how many of them sort themselves anyway | fm-lab / community |
| Repeating field | info | Fields with more than one repetition — hard to query and report on | fm-lab |
| Global storage field | info | Session-scoped shared state that is easy to overuse | fm-lab |
| Lookup field | info | Fields populated by a lookup (deliberate snapshot semantics) — awareness inventory | fm-lab |
| Layout without Body part | info | Layouts that cannot render records in Form/List view | fm-lab |
| Layout without table context | info | Layouts with no table-occurrence context — stray or utility layouts | fm-lab |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Performance](SCA%20Performance.md) — the loop and index rules this rubric borders on
- [SCA Error-Prone](SCA%20Error-Prone.md) — where a pattern stops being a choice and becomes a defect
