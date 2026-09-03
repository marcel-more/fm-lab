# Graph API

Endpoints under `/api/graph/*` expose the object graph (`ObjectCatalog` + `ObjectLinks`) for interactive exploration: focus-centered subgraphs, lazy expansion, the top-down atlas, community/cluster information, and search. `/api/relationship-graph/:fileName` additionally renders the classic FileMaker relationship diagram data for one file.

Common behavior:

- All GET routes accept the standard `format` / `meta` / `debug` parameters ([REST API Conventions](../REST%20API%20Conventions.md)).
- Focus-based routes resolve the focus node clone-aware: optional `focus_file` disambiguates shared UUIDs, otherwise `409 AMBIGUOUS_UUID` (response details list the matching files).
- Node identifiers in responses are composite `uuid::file` (`id`) plus the raw `uuid` — the composite key stays unique across cloned files.
- Subgraph/overview responses are LRU-cached for 5 minutes per parameter set.

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

v1 start objects: **Script** and **Layout**. A layout start maps onto a seed-script set via an entry preset (see `/graph/trace/entries`).

| Parameter | Type | Default | Description |
|---|---|---|---|
| `start` | string | — | **Required.** Start object UUID |
| `start_file` | string | — | Clone disambiguation of the start object |
| `entry` | enum | type-dependent | Entry preset for layout starts: `layout_runtime` (triggers of the layout and its objects + button scripts) · `layout_inbound` (scripts navigating onto the layout) · `layout_full` (both). Script starts ignore it |
| `up_depth` | integer | `3` | Chain budget upward (caller levels, 0–16) |
| `down_depth` | integer | `6` | Chain budget downward (subscript levels, 0–16) |
| `trigger_depth` | integer | `1` | Trigger-cascade stages (0–3); layouts entered by a cascade fire the next stage only above 1 |
| `expand_up` | boolean | `false` | Also expand the touch set of the upstream chain |
| `include_local_vars` | boolean | `false` | Include local `$` variables of the chain scripts (`$$` globals are always included) |
| `include_buttons` | boolean | `false` | Include `button_action` triggers of entered layouts in the cascade |
| `include_interaction_triggers` | boolean | `false` | Include interaction-class events in the cascade. By default the cascade skips events that only user interaction can fire (`OnLayoutKeystroke`, `OnObjectKeystroke`, `OnGestureTap`, `OnObjectModify`, `OnExternalCommandReceived`) — a running script presses no keys, so these triggers cannot fire during the traced flow. Script-reachable events (`OnLayoutEnter`/`Exit`, `OnRecordLoad`/`Commit`/`Revert`, `OnModeEnter`/`Exit`, `OnObjectEnter`/`Exit`/`Save`/`Validate`, `OnPanelSwitch`, `OnViewChange`, `OnLayoutSizeChange`, the AVPlayer events) always stay in. Entry presets of a layout start are unaffected — there, interaction triggers are legitimate entry paths |
| `include_builtins` | boolean | `false` | Include builtin-function targets |
| `node_limit` | integer | `1000` | Node cap; ranked by trace role (start > chain > triggered > touched > cascade-touched > context), then depth, then degree — `truncated: true` signals clipping |
| `hub_degree` | integer | `100` | Degree threshold for the `isHub` flag |
| `exclude` | string | — | Boundary exclusions: comma-separated composite node IDs (`<uuid>::<file>`; an item without `::` addresses an object whose `File_Name` is NULL). Excluded nodes stay visible in the result but are not expanded: the walk stops at them (call chain and cascade), they contribute no touch edges, and an excluded layout fires no trigger cascade. Excluding the start object is a no-op. An excluded **field** stays a visible touch target but no longer arms the selective object-level triggers of stage 3 — object triggers that would fire only because an object displays that field stay silent. Malformed items answer `400`; unknown UUIDs are inert |

**Response `data`** — subgraph shape plus:

- per node: `traceRole` (`start` · `chain_down` · `chain_up` · `triggered` · `touched` · `trigger_touched` · `trigger_owner`), `traceDepth` (signed; upstream negative) and `isExcluded` (true on boundary nodes from the `exclude` list)
- per edge: `traceKind` (`chain` · `trigger` · `touch` · `induced`); `induced` edges are context edges between already-collected nodes (`displays_field`, `displays_variable`, `context_table`, `uses_valuelist`) and never expand the node set
- `trace`: `{ start: { uuid, file, type }, entry, seeds[], excluded[], suggestions[], stats: { dynamicCalls } }` — the seed scripts of stage 0; `excluded[]` resolves every `exclude` item against the catalog as `{ id, uuid, file, label, type }` (label/type are null for unknown UUIDs), including items the damped trace no longer reaches
- `trace.suggestions[]`: server-computed exclusion candidates among the traced scripts — shared utilities whose global metrics mark them as hubs (trigger fan-in ≥ 25, callers ≥ 50, or field touches ≥ 100), each as `{ id, uuid, file, label, type, trigIn, fanIn, touchOut, score, reason }` with `reason` ∈ `trigger_hub` · `call_hub` · `touch_hub`, score-descending, capped at 10. The start object, already excluded nodes, and chain nodes of the start's file or at chain depth ≤ 1 are never suggested. Suggestions are never applied automatically — clients offer them and pass accepted ones back via `exclude`
- `stats.dynamicCalls`: number of call steps of the traced scripts that resolve their target by name at runtime (Perform Script "by name" and its on-server variants) — these have no static edge, so the trace is a static approximation

Errors: `404 OBJECT_NOT_FOUND`, `409 AMBIGUOUS_UUID`, `422 TRACE_UNSUPPORTED_START` (start type without v1 trace semantics; details name the supported types), `422 TRACE_EMPTY_ENTRY` (the chosen entry preset yields no seed scripts; details carry the available presets with seed counters).

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

Composition responses return `tiles[]` (aggregate tiles with `key`, `label`, `node_count`, `weight`; leaf tiles with `uuid`, `file`, `type`; a folded tail becomes a `kind: "rest"` tile). Topology responses return super-`nodes[]` and undirected, de-duplicated `edges[]` with weights.

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
