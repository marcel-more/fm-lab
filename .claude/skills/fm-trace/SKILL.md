---
name: fm-trace
version: 0.3.0
description: >
  Opens the selective flow graph (Trace) of a FileMaker Script or Layout in the
  FM-Lab web frontend — call chain up/down, the objects the flow actually
  touches, and the script triggers of entered layouts, as a deep link into the
  Graph Explorer's trace mode. Layout starts offer entry-path presets
  (runtime triggers / inbound navigators). Use fm-show --graph for the plain
  neighborhood graph instead. Triggers (English): "/fm-trace", "trace this
  script", "show the flow of this script", "what does this process touch",
  "open the trace". Triggers (German): "trace dieses Script", "zeig den Ablauf
  dieses Scripts", "was fasst dieser Prozess an", "öffne den Trace". Triggers
  (Spanish): "traza este script", "muestra el flujo de este script". Triggers
  (French): "trace ce script", "montre le flux de ce script". Triggers
  (Italian): "traccia questo script", "mostra il flusso di questo script".
  Triggers (Dutch): "trace dit script", "toon de flow van dit script".
  Triggers (Portuguese): "trace este script", "mostre o fluxo deste script".
  Triggers (Swedish): "trace det här skriptet", "visa skriptets flöde".
  Triggers (Japanese): "このスクリプトをトレースして", "このスクリプトのフローを表示して".
  Triggers (Korean): "이 스크립트를 트레이스해 줘", "이 스크립트의 흐름을 보여 줘".
  Triggers (Chinese): "跟踪这个脚本", "显示这个脚本的流程".
---

# fm-trace — Open the selective flow graph (Trace) of a FileMaker object

## Purpose

Opens the discussed object in the Graph Explorer's **trace mode**
(`/graph?trace=…`): instead of the breadth-first neighborhood, the graph
collects only what a flow starting at the object actually touches — the call
chain up/down, the fields/variables/layouts/functions the chain scripts touch,
and the script triggers of layouts the flow enters. v1 start objects:
**Script + Layout**. Neighbour skills: **fm-show --graph** (neighborhood
graph), **fm-open** (jump into FileMaker Pro). Answer the user in the user's
language; this document is English by convention.

## Prerequisites

- Master DB `db/fm_catalog.duckdb` (object resolution; with an active session
  pin — `FMLAB_SOLUTION`/`FMLAB_CONTEXT`, CLAUDE.md §2 — resolve against the
  literal bundle path `solutions/<id>/db/fm_catalog.duckdb`). Missing → abort
  with a pointer to the `convert-xml` skill.
- A reachable FM-Lab web frontend (dev server on :5173, or any base URL the
  user provides). Not reachable → see error table.
- REST API (:3003) is OPTIONAL — used for the entry-preset preview of layout
  starts; without it the same presets are counted via a direct DuckDB query.

## Arguments & modes

| Argument / flag | Effect | Default |
|---|---|---|
| _(none)_ / `<name>` / `<uuid>` / `--file <File>` / `--list` / `--dry-run` | identical to fm-show (shared resolution) | — |
| `--entry <preset>` | Layout starts: entry-path preset (`layout_runtime` \| `layout_inbound` \| `layout_full`) — skips the selection table | ask (table) |
| `--up <0-16>` | upstream chain budget (caller levels) | 3 |
| `--down <0-16>` | downstream chain budget (subscript levels) | 6 |
| `--trigger-depth <0-3>` | trigger-cascade stages | 1 |
| `--vars` | include local `$` variables of the chain scripts | off |
| `--buttons` | include button scripts of entered layouts (stage 3) | off |
| `--interaction-triggers` | let interaction events (keystroke, gesture, device buttons) fire in the cascade — they normally never fire during a script run | off |
| `--expand-up` | expand the touch set of the upstream chain too | off |
| `--exclude <name\|uuid>[,…]` | boundary exclusions: these nodes stay visible but are not expanded (no calls/touches, no trigger cascade); an excluded field stops arming stage-3 object triggers. Scripts, layouts and fields. Repeatable / comma-separated | none |
| `--base-url <url>` | Frontend base URL override | probed |

