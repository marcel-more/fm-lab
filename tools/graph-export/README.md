# Community Detection

Batch that computes **community / module clusters** over the FileMaker object
graph and writes them into the master DuckDB, so the Graph Explorer can color
nodes by module.

It runs **two ways**: automatically as the gated **Phase 7** of the `convert-xml`
pipeline (from-scratch / force-rebuild imports only — see _"Why gated"_ below), and
standalone via the command below for a manual (re-)cluster (the `fm-graph-cluster`
skill drives it this way for resolution sweeps + semantic naming).

## Run

```bash
bash tools/graph-export/cluster.sh
```

Knobs (env):

| Var                        | Default | Meaning                                                        |
| -------------------------- | ------- | -------------------------------------------------------------- |
| `FMLAB_CLUSTER_ENGINE`     | `auto`  | `auto` \| `louvain` \| `leiden`                                |
| `FMLAB_CLUSTER_RESOLUTION` | `1.0`   | Louvain/Leiden resolution (higher → more, smaller communities) |
| `FMLAB_CLUSTER_SEED`       | `42`    | PRNG seed — fixed so colors are reproducible between runs      |

The three defaults above apply only when the solution has **no persisted sweep winner**:
`cluster.sh` reads `solutions/<id>/state/cluster.json` (written by `fm-graph-cluster`) first —
the same reader (`tools/lib/cluster_config.sh`) the pipeline's Phase 7 uses — so a bare run
re-partitions at the granularity that was actually chosen; the env knobs override it.
| `FMLAB_CLUSTER_NO_SYNC`    | –       | set `1` to skip the rest-api copy + `/api/admin/reload`        |

