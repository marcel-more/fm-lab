# SCA Performance

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 20 rules · `rest-api/templates/dashboards/static-code-analysis/performance/`

Performance rules flag constructs that are cheap once but expensive in aggregate: work repeated inside loops, calculations re-evaluated per displayed record, step *sequences* and *options* that cause avoidable network round trips, and index settings that defer their cost to the first find. Most of them are structural — they don't need timing data, because the pattern itself predicts the cost.

## When to use it

- A solution "feels slow" and you want a ranked list of structural suspects before profiling anything.
- A solution is fine on the LAN but slow for remote users — the WAN pattern family targets exactly the hidden per-display and per-hop network costs.
- Before moving a solution to WebDirect or FileMaker Server, where per-iteration round trips and render cost multiply.
- As a review gate: loop bodies are where a harmless-looking edit most often introduces a quadratic cost.

## Reading the results

The `*_in_loop` family flags a *step inside a Loop block*, computed from the per-step nesting model — not a guess from step order. A finding is a candidate, not a verdict: a `Perform Find` in a loop over ten records is fine; the same loop over fifty thousand is not. The two unstored-calculation rules complement each other — one lists the fields, the other ranks the layouts that display many of them (that is where the cost actually lands, once per visible record — weighted by view type, since list views and portals repeat the evaluation per row). `field_index_minimal_locked` and the *Auto-index field* best-practice rule are the index traps: settings that save nothing today and trigger an uninterruptible index build on the first find.

The **WAN pattern family** encodes community-established remote-performance practice, each rule with its published sources in the rule metadata. The sharpest of them is the step pair *Go to Layout → Enter Find Mode*: Claris documents that switching the layout first downloads the first records of the target context, which the find then discards — swapping the two steps is a free fix with identical behavior. Its siblings follow the same idea of avoidable network work: a Refresh Window that flushes cached join results forces every related record to reload; a Pause step silently ends a Freeze Window, so everything after it renders mid-script; an unstored calculation calling `Get(CurrentHostTimestamp)` asks the server for its clock on every render. Two heuristic members stay `info` by design: navigation-heavy scripts without Freeze Window (threshold slider, with a *called via PSoS* context column — server-side scripts have no window to freeze) and auto-enter calculations that traverse relationships on every write.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Perform Find inside Loop | warning | A full find triggered on every iteration | fm-lab |
| Sort Records inside Loop | warning | Sorting per iteration — rarely intended | fm-lab |
| Commit Records inside Loop | warning | A database write on every iteration | fm-lab |
| Go to Layout inside Loop | warning | A forced context switch on every iteration | fm-lab |
| Go to Related Record inside Loop | warning | Context and found-set switch per iteration | fm-lab |
| Insert from URL inside Loop | warning | A network request fired per iteration | fm-lab |
| Open URL inside Loop | warning | An external handler launched per iteration | fm-lab |
| Export Records inside Loop | warning | A file written on every iteration | fm-lab |
| Deeply nested Loop | warning | Three or more nested Loops — work multiplies per outer pass | fm-lab |
| Unstored calculation field | warning | Calculations recomputed on demand, once per displayed record | fm-lab |
| Layouts with unstored calculations | warning | Layouts ranked by displayed unstored calculations, with view type and portal placements | fm-lab |
| Enter Find Mode after Go to Layout | warning | The step pair that downloads the target layout's records only for the find to discard them — swap the steps | Claris / community |
| Refresh Window flushing cached joins | warning | Flush options that discard relationship caches and force related records to reload from the server | Claris / community |
| Freeze Window ended by Pause | warning | A Pause step that silently cancels the freeze — the window renders mid-script | Claris / community |
| Unstored calculation with host round trip | warning | `Get(CurrentHostTimestamp)` in a displayed unstored calculation — a server request per render | Claris / community |
| Navigation script without Freeze Window | info | Scripts hopping across layouts with the screen repainting on every hop (threshold slider, PSoS context) | community |
| Auto-enter calculation crossing relationships | info | Auto-enter formulas that read related fields — a relationship traversal on every write | community |
| OnRecordLoad trigger | info | Triggers that fire for every record scrolled into view | fm-lab |
| Minimal index with automatic indexing on | info | An index cleared to Minimal that FileMaker will silently rebuild anyway | fmCheckMate |
| ExecuteSQL range without BETWEEN | info | Range conditions written as `>=`/`<=` instead of `BETWEEN` — the engine evaluates two conditions and intersects the results where a single range scan would do | fm-lab / community |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Best Practices](SCA%20Best%20Practices.md) — the *Auto-index field* sibling trap, and the sorted-relationship rule with its consumer-portal analysis
- [SCA Code Style](SCA%20Code%20Style.md) — heavy layouts and portal counts (render cost)
- [Analysis Tests](../Wiki/Analysis%20Tests.md) — the WAN rules ship bundled as the tests *WAN Script Patterns*, *Layout Render Performance* and *Schema Performance* (keyword `wan`); the ExecuteSQL rule ships as the test set *SQL Performance Checks*
