# Graph Explorer: Data Trace (experimental)

> **Experimental.** The data trace works on real solutions, but its answers are a static approximation and need judgement. Expect noise on widely used fields and variables, ways that stop at boundaries the catalog cannot see through, and gaps wherever a solution relies on its own conventions — see [Limits](#limits). Parameters, response fields and defaults may still change between releases.

The [flow trace](Graph%20Explorer%20Trace%20Mode.md) follows a *process*: which scripts call which, and what they touch. The **data trace** follows a *value*: where the content of one field or variable comes from (**Origin**), and where it flows to (**Usage**). It walks from field to step to variable to parameter to field, across script calls and files, and lists the result as **ways** — one per write site (origin) or read site (usage), each also as a Mermaid diagram.

## Opening the trace

- **Field:** *Trace* in the field's detail view, graph tab or inspect panel.
- **Variable:** *Trace* in the variable's detail view, graph tab or inspect panel. Opened from a variable in a script line, the trace starts **at that step**: for a reading step it shows the setters that can reach it, for a setting step the readers it reaches. *Whole script* in the trace panel removes the anchor; a local variable then covers every setter or reader in its script, a global variable every setter or reader in its file.
- **URL:** `/graph?trace=<uuid>&trace_file=<file>&tmode=data` (add `tdir=down` for usage).

The trace opens with *Origin*; the tabs *Origin* / *Usage* in the ways list switch the direction. Each direction is its own trace, so a switch reloads. The data comes from [GET /api/graph/trace](../rest-api/endpoints/Graph%20API.md#get-apigraphtrace) with `mode=data`.

The data trace needs a catalog of schema 1.43.0 or later, built from the data-flow views `v_dataflow_edges` (every value flow between fields, steps, variables, script parameters and results, formulas and entries) and `v_step_guards` (the enclosing If branch and loops of each step). On an older catalog — or when the data-flow phase of the import failed — the Explorer hides the trace and asks for a re-import.

## What the trace follows

| Hop | Example |
|---|---|
| Step writes field | `Set Field`, `Insert …`, `Replace Field Contents`, `Import Records` (as an entry) |
| Field is read by a step | a step formula reads the field — directly or through `ExecuteSQL` |
| Field into calculation | calculation fields, lookups, summary fields, auto-enter |
| Variable | a step sets `$x` / `$$x`, another step reads it |
| Parameter and result | `Perform Script` passes a parameter; `Exit Script` returns a result to the calling step |
| Entry | manual input on a layout, a button, a script trigger, a menu command, a file trigger, an import, an auto-enter |
| Sink (usage only) | display on a layout, sort, export, find, relationship, value list |

Rules that keep the ways close to what can happen at runtime:

- **Local variables connect only where a setter can reach the reader.** A reader of `$x` is linked to the setters before it in the same script, not to every `$x` in the script. A reader without any reaching setter shows as *not initialized*.
- **Accumulating steps count once.** A chain like `$x = $x & …` is one variable level, so long collection loops do not cut the way at the depth limit.
- **Call context.** A value that enters a sub-script as a parameter returns its result only to the step that called it, not to every caller of the sub-script. Where the call site is unknown (the walk started inside the sub-script), the trace connects to every call site and counts it as *without call context*.
- **Disabled steps are left out** and counted.
- **Conditions are shown, not evaluated.** Fields and variables that only steer (If conditions, SQL filters, repetition numbers) are not followed as data; the *Control edges* switch shows them as leaves.

## Origin

One way per **write site** of the field at level 1: the step, calculation, lookup or entry that gives the field its value. Each way lists its **entries** grouped by kind — "3 buttons · 2 triggers · input on 4 layouts" — and the source fields it reads.

- **Field levels** (default 1): how many field-to-field transitions the trace follows. Rather than raising it for every way, use **Follow source** on one way: its source fields go one level further, and the new ways hang below it.
- **Reset:** write steps that empty the field (`""`) form a collapsed group *Reset* instead of ways of their own; *Resets as ways* lists them.
- **Flow trace:** a writing step opens the [flow trace](Graph%20Explorer%20Trace%20Mode.md) of its script — the way from the value to the process.

## Usage

Usage is usually far wider than origin, so it opens as an **impact list** instead of a graph: groups with counters — *Display*, *Sort*, *Export*, *Find*, *Navigation*, *Relationship*, *Value list*, *Calculation*, *Writes into fields*, *Infrastructure* — expandable to the objects. The read ways (field → step → variable → field …) are listed below it; the graph is available on demand. The *Sinks* switch removes display, sort, export, find, relationship and value list from the count.

## Diagrams

*Diagram* opens a way as Mermaid in the same overlay as the flow trace. The way runs in the direction of the value: entries and sources on the left, the field on the right (origin), or from the field to its readers and targets (usage). Value flow is drawn solid; the flow hops between a script and its steps are dotted. Way **0** is the field-to-field overview of all ways, each edge labelled with its way number. A way that is only approximately backed is marked *approximate* in the list.

## Solution profile

The catalog cannot tell a layout that edits business data from a technical layout that shows every field of a table for scripting, or a shared logging script from a business sub-script. Such objects connect almost everything and drown the relevant ways. The **solution profile** holds this knowledge as declarative rules:

| Rule | Effect in the walk |
|---|---|
| Technical layout | manual input on this layout is no entry |
| Infrastructure script | the walk stops at the script; usage counts it under *Infrastructure* |
| UI state variable | setting and reading count as control, never as data |
| Hub variable | the walk ends at the variable; its readers are only counted |

The rules come from **candidates** the server derives from the catalog (heuristics H1–H4: many same-named layouts showing most fields of their table editable; scripts called from many files whose result nobody reads; variables read mostly in layout objects; variables with very many read sites). Candidates are never applied automatically: the trace panel shows the candidates on the current trace with *Confirm* / *Reject*, and *Manage…* lists all candidates per heuristic for confirming or rejecting in bulk. Only confirmed rules act; rejected candidates do not come back. The panel names what the profile hid ("2 entries from technical layouts hidden"), and *Apply solution profile* switched off shows the purely generic view.

The profile is stored in the solution bundle (`solutions/<id>/state/dataflow_profile.json`), survives re-imports and travels with a solution export. A rule whose object is missing after a re-import is reported as *without object*, not dropped.

## Limits

The data trace reads the solution's structure, not its runtime. Three kinds of limits shape every answer.

### Noise

Statically, every setter of a global variable feeds every reader, every column of an `ExecuteSQL` result counts as a value source (the trace does not know which column a later `GetValue` picks), and a field displayed on hundreds of layouts or a trigger shared by hundreds of layouts produces as many entries. Without a profile the generic view of a large solution is dominated by such connections. Reads through custom functions are followed as well, but only approximately: a function that reads a field or `$$x` makes every formula calling it a reader. Expect to confirm profile candidates before the ways become useful, and read ways marked *approximate* as "possible", not "certain".

### Boundaries

A way stops where the catalog has no static target:

- **Dynamic targets:** `Set Field By Name`, inserts into the active field, `Perform Script` by name, dynamic SQL — counted under *Blind spots*, not followed.
- **Outside the catalog:** plugin functions that read or write fields, JavaScript in web viewers, data that arrives through external sources; an import contributes its source, not a field-to-field mapping.
- **Files without DDR info:** formula references are missing there — fields read in formulas, script parameters and results. Every way through such a file is marked *incomplete?*; re-export with *Include details for analysis tools*.
- **Budgets:** field levels, variable levels, steps per path, node and way limits. A cut way is flagged with the limit that cut it.
- **Profile stops:** an infrastructure script or hub variable you confirmed ends the walk on purpose.

### Conventions

Many solutions encode meaning in naming and structure that a generic analysis cannot know: which layouts are search or filter layouts, which scripts only find records, which table is current when a step writes (the layout context), naming schemes of table occurrences. The trace treats all of these generically — a `Set Field` on a search layout is a write like any other, and a branch that depends on the current layout is shown, not resolved. The solution profile covers the four rule kinds above; it does not yet express layout-context or naming conventions.

## Address bar

| Parameter | Meaning |
|---|---|
| `tmode=data` | data trace (instead of the flow trace) |
| `tdir=down` | *Usage* (default *Origin*) |
| `flevels=<n>` | field levels (1–10, default 1) |
| `ctl=1` | show control edges |
| `sinks=0` | without sinks (usage) |
| `reset=1` | resets as ways |
| `profile=off` | generic view without the solution profile |
| `expand=<way IDs>` | ways followed with *Follow source* |
| `tstep=<step uuid>`, `trole=read\|set` | step anchor of a variable start |

Parameters at their default stay out of the URL.

## See also

- [GET /api/graph/trace](../rest-api/endpoints/Graph%20API.md#get-apigraphtrace) — `mode=data` parameters and response, [the profile endpoints](../rest-api/endpoints/Graph%20API.md#get-apigraphtraceprofile)
- [Graph Explorer Trace Mode](Graph%20Explorer%20Trace%20Mode.md) — the flow trace of scripts and layouts
- [Graph analysis](4%20Code%20Analysis%20Approaches.md#3-graph-analysis)
