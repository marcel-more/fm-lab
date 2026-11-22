# Skill: fm-trace

Opens the **selective flow graph** of a script or layout in the Graph Explorer's trace mode: the call chain up and down, the objects the flow actually touches, and the script triggers of layouts the flow enters — as a deep link into the web client. For scripts it also lists the **ways** in the terminal: what the script calls and how it is reached, step by step with conditions — and prints any way as a Mermaid diagram.

| | |
|---|---|
| **Category** | Navigation |
| **Slash command** | `/fm-trace [<object>] [--entry layout_runtime\|layout_inbound\|layout_full] [--up <0-16>] [--down <0-16>] [--trigger-depth <0-3>] [--vars] [--buttons] [--interaction-triggers] [--expand-up] [--exclude <a,b,…>] [--include-disabled] [--ways down\|up] [--limit <n>] [--way <n> [--up]] [--expand <wayId,…>] [--file <F>] [--list] [--dry-run] [--base-url <url>]` |
| **Say it naturally** | "trace this script", "show the flow of this script", "what does this process touch", "how is this script reached", "open the trace" — understood in 11 languages |
| **Input** | a script or layout (name, UUID or the object under discussion) |
| **Reads** | `db/fm_catalog.duckdb` (read-only) for resolution and, for layouts, the entry-path counts; `GET /api/graph/trace` for the ways table and diagrams, `GET /api/graph/trace/entries` for the layout presets |
| **Writes** | nothing — one browser open |
| **Prerequisites** | a converted catalog (schema 1.43.0 or later for the step-exact trace) and a reachable web client; the REST API for the ways table and `--way` |
| **Under the hood** | the shared resolution contract, the base-URL probe shared with fm-show, `open_url.sh`, `scripts/flow_ways.mjs` (ways table and Mermaid source); the frontend calls `GET /api/graph/trace` |
| **Skill directory** | `.claude/skills/fm-trace/` |
| **Related** | [Graph Explorer Trace Mode](../Wiki/Graph%20Explorer%20Trace%20Mode.md) · [Skill fm-show](Skill%20fm-show.md) · [Skill fm-analyze](Skill%20fm-analyze.md) · [Skill fm-open](Skill%20fm-open.md) |

## What it does

Where `fm-show --graph` expands every neighbourhood breadth-first, a trace collects only what a flow starting at the object would reach: the chain of scripts up (callers) and down (sub-scripts), the fields, variables, layouts and functions those scripts touch, and — for layouts the flow navigates onto — their script triggers, which can cascade into further chains. The result is the graph of *one process*, not of everything nearby.

Start objects are **scripts and layouts**. A script start needs no further input. A layout start first needs an **entry path** — which scripts count as the flow's seeds:

| Preset | Seeds |
|---|---|
| `layout_runtime` | the layout's own triggers and the triggers of its objects, including button scripts |
| `layout_inbound` | the scripts that navigate onto this layout |
| `layout_full` | both combined |

Without `--entry` the skill shows the seed counts per preset and lets you choose; a single non-empty preset is picked silently, and a layout with no entry points at all is reported as such (the neighbourhood graph is offered instead). Other object types are not trace starts; the skill says so and offers `fm-show --graph` on the same object.

### Ways in the terminal

After the link, a script start prints two tables (15 rows each by default):

- **Reached from** — one way per entry script: its entries (buttons with their layouts, script triggers with the event, menu commands, file triggers, *no caller*, *callers beyond up_depth*), flags, the path to the start and the way ID for `--expand`.
- **Calls** — one way per reached script, as a call tree: level, target script, how it is reached (call, trigger cascade with event and layout), the calling step with its condition (`#5 Perform Script · If $mode = "new"`), flags (*always* or *n cond*, loop, server, cross-file, parameter, unreachable) and the chain above.

`--way <n>` prints the Mermaid source of way `n` instead (`--up` for the "reached from" numbering, `0` = overview); the opened link shows the same diagram. The tables need the REST API — without it the skill opens the link and says so. The trace reads conditions, it does not evaluate them.

## How to use it

```
/fm-trace                                            # the script we just discussed
/fm-trace "Create Invoice"
/fm-trace "Task Details" --entry layout_runtime
/fm-trace "Create Invoice" --down 4 --trigger-depth 2 --buttons
/fm-trace "Create Invoice" --exclude "Log Event,Utility Refresh"   # boundaries
/fm-trace "Create Invoice" --ways up                 # how is it reached?
/fm-trace "Create Invoice" --way 3                   # way 3 as Mermaid
/fm-trace "Create Invoice" --ways up --expand 3f9c0a1b2d4e   # follow source
/fm-trace --dry-run                                  # print the URL only
```

## Options

| Option | Default | Effect |
|---|---|---|
| `--up <n>` / `--down <n>` | 3 / 6 | Chain budget upstream (caller levels) and downstream (sub-script levels) |
| `--trigger-depth <n>` | 1 | How many trigger-cascade stages to follow |
| `--vars` | off | Include the local `$` variables of the chain scripts |
| `--buttons` | off | Include the button scripts of entered layouts |
| `--interaction-triggers` | off | Let interaction events (keystroke, gesture, device buttons) fire in the cascade — a running script presses no keys, so they are skipped by default |
| `--expand-up` | off | Expand the touch set of the upstream chain as well |
| `--exclude <list>` | none | Boundary nodes: shown but not expanded — no calls, no touches, no trigger cascade. Scripts, layouts and fields |
| `--entry <preset>` | ask | Entry path for layout starts |
| `--include-disabled` | off | Follow disabled steps too (calls, touches, `Go to Layout`) |
| `--ways down\|up` | both | Ways table for one direction only |
| `--limit <n>` | 15 | Rows per direction (`0` = all) |
| `--way <n> [--up]` | — | Mermaid source of way `n`; `--up` without a number picks the "reached from" direction, with a number it stays the upstream budget |
| `--expand <ids>` | none | *Follow source* on up-ways with a button, trigger or budget entry (way IDs from the table) |

Parameters at their defaults are omitted from the URL, which keeps links short and deterministic.

## Good to know

- Every link carries the session's `solution=<id>`; base-URL resolution and the open mechanism are the same as in [fm-show](Skill%20fm-show.md), including the dry-run and the open-bridge fallback.
- Exclusions are resolved like the start object (selection list on ambiguity) and become composite `<uuid>::<file>` ids in the URL; excluding the start itself is a no-op.
- The trace is a good companion to [fm-analyze](Skill%20fm-analyze.md): the analysis names the chain, the trace shows it.

## See also

- [Graph Explorer Trace Mode](../Wiki/Graph%20Explorer%20Trace%20Mode.md) — ways list, diagrams and *Follow source* in the web client
- [Graph API](../rest-api/endpoints/Graph%20API.md) — `GET /api/graph/trace` and `/trace/entries`, trace roles and edge kinds, ways and diagram formats
- [Skill fm-show](Skill%20fm-show.md) — the neighbourhood graph and the other views
- [Graph analysis](../Wiki/4%20Code%20Analysis%20Approaches.md#3-graph-analysis)
