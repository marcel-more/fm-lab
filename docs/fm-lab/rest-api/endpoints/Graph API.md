# Graph API

Endpoints under `/api/graph/*` expose the object graph (`ObjectCatalog` + `ObjectLinks`) for interactive exploration: focus-centered subgraphs, lazy expansion, the top-down atlas, community/cluster information, and search. `/api/relationship-graph/:fileName` additionally renders the classic FileMaker relationship diagram data for one file.

Common behavior:

- All GET routes accept the standard `format` / `meta` / `debug` parameters ([REST API Conventions](../REST%20API%20Conventions.md)).
- Focus-based routes resolve the focus node clone-aware: optional `focus_file` disambiguates shared UUIDs, otherwise `409 AMBIGUOUS_UUID` (response details list the matching files).
- Node identifiers in responses are composite `uuid::file` (`id`) plus the raw `uuid` — the composite key stays unique across cloned files.
- Subgraph/overview responses are LRU-cached for 5 minutes per parameter set. Writing an annotation or a change-author alias clears the caches.

---

## GET /api/graph/subgraph

Focus-centered k-hop subgraph.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `focus` | string | — | **Required.** Focus node UUID |
| `focus_file` | string | — | Clone disambiguation of the focus node |
| `depth` | integer | `1` | Traversal depth (server-capped) |
| `direction` | enum | `both` | `out` · `in` · `both` |
| `mode` | enum | `logical` | `logical` (condensed) · `raw` (all edges). In `logical` mode, edges of sub-objects are hoisted onto their container — except for the focus node itself, which shows its own relations directly (a layout-object or script-trigger focus is never a dead end), and except for the standalone layout objects described below. Trigger relations of a field-bound layout object anchor at the displayed field rather than the layout, so that chain reads object → field → script, which shows in the depth counting. |
| `types` | string (CSV) | — | Object types to include |
| `roles` | string (CSV) | — | Edge roles to include |
| `include_builtins` | boolean | `false` | Include builtin-function nodes |
| `node_limit` | integer | `1000` | Node cap; `truncated: true` signals clipping |
| `hub_degree` | integer | `100` | Degree threshold for the `isHub` flag |

**Response `data`**

```json
{
  "focus": "…",
  "params": { "depth": 2, "direction": "both", "…": "…" },
  "truncated": false,
  "stats": { "nodeCount": 57, "edgeCount": 84, "totalReachable": 57, "maxDepthReached": 2 },
  "nodes": [ { "id": "uuid::File", "uuid": "…", "label": "…", "type": "Script", "file": "…",
               "depth": 1, "degree": 4, "isHub": false, "isFocus": false,
               "community": 3, "communityName": "Invoicing", "hidden": false } ],
  "edges": [ { "id": "…", "source": "…", "target": "…", "role": "calls_script",
               "subrole": null, "linkType": "operational", "crossFile": false } ]
}
```

`community`/`communityName` are `null` when the solution has not been clustered yet. Errors: `404 OBJECT_NOT_FOUND`, `409 AMBIGUOUS_UUID`.

