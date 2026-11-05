# SCA Error-Prone

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 22 rules · `rest-api/templates/dashboards/static-code-analysis/error_prone/`

Error-prone rules target patterns that hide real defects: code that silently never runs, references that resolve to nothing, control flow that doesn't balance, and constructs whose failure mode is invisible until a user hits it. This is the rubric with the highest defect density — several rules report at `error` severity because the finding *is* the bug, not a style opinion about it.

## When to use it

- First pass over an inherited or long-grown solution: the errors here are concrete, checkable and usually fixable one by one.
- After large refactorings or deletions — broken lookups, never-set variables and dead window names are classic rename/delete fallout.
- When users report "it sometimes doesn't do anything": commented-out calculations, dead code after `Exit Script` and no-op `Close Window` steps are exactly that symptom.

## Reading the results

Severity is graded by certainty. `error` findings (unbalanced If blocks, broken lookups, removed plug-in functions, Close Window on a never-created name) are defects by construction. `warning` findings are near-certain problems that occasionally have a legitimate reading — a cascading delete can be intended, an `Exit Script` inside a Loop can be deliberate control flow. `info` findings (self-recursion, `Replace Field Contents`, Loop without terminator) are risk inventories: review, don't mass-fix. `variable_read_never_set` deserves a caveat — values can legitimately arrive from outside the exported files (script parameters, other systems), so treat it as a pointer, not a verdict.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| Unbalanced If / End If | error | If/End If nesting that does not balance out | fm-lab |
| Broken lookup | error | A lookup whose source table, occurrence or field no longer exists — the field silently stays empty | fmCheckMate |
| Removed plug-in function call | error | Calls to plug-in functions the vendor has removed — they fail on any current plugin version | fm-lab |
| Close Window targets a never-created name | error | A Close Window naming a window no step in the solution ever creates — a silent no-op | fm-lab |
| Dead code after Exit Script | warning | Executable steps directly after an unconditional Exit/Halt — they can never run | fm-lab |
| Commented-out calculation | warning | A calculation slot whose entire formula is one comment — behavior silently disabled | fmCheckMate |
| Broken comment structure in a calculation | warning | Comment markers that cannot nest (`/*` inside `/*`, stray `*/`) — parts of the formula land on the wrong side of the comment | fmCheckMate |
| Duplicate script name | warning | Two scripts with the same name in one file — "call by name" becomes ambiguous | fm-lab |
| Empty If branch | warning | An If followed immediately by Else/End If — leftover or logic bug | PMD |
| Empty Else branch | warning | An Else immediately followed by End If | PMD |
| Deep If nesting | warning | Steps nested five or more If levels deep | PMD |
| Exit Script inside Loop | warning | Leaving the script mid-loop, skipping loop cleanup | fm-lab |
| Window opened without a later Close Window | warning | Each execution leaks a window; on Server it can silently replace the caller's found set | fm-lab |
| Show Custom Dialog inside Loop | warning | A modal dialog on every iteration | fm-lab |
| Cascading delete relationship | warning | Relationships that delete related records — review each one | fm-lab |
| Cartesian (×) relationship | warning | Cross-product joins relating every record to every record | fm-lab |
| Variable name with spaces | warning | Names only reachable via `${…}` notation — a plain `$name` silently reads something else | fmCheckMate |
| Variable read but never set | info | Reads with no writer anywhere in the catalog — renamed writer or external input | fmCheckMate |
| Loop without Exit Loop If | info | Loops with no reliable terminator step | fm-lab |
| Auto-enter calc overwrites existing value | info | Auto-enter calculations that replace existing values — can clobber user edits | fm-lab |
| Replace Field Contents | info | Whole-found-set rewrites with no undo | fm-lab |
| Self-recursive Script | info | Scripts that call themselves — fine with a solid exit condition, fatal without | fm-lab |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [SCA Layout Quality](SCA%20Layout%20Quality.md) — the broken-reference rules on the layout side
- [SCA Unused Code](SCA%20Unused%20Code.md) — the "never read" counterpart: written but unused
