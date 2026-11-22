# Graph Explorer: Trace Mode

The Graph Explorer's **trace mode** follows one flow instead of every edge. For a script or layout it collects the call chain up and down, the objects those scripts touch, and the script triggers of layouts the flow enters. Next to the graph it lists the **ways**: how the script is reached, and what happens when it runs. Every way opens as a Mermaid diagram.

Open it from a script or layout (*Trace* in the graph tab or in the inspect panel), with the [fm-trace](../skills/Skill%20fm-trace.md) skill, or by URL (`/graph?trace=<uuid>&trace_file=<file>`). The same *Trace* button on a field or variable opens the **data-flow trace** instead (experimental, see [Graph Explorer Data Trace](Graph%20Explorer%20Data%20Trace.md)); it starts with *Origin* and switches to *Usage* in the tabs of the ways list. Opened from a variable in a script line, it starts at that step; *Whole script* in the trace panel removes the anchor. The data comes from [GET /api/graph/trace](../rest-api/endpoints/Graph%20API.md#get-apigraphtrace).

## What the trace follows

The trace works step by step. Calls, field and variable touches and `Go to Layout` come from the script steps themselves, not from the script-level edges:

- **Disabled steps are left out.** A script that is only called from a disabled step does not appear, and neither does the trigger cascade behind a disabled `Go to Layout`. The *Disabled steps* switch in the trace panel follows them again.
- **Every call carries its call sites.** An edge script → script lists the calling steps with their condition (`If …`, `Else If …`, `Else`), loop, server call (Perform Script on Server), parameter and the steps that read the script result. The edge tooltip and the inspect panel show them; a click opens the calling script at that step.
- **Conditions are shown, not evaluated.** The catalog knows that a call sits under `If $mode = "new"`, not whether that is ever true. An edge whose call sites all sit under a condition is dashed.
- **Calls after `Exit Script` / `Halt Script`** in the same block are marked *unreachable*. The edge stays in the graph.
- **Calls without a static target** (Perform Script by name, or a target outside the catalog) appear as a red diamond at the calling script.

The trace needs a catalog of schema 1.43.0 or later. On an older catalog the Explorer hides *Trace* and a deep link shows a hint to re-import the solution.

**Files without DDR info.** A file exported without *Include details for analysis tools* carries no formula references: fields read in formulas, script parameters and script results are missing there. The trace panel then shows a yellow hint naming the file, the effect line of a script from that file ends with *(without formula references)*, and in the data-flow trace every way through the file is marked *incomplete?*. Field and script detail views show a *Without DDR info* badge. Re-export with the option switched on and re-import the solution.

## Ways

The right-hand panel lists the ways in two tabs, *Reached from* (shown first, like *Origin* in the data-flow trace) and *Calls*. Switching tabs does not reload the trace. The data-flow trace has its *Origin* / *Usage* tabs in the same place; there a switch reloads, because each direction is its own trace.

### Calls

*What happens when the script runs* — one way per reached script, as a call tree. Each row shows:

- the target script and how it is reached: a call, a **cascade** (a script trigger of a layout the way enters, with the event and the layout) or a **trigger** of the start layout;
- the call step with its condition and parameter, for a cascade the `Go to Layout` step;
- the chain of scripts above it (from level 2);
- flags: *always runs* or *n conditions*, *loop*, *Server*, *file* (crosses into another file), *parameter*, *unreachable*, *approximate* (plugin call without a step anchor), *dynamic*;
- the **effect** of the target script as a one-liner — "sets 4 fields · reads 12 fields · enters 2 layouts" — expandable to the objects in the graph.

Child ways are collapsed with a counter. On a layout start, the first level are the layout's own triggers; each row names the object that fires it (*Fired by*: a button, a field, the layout) and opens the layout with that object. Actions per row: *Diagram*, *At call step* (opens the caller at the step), *Trace from here* (new trace at this script).

### Reached from

*How the script is reached* — one way per entry script, grouped by entry kind:

| Entry | Meaning |
|---|---|
| Buttons | button actions on layouts, with the layouts |
| Script triggers | layout or object triggers, with the event |
| Menu commands | custom menu items |
| File triggers | file-level triggers such as `OnFirstWindowOpen` |
| No caller (root) | no script calls this script — it starts through its entries or by hand |
| Beyond the budget | the callers go on beyond the up budget |
| Excluded | an excluded (boundary) script whose callers are not followed |

Each way runs from the entry script over the calling steps to the start.

### Search

The search field above the list finds a script by name in the loaded ways — the target of a way in *Calls*, the entry script in *Reached from*. Matching ways stay in the list with the ways above them, which show as dimmed context rows (head only); everything else is hidden while the field holds text. This is how a script nine levels deep in a large call tree is found without opening each level. The search covers the ways the trace returned; when the list is cut (*n of m ways shown*), raise the limit or narrow the trace.

### Follow source

A way that starts at a button, a script trigger or the budget limit can be followed one level further with **Follow source**:

- **Button or trigger entry:** which scripts enter the owner layout with `Go to Layout` — and how are *they* reached?
- **Budget entry:** the callers beyond the up budget.

The new ways hang below the followed one. A way that enters a layout ends in that layout and the event (`Button`, `OnLayoutEnter`, …) that leads to the parent's entry script. The trace panel counts the followed ways and resets them. The new scripts appear in the list, not in the graph — the graph stays the trace.

## Diagrams

*Diagram* opens a way as a Mermaid diagram in an overlay with pan, zoom, full screen and copy. The start or entry is on the left. Scripts are rectangles, call steps are rounded (`#12 Perform Script`), layouts and entries are subroutine shapes, calls without a target are diamonds.

- the edge from a script to its call step carries the condition (`If …`, `Else If …`, `Else`), `↻` in a loop and `×n` when the same edge has several call sites;
- a server call is a thick edge labelled *Server*;
- trigger events are dotted edges labelled with the event.

Way **0** is the overview: downward the tree of all called scripts, upward entries → entry scripts → start. A click on a call step opens the calling script at that step; a click on an entry group selects the way and opens the group in the list. Selecting a way in the list highlights its path in the graph. An open diagram also selects its way in the list — including a diagram opened by link (`way=<n>`): the list opens the levels above it and scrolls the way into view.

## Address bar

The trace state lives in the URL, so a view can be shared:

| Parameter | Meaning |
|---|---|
| `dis=1` | follow disabled steps |
| `wdir=down` | tab *Calls* (default *Reached from*) |
| `way=<n>` | open diagram of way `n` (`0` = overview) |
| `expand=<way IDs>` | ways followed with *Follow source* |

Budgets, switches and exclusions (`up`, `down`, `tdepth`, `vars`, `buttons`, `itrig`, `expup`, `exclude`, `entry`) are described with the [fm-trace](../skills/Skill%20fm-trace.md) skill. Parameters at their default stay out of the URL.

## See also

- [GET /api/graph/trace](../rest-api/endpoints/Graph%20API.md#get-apigraphtrace) — parameters and response
- [Skill fm-trace](../skills/Skill%20fm-trace.md) — the same ways in the terminal, one way as Mermaid
- [Graph Explorer Data Trace](Graph%20Explorer%20Data%20Trace.md) — origin and usage of a field or variable value (experimental)
- [Graph analysis](4%20Code%20Analysis%20Approaches.md#3-graph-analysis)
