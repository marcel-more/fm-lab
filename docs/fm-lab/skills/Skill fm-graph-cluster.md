# Skill: fm-graph-cluster

Segments the solution's object graph into modules (communities) at a resolution that fits the solution's size, gives the modules semantic names and persists the chosen granularity — the finishing touch for graph analysis. The written description of a whole solution is the job of [fm-deep-research](Skill%20fm-deep-research.md), which builds on this partition.

| | |
|---|---|
| **Category** | Agentic analysis |
| **Slash command** | `/fm-graph-cluster [--resolution=<x>] [--candidates=…] [--engine=auto\|louvain\|leiden] [--seed=<n>] [--name-threshold=<n>] [--rename-all] [--no-rule-names] [--interactive] [--no-sync]` |
| **Say it naturally** | "cluster the graph", "find the modules", "name the clusters", "segment the solution into modules" — English and German |
| **Input** | none required; options tune the sweep and the naming |
| **Reads** | `db/fm_catalog.duckdb` — the cleaned logical edge set (`ClusterEdges`) and the hint columns of `CommunityNames`, including the dominant script/layout folder of each community |
| **Writes** | the tables `ObjectClusters` and `CommunityNames` in the master catalog, the run protocol `output/graph_cluster_run_<solution>_<timestamp>.md`, the granularity file `solutions/<id>/state/cluster.json`, the `n_named` count in `solutions/<id>/state/cluster_run.json`, and — unless `--no-sync` — the REST API's read copy |
| **Prerequisites** | a catalog built with the graph views (`LogicalLinks`, `ClusterEdges`); Node.js with `graphology` (Louvain); optionally Python 3 with `igraph` (Leiden) |
| **Under the hood** | orchestrates `tools/graph-export/` — `cluster.sh`, the Louvain/Leiden engines, `cluster_load.sql`, `sync_db.sh` — plus the sweep driver `scripts/sweep.mjs` and the shared readiness script `_shared/scripts/cluster_state.sh` |
| **Skill directory** | `.claude/skills/fm-graph-cluster/` |
| **Related** | [Skill fm-deep-research](Skill%20fm-deep-research.md) (solution report on this partition) · [Skill fm-test](Skill%20fm-test.md) (cluster scope) · [Skill fm-show](Skill%20fm-show.md) (`--graph`) · [Skill convert-xml](Skill%20convert-xml.md) |

## What it adds to the automatic clustering

The clustering engine, the heuristic names and the two-table model (`ObjectClusters`, `CommunityNames`) exist independently of the agent: the ingestion pipeline clusters automatically at the end of a fresh build, and the Graph Explorer has a rebuild button. A heuristic name, though, reads like `Kunden · Eingangsdaten laden [Datum] (+141)` — the dominant file, the anchor object and a member count. It is correct and useless at the same time.

What the skill adds is judgement in two places:

- **Which resolution fits this solution.** The cleaned edge set is exported once and the engine runs for each candidate resolution (default `0.5, 0.75, 1.0, 1.5, 2.0, 3.0`) without a single database write. Each candidate is scored by modularity with guardrails against one giant community, fragmentation into singletons and a module count outside the band that fits the solution's size. The full ranking is always shown; the top score is picked automatically unless the top two are a near tie or `--interactive` is set, and `--resolution=<x>` skips the competition altogether. One clean final run with the winner then produces the partition — deterministic for the same engine, seed and resolution.
- **What the modules are called.** Scaffolding communities — a file's access-rights set, a file's menu overrides — are named by rule (`Zugriffsrechte <file>`, `Menü-Overrides <file> · <menu>`, in the language of the conversation), so the model only reads the hints of the communities that need judgement. Every remaining community above the size threshold receives a concise semantic name synthesised from its dominant file and object type, the dominant script or layout folder of its members (the developers' own module vocabulary), its anchor object and a sample of member labels — `Kunden-Import & Eingangsdaten-Aufbereitung` instead of the heuristic string above. The whole list is named in one pass, so the vocabulary is coherent across modules. Names of communities that survived a re-clustering unchanged are restored from a cache first; only genuinely new, split or merged modules are named afresh. Small communities keep their heuristic name. `--rename-all` clears every name first and asks before it does.

The winning granularity is persisted per solution in `cluster.json`, and the pipeline's automatic re-clustering after a rebuild, the Explorer's rebuild button and a plain `cluster.sh` run all reuse it. The named partition is then synced to the REST API's read copy exactly once, so the web client never shows an intermediate, unnamed state.

**Result:** graph analysis with names that mean something. The Graph Explorer colours and labels the modules, the cluster overview lists them, [fm-test](Skill%20fm-test.md) runs tests per cluster, and a subgraph opened with [fm-show](Skill%20fm-show.md) `--graph` is readable without decoding community numbers. The deliverable of the run is the partition itself; the run protocol written alongside records what was measured and decided.

## The run protocol

`output/graph_cluster_run_<solution>_<timestamp>.md` is a protocol, not an analysis: the environment and solution size, the complete resolution ranking with the chosen candidate and why, the naming statistics (named, restored from cache, left heuristic), the top hubs by logical cluster degree, and the full community list. The chat shows a summary of at most eight lines with a link to the file. For the interpretation — what the modules mean, how the solution is built, what stands out — run [fm-deep-research](Skill%20fm-deep-research.md) on the same partition.

## Before you run it

The preflight reports the readiness of the cluster layer: whether a partition exists, whether it was produced at the last sweep's granularity, and whether names are present. A partition that was re-built at a different resolution than the sweep winner (for example by an older tooling version) is healed by this run.

## How to use it

```
/fm-graph-cluster                                  # sweep, auto-pick, name, persist, sync
/fm-graph-cluster --resolution=1.5 --no-sync       # fixed resolution, no publish
/fm-graph-cluster --candidates=1,2,3 --interactive # custom sweep, confirm the choice
/fm-graph-cluster --rename-all                     # fresh vocabulary for every community (asks first)
```

Or ask: *"cluster the graph and name the modules"*, *"segmentiere die Lösung in Module"*.

## Options

| Option | Default | Effect |
|---|---|---|
| `--resolution=<float>` | — | Skip the sweep and force this resolution |
| `--candidates=<list>` | `0.5,0.75,1.0,1.5,2.0,3.0` | Candidate resolutions for the sweep |
| `--engine=auto\|louvain\|leiden` | `auto` | Leiden when Python with `igraph` is available, otherwise Louvain |
| `--seed=<int>` | `42` | Random seed — a fixed seed means a reproducible partition and stable colours |
| `--name-threshold=<n>` | `3` | Minimum member count for a semantic name; smaller communities keep the heuristic name |
| `--rename-all` | off | Clear all semantic names before naming (asks first; discards cache reuse) |
| `--no-rule-names` | off | Skip the rule-based names for scaffolding communities |
| `--interactive` | off | Confirm the resolution choice instead of auto-picking |
| `--no-sync` | off | Skip the final sync to the REST API copy |