Natural-language routing: "trace / zeig den Ablauf / was fasst X an" → trace
with defaults; "trace tiefer / mit Kaskade 2" → `--trigger-depth 2`; "mit
lokalen Variablen" → `--vars`; "ohne X / blende X aus / X nicht expandieren"
→ `--exclude X`.

Examples: `/fm-trace` · `/fm-trace Bezugsdatensatz hinzufügen` ·
`/fm-trace Aufgabendetails --entry layout_runtime` ·
`/fm-trace 3B9E7072-… --file Aufgaben --down 4 --trigger-depth 2 --buttons`

## Workflow

### 1 — Resolve the object

Follow `.claude/skills/_shared/resolve-object.md` (read it now if not loaded).
Result: `Object_UUID`, `Object_Type`, `Object_Name`, `File_Name`. `--list`
mode: shared selection-list table, then stop.

### 1a — v1 type gate

Trace v1 supports `Object_Type` **Script** and **Layout** only. Any other type
(Field, Variable, CustomFunction, …): say the trace for this type is planned
(v2), and offer `fm-show --graph` (neighborhood view) on the same object
instead. Do not build a trace URL for unsupported types — the backend answers
422 `TRACE_UNSUPPORTED_START`.

### 1b — Entry path (Layout starts only)

Script starts skip this step (trivial preset). For a Layout start WITHOUT
`--entry`, fetch the preset preview and let the user choose:

```bash
curl -s "http://localhost:3003/api/graph/trace/entries?start=<UUID>&start_file=<FILE>"
```

(URL-encode the params; honor an `X-Solution` context is not needed — the CLI
talks to the API copy of the session's solution only when it matches; when a
session pin diverges from the API's active solution, prefer the DuckDB
fallback below.)

Fallback without a running API — same presets via DuckDB (master DB per CLAUDE.md §2):

```sql
-- layout_runtime: triggers of the layout + its objects (incl. buttons)
SELECT count(DISTINCT Target_UUID || '~' || COALESCE(Target_File, '')) FROM ObjectLinks
WHERE Link_Role = 'triggers_script'
  AND ((Source_Type = 'Layout' AND Source_UUID = '<UUID>' AND Source_File = '<FILE>')
       OR (Source_UUID, Source_File) IN (
         SELECT Source_UUID, Source_File FROM ObjectLinks
         WHERE Link_Role = 'parent_layout' AND Source_Type = 'LayoutObject'
           AND Target_UUID = '<UUID>' AND Target_File = '<FILE>'));
-- layout_inbound: scripts navigating onto the layout
SELECT count(DISTINCT Source_UUID || '~' || COALESCE(Source_File, '')) FROM ObjectLinks
WHERE Link_Role = 'navigates_to_layout' AND Source_Type = 'Script'
  AND Target_UUID = '<UUID>' AND Target_File = '<FILE>';
```

Present a selection table (stop and wait — mirror the resolve-object pattern):

```
| # | Entry path      | Seeds | Meaning                                        |
|---|-----------------|-------|------------------------------------------------|
| 1 | layout_runtime  |     5 | triggers of the layout/objects + button scripts |
| 2 | layout_inbound  |     2 | scripts navigating onto this layout             |
| 3 | layout_full     |     6 | both combined                                   |
```

A preset with 0 seeds is shown but marked not selectable. If ALL presets have
0 seeds, say the layout has no flow entry points and stop (offer
`fm-show --graph`). With exactly one non-empty preset, pick it silently and
mention the choice in the success line. `--entry` overrides the table.

### 1c — Exclusions (`--exclude`, optional)

Each `--exclude` item is resolved like the start object (shared
resolve-object rules; `Name` needs a unique hit — on ambiguity show the
selection table for that item). Only **Script** and **Layout** make sense
(other types have no expansion effect — say so and drop the item). The
resolved items become composite IDs `<uuid>::<File_Name>` for the URL.
Excluding the start object itself is a server-side no-op — warn and drop it.

### 2 — Determine the frontend base URL

