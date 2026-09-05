# Skill: fm-show

Opens the object under discussion in the FM-Lab web client as a deep link — the detail view by default, the where-used references or the focused Graph Explorer on request — and works from inside a container by opening the browser on the host.

| | |
|---|---|
| **Category** | Navigation |
| **Slash command** | `/fm-show [<object>] [--refs [--type <T,…>] [--dir in\|out]] [--graph [--depth <1-16>] [--dir in\|out]] [--ref <object>] [--file <F>] [--list] [--dry-run] [--base-url <url>]` |
| **Say it naturally** | "show this in FM-Lab", "open in the web frontend", "show the references in the browser", "show who calls this", "show this in the graph" — understood in 11 languages |
| **Input** | an object name, a UUID, or the object under discussion; optional view flags |
| **Reads** | `db/fm_catalog.duckdb` (read-only) for resolution; probes the frontend for a reachable base URL |
| **Writes** | nothing — one browser open |
| **Prerequisites** | a converted catalog and a reachable web client (dev server on port 5173 or any base URL you provide). The REST API is not required |
| **Under the hood** | the shared resolution contract, `scripts/resolve_base_url.sh` (probe chain) and `_shared/scripts/open_url.sh` (the one open mechanism) |
| **Skill directory** | `.claude/skills/fm-show/` |
| **Related** | [Skill fm-trace](Skill%20fm-trace.md) · [Skill fm-open](Skill%20fm-open.md) · [Skill fm-summarize](Skill%20fm-summarize.md) |

## What it does

Every catalog object has a detail route, so — unlike the jump into FileMaker Pro — there is no type restriction: variables, layout objects, calculation instances and script triggers open just as well as scripts and fields. The skill resolves the object, determines the frontend's address, builds the deep link and opens it.

Three views:

| View | Flag | Opens |
|---|---|---|
| Detail | *(default)* | `/object/<uuid>?file=<File>` — the object's detail page; for a file, its dashboard `/file/<File>`; for a layout, the detail page plus the full-screen canvas link `/layout/<uuid>` |
| References | `--refs` | the where-used tab, optionally restricted to object types (`--type Script,Layout`) and a direction (`--dir in` = who references this, `--dir out` = what it references) |
| Graph | `--graph` | the Graph Explorer focused on the object, with subgraph depth (`--depth`, 1–16) and direction |

**Relational targets** are understood, too: *"show the layout where a button calls this script"* resolves the connecting object in two hops through the catalog's links, opens the container and highlights the connecting object via a `ref` parameter — on a layout canvas the button is pre-selected, in a formula the token is marked, in the references tab the origin's hits are flagged. Sub-objects without a standalone view (layout objects, script steps) open their container the same way. `--ref <object>` sets the highlight explicitly.

## How to use it

```
/fm-show                                              # the object we just discussed
/fm-show "Create Invoice"
/fm-show "Status" --refs                              # where-used tree
/fm-show "Create Invoice" --refs --type Script --dir in   # callers only
/fm-show --graph --depth 3 --dir out                  # what it reaches, three hops
/fm-show 8075DF6B-… --file Customers                  # clone-safe
/fm-show --list                                       # objects currently in context, open nothing
/fm-show --dry-run                                    # print the URL only
```

Natural phrasing routes to the flags: *show the references* → `--refs`; *show it in the graph* → `--graph`; *who calls this* → `--refs --type Script --dir in`; *what does it use* → `--refs --dir out`.

## Good to know

- **The link carries the solution.** The web client keeps its own per-tab solution context, which may differ from the session's. Every deep link therefore includes `solution=<id>`; the frontend adopts it for that tab. See [Multi-solution workspaces](../rest-api/REST%20API%20Overview.md#multi-solution-workspaces).
- **Finding the frontend.** The base URL comes from `--base-url`, else the `FMLAB_WEB_URL` variable, else a probe of the usual addresses — including the container-internal service names of the Docker stack, while the returned URL stays the host address your browser can reach. Nothing reachable → the skill offers to start the web client (your call) or prints the URL anyway.
- **Opening from a container.** Inside a dev container the VS Code helper opens the URL on the host; in a plain Docker stack the host-side open-bridge does (`bash tools/fmlab.sh open-bridge`). Without either, the URL is shown as a clickable link.
- Type filters are matched against the catalog's actual type names before the URL is built; out-of-range depths are clamped like the frontend does.

## See also

- [Skill fm-trace](Skill%20fm-trace.md) — the selective flow graph instead of the neighbourhood
- [Skill fm-open](Skill%20fm-open.md) — the same object in FileMaker Pro
- [Interactive exploration](../Wiki/4%20Code%20Analysis%20Approaches.md#1-interactive-exploration) — the views this skill opens
- [Web Client](../Wiki/Components.md#web-client) · [Local servers](../Wiki/Components.md#local-servers)