Engine selection (`auto`): **Leiden** when `python3` + `igraph` are importable,
otherwise the guaranteed Node/**Louvain** baseline (no hard Python dependency).
The chosen engine is persisted in `ObjectClusters.Engine` (provenance).

## Pipeline

```
graph_export_logical.sql  →  edges.csv         (SELECT FROM ClusterEdges; nodes = uuid::file; ORDER BY → stable)
cluster_louvain.mjs       →  communities.csv   (node → community; graphology; Q on stderr)
  └ or cluster_leiden.py                        (igraph, optional drop-in; Q on stderr)
cluster_load.sql          →  ObjectClusters + CommunityNames (split uuid::file; heuristic names)
sync_db.sh                →  rest-api/db copy + reload
```

**Clone node key.** Node IDs are composite `uuid::file` (export ≥ 3.0.0), so two clones of the same
UUID in different files stay **distinct** cluster nodes (previously they collapsed into one node and
merged their edges → possibly wrong modules). `cluster_load.sql` splits the composite back into
`(Object_UUID, File_Name)`. NULL-file synthetics (PluginFunction) stay bare `uuid`. On a clone-free
solution every UUID is file-unique ⇒ `uuid::file` is a pure node relabel = structurally identical
partition (same Q/K), one-time color re-baseline only.

The edge export is **sorted** (`ORDER BY source, target`), so `edges.csv` is
bit-identical across runs and the (order-sensitive) engines produce the same
partition for a fixed seed+resolution — reproducible cluster colors.

The clustering input is the **same cleaned logical graph the Explorer renders**
in `mode=logical` (operational links, sub-objects hoisted to their container,
builtins + orphans removed) — so cluster colors match the shown topology.

### Logical edge source — the `ClusterEdges` view (`graph_export_logical.sql` ≥ 2.0.0)

The cleaned edge set is a **DuckDB view**, not inline SQL. `convert-xml` Phase 5
([ingestion/sql/convert_xml_05_homes.sql](../../ingestion/sql/convert_xml_05_homes.sql))
creates two views as a single source of truth:

- **`LogicalLinks`** — operational links, sub-objects hoisted to their container,
  containment scaffold + orphans removed, `(source,target)`-deduped. **With** builtins.
  Canonical definition: [ingestion/sql/convert_xml_05_homes.sql](../../ingestion/sql/convert_xml_05_homes.sql) (P5; the API template graph_logical_links.sql is a read-only consumer stub).
- **`ClusterEdges`** — `LogicalLinks` minus `BuiltinFunction` endpoints. This is
  the exact engine input and the canonical **logical degree** definition the
  `fm-graph-cluster` skill uses for its hub analysis.

`graph_export_logical.sql` just does `SELECT … FROM ClusterEdges ORDER BY source, target`.
The 2.0.0 switch from inline-CTE to view-read is **bit-identical**.
Because `cluster.sh` runs the export `-readonly`, the views must already exist —
a fresh `convert-xml --batch` creates them in P5.

## Output tables

```
ObjectClusters(Object_UUID, File_Name, Community INT, Engine)   -- key (Object_UUID, File_Name)
CommunityNames(Community, Engine, Member_Count, Dominant_Type, Dominant_File,
               Top_Member_UUID, Top_Member_Label, Sample_Labels[],
               Heuristic_Name,        -- always (deterministic, no LLM)
               Semantic_Name,         -- optional naming step, nullable
               Semantic_Description)  -- optional, nullable (fm-deep-research)
```

Heuristic name = `Dominant_File · Top_Member_Label (+N)`. Display in the Explorer
is `COALESCE(Semantic_Name, Heuristic_Name)`. The optional semantic-naming step
(`fm-graph-cluster` reads the hint columns and fills `Semantic_Name`; `fm-deep-research`
adds `Semantic_Description` for the segments it scans) is not required — the explorer
works fully on heuristic names.

## Semantic naming via `fm-graph-cluster`

The `Semantic_Name` / `Semantic_Description` columns are filled by the
**`fm-graph-cluster`** skill (`.claude/skills/fm-graph-cluster/`). Beyond just
naming, the skill **picks the resolution itself**: it sweeps candidate
resolutions (export edges once, run the engine N×), scores each by **modularity
`Q`** (now emitted on the engine's stderr — `modularity=…`) plus distribution
guardrails relative to the solution size, runs the winner through `cluster.sh`
once, then fills the names via bundled `UPDATE`s and writes an analysis report to
`output/graph_cluster_report_<ts>.md`.

Because `cluster_load.sql` rebuilds `CommunityNames` via `CREATE OR REPLACE`,
**every cluster run wipes the semantic names** — so naming is always the skill's
_last_ write step, and the rest-api sync runs once at the very end (after naming)
so the Explorer sees the named partition in a single reload. The sync itself lives
in the reusable `sync_db.sh` (cluster.sh step 5 and the skill both call it).

### Persistent name cache (survives a cluster run)

To keep `Semantic_Name` from being lost on every re-cluster, `cluster.sh` wraps the
load with a **drift-tolerant cache** (`cache_save.sql` → load → `cache_apply.sql`):

- **`cache_save.sql`** (before the replace) snapshots the current names at **object
  granularity** (`Object_UUID → name`) into the standalone table `SemanticNameCache`
  — only if names exist (an empty snapshot never overwrites a good cache).
- **`cache_apply.sql`** (after the load) restores names onto the **new** communities by
  **majority vote**: each new community inherits the cached name held by ≥ `τ_purity`
  (default 0.6) of its cache-covered members, provided coverage ≥ `τ_coverage` (0.5). A
  cached name maps to **at most one** new community (split-safe); merges and mostly-new
  modules stay dirty (`Semantic_Name IS NULL`) for the skill to (re)name.

Object-level keying sidesteps the unstable integer `Community` id. Measured reuse on a
~3 % input drift: **97 %** of nodes keep their name automatically; identical/resolution
re-runs restore ~100 %. `cluster.sh` logs `restored N/Z, node-reuse=R`; if `R` falls
below `FMLAB_CACHE_FLOOR` (0.5) it warns that a full re-name is advisable. Knobs:
`FMLAB_CACHE_{DISABLE,TAU_PURITY,TAU_COVERAGE,FLOOR}`. The `fm-graph-cluster` skill then
names **only the dirty communities**.

**Partition, not overlap:** Louvain/Leiden produce a _partition_ — every node belongs to
**exactly one** community (`ObjectClusters` is keyed `(Object_UUID, File_Name)`, unique per node).
Overlapping membership would require a different algorithm (link communities / clique percolation)
and is out of scope.

## How the Explorer consumes it

`graph.service.js` enriches subgraph nodes with `community` (int color key) +
`communityName` (display) via a **guarded** lookup — only if `ObjectClusters`
exists (`information_schema` check). The subgraph SQL itself never joins the
cluster tables, so the Explorer keeps working _before_ the first cluster run and
on databases that never clustered (community stays `null`). The standalone
`/graph` view exposes a Type↔Community color toggle + legend; the embedded
object-view panel does not.

## Why gated, not run on every import

> **Disclaimer — illustrative numbers only.** The figures below come from a single
> run against one example FileMaker solution. That solution is **not necessarily
> representative**; the numbers are for illustration and **cannot be transferred 1:1**
> to your own solutions (graph size, density and hardware all change them). The
> _conclusion_ that follows holds regardless — it is about why re-clustering is gated
> to from-scratch imports, not about any particular runtime.

Example run (one sample solution):

- input: **178 478** logical edges / **56 794** nodes (builtins/orphans removed)
- Louvain: parse **535 ms**, cluster **129 ms**, peak RSS **243 MB**
- result: **453** communities, largest 4 879, avg 125 members
- total wall-clock incl. export + load: **~1–2 s**

The compute itself is cheap, **but** it needs Node (or Python) and the fully built
`ObjectCatalog`/`ObjectLinks`. The import pipeline is otherwise pure DuckDB SQL. It
therefore runs as a **gated tail phase (P7)**: only on from-scratch / force-rebuild
imports (or when `ObjectClusters` is empty), **never** on incremental imports —
`cluster.sh` has no warm start, so re-partitioning every import would churn community
boundaries in untouched files and mask the drift signal. P7 is non-fatal, and
`FM_SKIP_CLUSTER=1` disables it. It writes only the **raw** partition; semantic naming
+ the resolution sweep stay the `fm-graph-cluster` skill's job.

## Dependencies

- `graphology` + `graphology-communities-louvain` — root `devDependencies`
  (build-time only; no new REST-API runtime dependency).
- optional: `python3` + `python-igraph` for the Leiden enhancement.