```bash
.claude/skills/fm-show/scripts/resolve_base_url.sh [<--base-url value>]
```

Same probe chain and rules as fm-show (shared script — do not duplicate it).
Exit 4 = nothing reachable → offer to start the frontend
(`rest-frontend-start` if available); on request build the URL against
`http://localhost:5173` anyway and display it.

### 2a — Resolve the session solution id (always stamp the link)

```bash
tools/solution.sh current        # prints: <id>\t<source> — take the first field
```

Append `&solution=<SOL_ID>` to the URL. If `solution.sh` is absent or errors,
skip the param silently (single-solution setup).

### 3 — Build the deep link

URL-encode every parameter value (e.g. `jq -rn --arg v "$VALUE" '$v|@uri'`).

```
<base>/graph?trace=<uuid>&trace_file=<File_Name>[&entry=<preset>][&up=<n>][&down=<n>][&tdepth=<n>][&vars=1][&buttons=1][&itrig=1][&expup=1][&exclude=<id1,id2,…>]&solution=<SOL_ID>
```

Flag mapping (frontend deep-link short forms): `--up` → `up`, `--down` →
`down`, `--trigger-depth` → `tdepth`, `--vars` → `vars=1`, `--buttons` →
`buttons=1`, `--interaction-triggers` → `itrig=1`, `--expand-up` → `expup=1`,
`--entry` → `entry`, `--exclude` →
`exclude` (comma-joined composite IDs from step 1c — the whole value
URL-encoded as one parameter). **Omit every parameter at its default** (up 3,
down 6, tdepth 1, toggles off, no exclusions) — short, deterministic URLs; the
frontend treats a missing param exactly like the default. `entry` is always
written when a preset was chosen (step 1b), so the frontend skips its chooser.
Clamp out-of-range budgets to the nearest bound and note it briefly.

### 4 — Open

```bash
.claude/skills/_shared/scripts/open_url.sh "<url>"
```

Same rules as fm-show: exit 3 → present the URL as a clickable Markdown link +
open-bridge hint. `--dry-run`: display the URL, do not open.

## Output

Success is a single line naming object, preset (layout starts) and URL:

```
FM-Lab → Trace of Script "Bezugsdatensatz hinzufügen" opened at http://localhost:5173/graph?trace=… (via $BROWSER).
FM-Lab → Trace of Layout "Aufgabendetails" (layout_runtime, 5 seeds) opened at … (via $BROWSER).
```

## Error cases

| Symptom | Cause | Reaction |
|---|---|---|
| DB missing / ObjectCatalog empty | no import yet | Abort → `convert-xml` |
| No object in context, no argument | nothing discussed yet | Usage hint (see resolve-object.md) |
| Name/UUID ambiguous | duplicates / clone files | Selection list, wait |
| Object_Type not Script/Layout | v2 start type | Say v1 covers Script + Layout; offer `fm-show --graph` |
| All entry presets empty (layout) | no triggers, no inbound navigators | Say so, offer `fm-show --graph`, stop |
| `resolve_base_url.sh` exit 4 | no frontend running | Offer a frontend start; on request show the :5173 URL anyway |
| `open_url.sh` exit 3 | headless / no open-bridge | Show the URL as a clickable link + `bash tools/fmlab.sh open-bridge` hint |
| Budgets outside their bounds | user input | Clamp to the bound, note it briefly |
| `--entry` invalid | typo | Name the three valid presets, show the table |

## Do not do

- No file changes — read-only plus one open invocation.
- Never start the dev server or the REST API silently.
- Never trace unsupported start types "anyway" via `?focus=` — that is
  fm-show's job; say which skill covers it.

## References

- `.claude/skills/_shared/resolve-object.md` — read before resolving (step 1).
- `.claude/skills/fm-show/scripts/resolve_base_url.sh` — shared base-URL probe.
- `.claude/skills/_shared/scripts/open_url.sh` — the only open mechanism.
- Backend contract: `GET /api/graph/trace` + `/api/graph/trace/entries`
  (templates `graph_trace.sql` / `graph_trace_entries.sql`).