**Change activity** (subgraph and trace): the response carries `activity: { available, dataState }` — whether the catalog has change stamps, and the data state the ages count back from — and every node `activity: { class, newestChange, newestAgeDays, saves, undated }` (`null` without change stamps). `class` follows the [activity classes](../../schema/catalog-tables/ObjectChangeMeta.md#activity-classes): `1` ≤ 30 days · `2` ≤ 90 days · `3` ≤ 1 year · `4` ≤ 2 years · `5` > 2 years · `6` unknown · `7` no stamp of its own.

### Standalone layout objects in the logical view

Most layout objects are hoisted onto their layout in `logical` mode. That is right for a field control: an edit box *represents* its field on the screen, so "layout shows field" is a true statement. Charts and web viewers are different. Their field and variable references come from their own calculation slots — chart title, axis titles, series values, the web-viewer URL — and none of those fields is visible on the layout. Hoisting them would claim the layout reads the field, when in fact the object computes it.

Both types therefore stay nodes of their own:

- At a **layout focus** the chart or web viewer sits at depth 1, and its fields and variables at depth 2 — one hop behind the object.
- The connecting edge is the object's own `parent_layout` edge. For layout objects that edge is operational (only `LayoutPart` → layout is structural) and points object → layout, so `direction=out` at a layout focus does not follow it; the default `direction=both` shows the whole chain.
- At an **object focus** the chart or web viewer speaks its own references, with no duplicate hoisted counterpart at the layout.

The classification is a curated type list, not an edge-role rule. Field controls also carry `reads_field` edges — from hide and tooltip calculations — and there the layout stays the correct speaker, as the visibility context of the placement.

The node `type` of both remains `LayoutObject`: the specific type is a column of [LayoutObjects](../../schema/catalog-tables/LayoutObjects.md), not a catalog object type.


## GET /api/graph/neighbors

1-hop expansion around an existing node (lazy expand). Identical parameters and response shape as `/graph/subgraph`, but without `depth` (fixed to 1).

## GET /api/graph/trace

Selective flow graph (trace mode of the Graph Explorer). Instead of expanding every neighborhood breadth-first, the trace collects only what a flow starting at the object actually touches: the call chain up/down (`calls_script`), the fields/variables/layouts/functions the chain scripts touch, and — for layouts the flow enters — their script triggers (object-level triggers only when the object displays a field the trace already touched). Response shape matches `/graph/subgraph` plus trace-specific fields, so Explorer clients render both with one pipeline.

Start objects of the flow trace (`mode=flow`, the default): **Script** and **Layout**. A layout start maps onto a seed-script set via an entry preset (see `/graph/trace/entries`). The Explorer side is described in [Graph Explorer Trace Mode](../../Wiki/Graph%20Explorer%20Trace%20Mode.md). Fields and variables have the experimental data trace (`mode=data`, see [below](#data-trace-modedata-experimental) and [Graph Explorer Data Trace](../../Wiki/Graph%20Explorer%20Data%20Trace.md)).

The flow trace is **step-exact**: calls, touches and navigation come from the script steps (`v_script_step_links`), so every call carries its call sites with their condition, and disabled steps are left out by default. Besides the graph the response carries the **ways** of both directions — one per reached script (`down`, "calls") and one per entry script (`up`, "reached from") — and every way is available as a Mermaid diagram. The flow trace needs catalog schema 1.43.0 or later (see errors and `/graph/trace/capability`).

| Parameter | Type | Default | Description |
|---|---|---|---|
| `start` | string | — | **Required.** Start object UUID |
| `start_file` | string | — | Clone disambiguation of the start object |
| `mode` | enum | `flow` | `flow` = flow trace (this section) · `data` = data-flow trace of a field or variable, with its own parameter set |
| `entry` | enum | type-dependent | Entry preset for layout starts: `layout_runtime` (triggers of the layout and its objects + button scripts) · `layout_inbound` (scripts navigating onto the layout) · `layout_full` (both). Script starts ignore it |
| `up_depth` | integer | `3` | Chain budget upward (caller levels, 0–16) |
| `down_depth` | integer | `6` | Chain budget downward (subscript levels, 0–16) |
| `trigger_depth` | integer | `1` | Trigger-cascade stages (0–3); layouts entered by a cascade fire the next stage only above 1 |
| `expand_up` | boolean | `false` | Also expand the touch set of the upstream chain |
| `include_local_vars` | boolean | `false` | Include local `$` variables of the chain scripts (`$$` globals are always included) |
| `include_buttons` | boolean | `false` | Include `button_action` triggers of entered layouts in the cascade |
| `include_interaction_triggers` | boolean | `false` | Include interaction-class events in the cascade. By default the cascade skips events that only user interaction can fire (`OnLayoutKeystroke`, `OnObjectKeystroke`, `OnGestureTap`, `OnObjectModify`, `OnExternalCommandReceived`) — a running script presses no keys, so these triggers cannot fire during the traced flow. Script-reachable events (`OnLayoutEnter`/`Exit`, `OnRecordLoad`/`Commit`/`Revert`, `OnModeEnter`/`Exit`, `OnObjectEnter`/`Exit`/`Save`/`Validate`, `OnPanelSwitch`, `OnViewChange`, `OnLayoutSizeChange`, the AVPlayer events) always stay in. Entry presets of a layout start are unaffected — there, interaction triggers are legitimate entry paths |
| `include_disabled` | boolean | `false` | Also follow disabled script steps — calls, touches and `Go to Layout` (and with it the trigger cascade). With `true` the node and edge set equals the script-level trace |
| `include_builtins` | boolean | `false` | Include builtin-function targets |
| `ways_limit` | integer | `300` | Ways per direction (1–2000); `trace.stats.truncatedBy` names `ways_limit` when it cut |
| `ways_mermaid` | boolean | `false` | Add the Mermaid source to every way and both overviews (see below) |
| `expand_way` | string | — | "Follow source" on up-ways: comma-separated way IDs (12 hex, max. 20) from `trace.ways[].wayId`. A button or trigger entry adds the scripts that enter the owner layout via `Go to Layout` and their callers up to `up_depth`; a `budget` entry adds the callers beyond `up_depth`. Unknown IDs change nothing |
| `way` / `way_dir` | integer / enum | — / `down` | Only with `format=mermaid-raw\|svg\|mermaid`: way number in direction `way_dir` (`down` · `up`), `0` = overview |
| `node_limit` | integer | `1000` | Node cap; ranked by trace role (start > chain > triggered > touched > cascade-touched > context), then depth, then degree — `truncated: true` signals clipping |
| `hub_degree` | integer | `100` | Degree threshold for the `isHub` flag |
| `exclude` | string | — | Boundary exclusions: comma-separated composite node IDs (`<uuid>::<file>`; an item without `::` addresses an object whose `File_Name` is NULL). Excluded nodes stay visible in the result but are not expanded: the walk stops at them (call chain and cascade), they contribute no touch edges, and an excluded layout fires no trigger cascade. Excluding the start object is a no-op. An excluded **field** stays a visible touch target but no longer arms the selective object-level triggers of stage 3 — object triggers that would fire only because an object displays that field stay silent. Malformed items answer `400`; unknown UUIDs are inert |

**Response `data`** — subgraph shape plus:

- per node: `traceRole` (`start` · `chain_down` · `chain_up` · `triggered` · `touched` · `trigger_touched` · `trigger_owner`), `traceDepth` (signed; upstream negative) and `isExcluded` (true on boundary nodes from the `exclude` list)
- per edge: `traceKind` (`chain` · `trigger` · `touch` · `induced`); `induced` edges are context edges between already-collected nodes (`displays_field`, `displays_variable`, `context_table`, `uses_valuelist`) and never expand the node set
- `trace`: `{ start: { uuid, file, type }, entry, seeds[], excluded[], suggestions[], stats: { dynamicCalls } }` — the seed scripts of stage 0; `excluded[]` resolves every `exclude` item against the catalog as `{ id, uuid, file, label, type }` (label/type are null for unknown UUIDs), including items the damped trace no longer reaches
- `trace.suggestions[]`: server-computed exclusion candidates among the traced scripts — shared utilities whose global metrics mark them as hubs (trigger fan-in ≥ 25, callers ≥ 50, or field touches ≥ 100), each as `{ id, uuid, file, label, type, trigIn, fanIn, touchOut, score, reason }` with `reason` ∈ `trigger_hub` · `call_hub` · `touch_hub`, score-descending, capped at 10. The start object, already excluded nodes, and chain nodes of the start's file or at chain depth ≤ 1 are never suggested. Suggestions are never applied automatically — clients offer them and pass accepted ones back via `exclude`
- `stats.dynamicCalls`: number of call steps of the traced scripts that resolve their target by name at runtime (Perform Script "by name" and its on-server variants) — these have no static edge, so the trace is a static approximation

**Step-exact parts** (`mode=flow`):

- per edge: `precision` (`exact` = backed by script steps · `approx` = call without a step anchor, e.g. `MBS("FM.RunScript")`) and, on `calls_script` edges, `callSites[]` sorted by step — `{ stepUuid, stepIndex, stepId, guard, conditions, ifDepth, inLoop, passesParam, resultReadAt[], unreachable, enabled }`. `guard` is the innermost enclosing branch `{ kind: if|elseif|else, level, stepIndex, calcUuid, text, textFull }` (`text` cut to 80 characters, `textFull` only when cut); `conditions` counts the enclosing If branches; `resultReadAt[]` are the step indexes that read the script result; `unreachable` marks a call after *Exit Script* / *Halt Script* in the same block; `enabled` appears only on disabled steps. Empty fields (null, false, 0, `[]`) are left out
- per script node: `effects` — touch counters per role (`{ "sets_field": 4, "reads_field": 12, "navigates_to_layout": 2, … }`); `trace.effectsTotal` counts the distinct touch targets per role in the graph
- `trace.blindSpots`: `{ dynamicCalls, unresolvedCalls, sites[] }` — every active call step without a static target, anchored at its script (`kind` `by_name` · `unresolved`, step, name formula, condition)
- `trace.blindSpots.noDdr` (both modes): `{ files[], missingKinds[], reducedKinds[] }` — the touched files exported without DDR info (*Include details for analysis tools* off). Formula references are missing there: fields read in formulas, script parameters and results (`missingKinds`: `field_value_to_step`, `param_to_step`, `result_to_step`, `param_ctl_to_step`, `param_guards_step`, `variable_ctl_to_step`; `reducedKinds`: `field_to_calc`, `field_sql_select_to_step`, `field_sql_filter_to_step`, `field_guards_step`, `sink_display`), so `effects` undercount reads and data ways can end early. Empty arrays when no such file is touched. In `mode=data` every way through such a file carries `noDdr: true`
- `trace.stats`: additionally `unresolvedCalls`, `disabledSteps` (left out, or followed with `include_disabled`), `conditionalCalls`, `ways` / `waysTotal` per direction and `truncatedBy` (`node_limit`, `ways_limit`)

**Ways** — `trace.ways[]`, numbered per direction (`wayNo` from 1):

```json
{ "wayNo": 3, "wayId": "687437be92f8", "dir": "down", "kind": "cascade", "level": 1,
  "target": "uuid::File", "parentWayId": null, "nDesc": 0, "precision": "exact",
  "flags": { "conditions": 1, "cascade": true },
  "event": "OnLayoutEnter", "eventOwner": "uuid::File",
  "pathNodes": ["start::File", "step::File", "layout::File", "target::File"] }
```

- `dir: down` — one way per reached script and per call without a static target, as a breadth-first call tree: `parentWayId` is the way to the calling script, `nDesc` counts the subtree. `kind` describes the last hop: `call`, `cascade` (script trigger of an entered layout, `event` + `eventOwner`), `trigger` (script trigger of the start layout), `dynamic`. `pathNodes` holds only the section after the parent way (`pathPrefix` = `parentWayId`); the full path is the parent's path plus this section.
- `dir: up` — one way per entry script, `kind: entry`, `pathNodes` from the entry script over the call steps to the start. `entryGroups[]` = `{ kind, event, n, nLayouts, layouts[], sample[] }` with `kind` `button` · `trigger` · `menu` · `file` · `root` (no caller) · `budget` (callers beyond `up_depth`) · `excluded`; `nEntries` sums them. Ways added by `expand_way` hang below the followed way (`parentWayId`); their section ends before the parent's entry script, which follows via `pathSuffix`, and `event` names the hop from the entered layout to the parent's entry script (`button_action`, `OnLayoutEnter`, …).
- Path nodes are graph node IDs, call steps (`<stepUuid>::<file>`) and calls without a target (`<stepUuid>#dyncall::<file>`). Hops follow from the node types: script → step, step → script (call), step → layout (`Go to Layout`), layout → script (event). Labels of nodes outside the graph — steps (`#n Name`, `stepIndex`, `stepId`, call context `site`, owning `script`), capped scripts and layouts, entry objects and the `eventOwner` of trigger ways (the layout object, field or layout whose trigger starts the way; a layout object carries `open` = its layout) — are under `trace.refs`.
- `flags` over the full path: `conditions` (hops whose call sites all sit under a condition — always present), and only when true `loop`, `server`, `param`, `crossFile`, `unreachable`, `cascade`. `precision` is the weakest hop (`dynamic` < `approx` < `exact`).
- `trace.overview = { down: { byLevel, byKind }, up: { byLevel, byEntry } }` — head counts per level and kind.
- `wayId` is stable across calls: the first 12 hex digits of `md5("flow|<dir>|<target>")` — a way keeps its ID when budgets or other ways change, its number may not.

**Diagram formats.** `format=mermaid-raw` returns the Mermaid source of one way, `format=svg` the rendered SVG, `format=mermaid` an HTML page with the diagram; `way` picks the way in direction `way_dir`, `way=0` the overview (downward the script tree, upward entries → entry scripts → start). The diagram runs left to right: call steps are nodes, the edge to a call step carries the condition (`If …` / `Else If …` / `Else`), `↻` (loop), `×n` (several call sites) or `unreachable`; server calls are thick (`Server`), events and approximate calls dotted. A way number outside the trace answers `400` with `details = { way, way_dir, ways }`. `ways_mermaid=true` adds `trace.ways[].mermaid` + `mermaidIds` (Mermaid node ID → graph node ID or entry-group key) and `trace.overviewMermaid` / `overviewMermaidIds` (`{ down, up }`) to the JSON.

### Data trace (`mode=data`, experimental)

The data trace follows the **value** of a field or variable instead of a process: `dir=up` (origin) walks back to the write sites and their entries, `dir=down` (usage) forward to the readers, the fields written from them and the sinks. It walks the data-flow view `v_dataflow_edges` and is a static approximation — noise, boundaries and the solution profile are described in [Graph Explorer Data Trace](../../Wiki/Graph%20Explorer%20Data%20Trace.md). Parameters and response shape may still change.

Start objects: **Field** and **Variable** (not Let variables). Parameters that only apply to `mode=data`:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `dir` | enum | `up` | `up` = origin · `down` = usage |
| `field_levels` | integer | `1` | Field-to-field transitions (1–10) |
| `var_levels` | integer | `5` | Transitions over variables, parameters and results (1–10); an accumulating chain (`$x = $x & …`) counts once |
| `step_limit` | integer | `150` | Steps per path (10–300) |
| `call_context` | `0` · `1` | `1` | `1` pairs a script result with the calling step that passed the parameter; `0` connects every call site |
| `include_control` | boolean | `false` | Control and guard edges (conditions, SQL filters, repetition) as leaves |
| `include_sinks` | boolean | `true` | Usage only: display, sort, export, find, relationship and value list as sinks |
| `include_reset` | boolean | `false` | Write steps with an empty value as ways of their own instead of `trace.resetGroup` |
| `expand_way` | string | — | "Follow source": comma-separated way IDs whose source fields go one field level further |
| `profile` | `on` · `off` | `on` | Apply the confirmed rules of the solution profile; `off` = generic view |
| `start_step` | string | — | Variable start: step UUID of the anchor step |
| `start_role` | `read` · `set` | derived | Variable start: the anchor step reads (origin at this reader) or sets the variable (sources resp. readers of this setter) |

`node_limit`, `ways_limit`, `ways_mermaid`, `way` and `exclude` work as in the flow trace; `exclude` takes fields, scripts, steps and variables. The flow-trace budgets and switches (`up_depth`, `entry`, `include_disabled`, …) have no effect.

**Response `data`** — subgraph shape plus:

- per node: `flowRole` (`start` · `field` · `step` · `variable` · `param` · `calc` · `entry` · `sink` · `control`), `fieldLevel`, `varLevel`, `isLeaf`, `isPseudo` (blind-spot nodes such as a dynamic target), `profileStop` (the walk ended here because of a profile rule)
- per edge: `flowKind` (the `Flow_Kind` of `v_dataflow_edges`, e.g. `step_writes_field`, `field_value_to_step`, `step_sets_variable`, `entry_input`), `flowClass` (`data` · `control` · `entry` · `sink`), `precision` (`exact` · `approx`)
- `trace`: `{ mode, dir, start: { uuid, file, type, step }, excluded[], stats, blindSpots, ways[], resetGroup, usageGroups, overview, profile }`
- `trace.stats`: `ways` / `waysTotal`, `resetWays`, `entries`, `reachedFields`, `maxFieldLevel`, `maxVarLevel`, `disabledSteps`, `contextOpen` (transitions without a known call site), the cut counters `cutFieldLevels`, `cutVarLevels`, `cutStepLimit` and `truncatedBy[]` (`field_levels` · `var_levels` · `step_limit` · `state_limit` · `node_limit` · `ways_limit`)
- `trace.blindSpots`: `uninitialized` (local readers without a reaching setter), `dynamicWrites` (`Set Field By Name`, active field), `dynamicCalls`, `dynamicSql`, `approxEdges`, and `noDdr` as in the flow trace
- `trace.ways[]`: `{ wayNo, wayId, level, field, writer, writerFlowKind, writerKind, isReset, parentWayId, precision, nEntries, entryGroups[], fields[], pathNodes[], pathEdges[] }` — one way per write site (origin) or read site (usage) of a field level; `writerKind` is `value` · `constant` · `reset` · `input` · `import`; `entryGroups[]` = `{ kind, event, n, nLayouts, layouts[], sample[] }` with `kind` `button` · `trigger` · `input` · `import` · `auto_enter` · `file` · `menu`; `fields[]` are the source fields (origin) or reached fields (usage) with the edge `via`; ways through a file without DDR info carry `noDdr: true`
- `trace.resetGroup`: `{ n, ways[] }` — the reset write sites when `include_reset` is off
- `trace.usageGroups[]` (usage): `{ kind, n, nSources, sample[] }` with `kind` `display` · `sort` · `export` · `find` · `navigate` · `relationship` · `valuelist` · `calc` · `writes` · `infrastructure`
- `trace.overview`: `{ fields[], links[] }` — the field-to-field overview (way 0)
- `trace.profile`: `{ enabled, hash, confirmed, orphaned, applied, candidates[] }` — `applied` counts what the profile changed on this trace (`technicalLayout`, `boundaryScript`, `uiStateVariable`, `hubVariable`, `hubReaders`); `candidates[]` are open profile candidates on this trace

`format=mermaid-raw|svg|mermaid` with `way=<n>` returns one way as a diagram (`way=0` = overview); `way_dir` does not apply.

Errors: `404 OBJECT_NOT_FOUND`, `409 AMBIGUOUS_UUID`, `409 SCHEMA_DRIFT` (the catalog is older than schema 1.43.0 — re-import the solution; details carry `db_schema_version`, `current_schema_version`, `missing`), `422 DATAFLOW_NOT_BUILT` (current schema, but the data-flow phase of the import failed), `422 TRACE_UNSUPPORTED_START` (start type without trace semantics in this mode; details name the supported types), `422 TRACE_EMPTY_ENTRY` (the chosen entry preset yields no seed scripts; details carry the available presets with seed counters).

## GET /api/graph/trace/capability

Whether the solution can serve the step-exact trace — clients ask once per solution and hide the trace instead of running into an error. Response `data`: `{ dataflow: "available" | "not_built" | "schema_drift", ddr: "all" | "partial" | "none" | "unknown", noDdrFiles: [] }` (`not_built` and `schema_drift` correspond to the errors `DATAFLOW_NOT_BUILT` and `SCHEMA_DRIFT` of `/graph/trace`). `ddr` is the DDR coverage of the solution — `partial`/`none` when files were exported without *Include details for analysis tools*, listed in `noDdrFiles`; traces through those files miss formula references (see `trace.blindSpots.noDdr`).

## GET /api/graph/trace/profile

The **solution profile** of the data trace (experimental, see [Graph Explorer Data Trace](../../Wiki/Graph%20Explorer%20Data%20Trace.md#solution-profile)): declarative rules the walk applies — `technical_layout`, `boundary_script`, `ui_state_variable`, `hub_variable` (`table_naming` is stored but has no effect yet) — and the candidates of the heuristics H1–H4. Stored per solution in `solutions/<id>/state/dataflow_profile.json`.

Response `data`: `solution`, `file`, `exists`, `updatedAt`, `hash` (part of the trace cache key), `summary: { rules, confirmed, rejected, orphaned }`, `rules[]` (`kind`, `uuid` + `file` or `pattern`, `name`, `status` `confirmed` · `rejected`, `source` `H1`–`H4` · `manual`, `confirmed_at`, `key`, `acts`, `matches`, `orphaned`) and `heuristics: { H1…H4: { kind, open, confirmed, rejected, candidates[] } }` — each candidate with `key`, `name` or `pattern`, `metrics`, `sample[]`, `uncertain` and its `status`.

## PUT /api/graph/trace/profile

Confirms, rejects or removes rules. Body: `rules[]` (`kind`, `uuid` + `file` or `pattern`, `status` `confirmed` · `rejected` · `none` — `none` removes the rule and reopens the candidate; optional `name`, `source`, `note`) and/or `heuristic: { id: "H1"…"H4", status, except[], include_uncertain }` — a bulk decision over every open candidate of one heuristic except the listed keys. Only confirmed rules act in the walk; a rejected candidate does not come back. Response: the profile as in `GET` plus `changed`. Errors: `400 VALIDATION_ERROR` (unknown rule kind, pattern or UUID where the kind does not take it), `422 DATAFLOW_NOT_BUILT`.

## GET /api/graph/trace/entries

Entry-preset preview for `/graph/trace` — lets clients offer the path choice before the first trace fetch.

Parameters: `start` (required), `start_file` — clone-aware like the trace itself.

Response `data`: `entries[]` of `{ entry, label, isDefault, seedCount, seedsSample[] }`. A script start answers with the single trivial `script` preset; a layout start lists `layout_runtime` (default), `layout_inbound` and `layout_full` with their seed counts and up to five sample script names. Unsupported start types answer `422 TRACE_UNSUPPORTED_START`.

## GET /api/graph/depth-profile

Maximum reachable depth (eccentricity) from a focus plus per-depth node counts — lightweight companion to the subgraph depth slider.

Parameters: `focus` (required), `focus_file`, `direction`, `mode`, `types`, `include_builtins` — same semantics as `/graph/subgraph`.

Response `data`: `focus`, `direction`, `mode`, `maxDepth`, `hitCap` (true when the walk hit the server's depth cap — real eccentricity may be larger), `hardCap`, and `perDepth[]` of `{ depth, nodes, cumulative }`.

## GET /api/graph/overview

Top-down atlas entry point: treemap (composition) or meta-graph (topology) over the whole solution.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `view` | enum | `composition` | `composition` (treemap) · `topology` (meta-graph) |
| `level` | enum | `root` | Treemap funnel: `root` · `segment` · `leaf` |
| `segment_by` | enum | `community` | `community` · `file` · `type` · `hubs` |
| `parent_community` / `parent_file` / `parent_type` | — | — | Drill-down context for levels `segment`/`leaf` |
| `weight` | enum | `domain` | Segment weighting: `domain` · `logical` |
| `include_builtins` | boolean | `false` | |
| `exclude_types` | string (CSV) | — | Object types to hide (applied before aggregation) |
| `fold` | boolean | `true` | Top-K folding with a "rest" tile; `false` = all segments |
| `limit` | integer | `50` | Top-N cutoff |
| `activity` | boolean | `false` | Compute the change activity per tile or super-node (the Atlas colour modes *Activity* and *Saves*). Off by default: it adds about 10–15 ms per uncached request |
| `activity_bulk` | enum | `hide` | `include` lets a mass stamp date the last change like an individual one |

Composition responses return `tiles[]` (aggregate tiles with `key`, `label`, `node_count`, `weight`; leaf tiles with `uuid`, `file`, `type`; a folded tail becomes a `kind: "rest"` tile). Topology responses return super-`nodes[]` and undirected, de-duplicated `edges[]` with weights.

Both carry `activity: { requested, available, data_state, bulk }` — `available` tells whether the catalog has change stamps at all, also without `activity=true`. With `activity=true` every tile and super-node carries `activity` with the [activity class](../../schema/catalog-tables/ObjectChangeMeta.md#activity-classes) of its youngest member (`class` 1–7), `class_counts` (members per class, adding up to the node count), `newest_change`, `newest_age_days`, `active_90`, `median_age_days`, `median_saves`, `stamped`, `undated`, `saves_level` (1–5) and `saves_sum`/`saves_n`. The rest tile and the rest super-node carry the sums of what they fold (medians `null`); the leaf rest tile carries the nodes beyond the cap.

## GET /api/graph/communities

Full community list of the active cluster partition, sorted by member count. Returns per community: `community` (id), `display_name` (user name > semantic name > heuristic name > "Community N"), `description`, `member_count`, `dominant_type`, `dominant_file`, and a representative top member. Without clustering: `{ "engine": "", "communities": [] }` (HTTP 200).

## GET /api/graph/community-stats

Cluster availability and naming status for the atlas status bar: `engine`, `clusters_available` (whether the active engine has cluster data at all), `total_communities`, `named_communities`, `coverage_pct` (member-weighted semantic-name coverage, `null` when unnamed), and the persisted metrics of the last cluster run (`modularity_q`, `resolution`, `seed`, …). Degrades gracefully to zeros/false when no clustering exists.

## GET /api/graph/search

Focus autocomplete over `ObjectCatalog`.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `q` | string | — | **Required.** Search text |
| `type` | string | — | Optional type filter |
| `file` | string | — | Optional file filter |
| `limit` | integer | `20` | Max 100 |

Response: `results[]` of `{ id, label, type, file }`.

A full UUID or import key in `q` focuses that object directly and ranks it first — by equality only, so a UUID fragment never matches by identity (same rules as [identity search](Search%20API.md#identity-search); `id:<n>` is not supported here, since a per-file ID is no focus candidate).

## POST /api/graph/recluster

Re-runs the graph clustering for the request's context solution and streams progress as **Server-Sent Events** (`text/event-stream`):

- `{ "event": "start", "ts": … }`
- `{ "event": "log", "level": "info", "msg": "…" }` — one per pipeline log line
- `{ "event": "done", "ok": true, "exit_code": 0 }` — terminal
- `{ "event": "error", "message": "…" }` followed by a failing `done` on errors

Engine, resolution and seed come from the solution's stored cluster configuration; no request body is required. Returns `409 ALREADY_RUNNING` when a recluster or an XML conversion is already active — the run shares the per-solution conversion lock, so parallel imports are rejected as well. A client disconnect does not abort the run.

## GET /api/relationship-graph/:fileName

Complete relationship-diagram model for one FileMaker file (`:fileName` = `File_Name`): table occurrences with geometry and color, relation-participating fields per TO, and relationships grouped by join predicate.

**Response `data`**

- `viewport` — bounding box over all TO boxes
- `tableOccurrences[]` — `uuid`, `id`, `name`, `baseTable`, `dataSource`, `view` (`Full`/`Related`/`Collapse`), `bounds`, `color`, `fields[]` (`{ uuid, id, name, dataType, isUsedInRelation }`)
- `relationships[]` — `id`, `left`/`right` (`{ toUuid, toName, cascadeCreate, cascadeDelete }`), `predicates[]` with operator symbols (`=`, `≠`, `<`, `≤`, `>`, `≥`, `×`)

Errors: `404 OBJECT_NOT_FOUND` when the file is not in the catalog.

---

See also: [References API](References%20API.md) (tabular reference lookups), [Solutions API](Solutions%20API.md) (cluster state lives per solution).
