---
name: fm-graph-cluster
version: 0.10.0
description: Segments the FileMaker object graph in `db/fm_catalog.duckdb` into modules (communities) - sweeps candidate resolutions and scores them (modularity Q + distribution guardrails), runs the winner, names the communities semantically (`CommunityNames.Semantic_Name`), writes a run protocol to `output/` and syncs the named partition to the Graph Explorer. Use it to create or re-name the segmentation; for a solution-level research report (business context, architecture, findings, recommendations) use `fm-deep-research` instead. Orchestrates the existing tools/graph-export tooling (cluster.sh, cluster_louvain.mjs/cluster_leiden.py, cluster_load.sql); it does not replace it. Triggers (English) - "/fm-graph-cluster", "cluster the graph", "detect communities/modules", "name the clusters", "segment the solution into modules". Triggers (German) - "clustere den Graph", "finde die Module/Communities", "benenne die Cluster", "segmentiere die Lösung in Module". Triggers (Spanish) - "agrupa el grafo", "segmenta la solución en módulos". Triggers (French) - "regroupe le graphe", "segmente la solution en modules". Triggers (Italian) - "raggruppa il grafo", "segmenta la soluzione in moduli". Triggers (Dutch) - "cluster de graaf", "segmenteer de oplossing in modules". Triggers (Portuguese) - "agrupe o grafo", "segmente a solução em módulos". Triggers (Swedish) - "klustra grafen", "segmentera lösningen i moduler". Triggers (Japanese) - "グラフをクラスタリングして", "ソリューションをモジュールに分割して". Triggers (Korean) - "그래프를 클러스터링해 줘", "솔루션을 모듈로 분할해 줘". Triggers (Chinese) - "对图进行聚类", "将解决方案划分为模块".
---

# FileMaker Graph Clustering & Semantic Naming

## Purpose

Segment the object graph into **modules (communities)**, pick the **resolution that fits this
solution's size**, give each community a **semantic name**, persist the granularity and sync the
named partition to the Graph Explorer. The engine, the heuristic names and the two-table model
(`ObjectClusters` + `CommunityNames`) already exist in `tools/graph-export/` — this skill adds
**resolution selection** and **naming**. It does **not** write a solution description: that is
`fm-deep-research` (member scan, `Semantic_Description`, report). If the user passes
`--deep-research`, say so, offer to run this skill now and `fm-deep-research` right after.

## Ground rules

- **DuckDB**: plain command per CLAUDE.md §2; with a session pin use the literal bundle path
  `solutions/<id>/db/fm_catalog.duckdb`. Never read `rest-api/db/`. Never install DuckDB.
- **Read-only** for all measuring (preflight, sweep, hints, protocol data). **Writes only** in the
  final `cluster.sh` run (D), the naming `UPDATE`s (E), `cluster.json` (F) and the sync (H).
- **SQL identifiers stay English.** Response language follows the prompt; generated
  `Semantic_Name`s are written in the prompt language (default German); **FileMaker identifiers
  stay original**. Policy: [`_shared/response-language.md`](../_shared/response-language.md).
- **No silent caps**: every bound (name threshold, ranking) is logged in chat and protocol.
- **Compact output**: DuckDB results as `-markdown` (never box tables), each result read once.
  This skill is often delegated to a sub-agent by `fm-deep-research` — the chat summary (≤ 8
  lines) is the only thing that must come back.

## Parameters

| Parameter | Default | Effect |
|---|---|---|
| `--resolution=<float>` | — | Skip the sweep, force this resolution (single measurement) |
| `--candidates=0.5,1.0,…` | `0.5,0.75,1.0,1.5,2.0,3.0` | Candidate list for the sweep |
| `--engine=auto\|louvain\|leiden` | `auto` | auto → leiden if python3+igraph, else louvain |
| `--seed=<int>` | `42` | PRNG seed (fixed ⇒ reproducible partition + colours) |
| `--name-threshold=<N>` | `3` | Only communities with `Member_Count ≥ N` get a semantic name |
| `--rename-all` | off | Clear **all** semantic names first (destroys cache reuse) — **asks before doing so** |
| `--no-rule-names` | off | Skip the rule-based names for scaffolding communities (access rights, menu overrides) |
| `--interactive` | off | Confirm the resolution choice instead of auto-pick |
| `--no-sync` | off | Skip the final rest-api sync/reload |

## Workflow (A–H)

```
A Preflight ─▶ B Sweep + ranking ─▶ C Pick ─▶ D Final run (winner) ─▶ E Naming
            ─▶ F cluster.json ─▶ G Protocol + chat summary ─▶ H Sync (once)
```

### A. Preflight — read-only, abort clearly

```bash
bash .claude/skills/_shared/scripts/cluster_state.sh          # solution, DB, partition, drift flags
ls tools/graph-export/cluster.sh tools/graph-export/graph_export_logical.sql \
   tools/graph-export/cluster_load.sql tools/graph-export/sync_db.sh
node -e "require('graphology'); require('graphology-communities-louvain')" 2>&1 && echo "louvain OK"
python3 -c "import igraph" 2>/dev/null && echo "leiden available" || echo "leiden NOT available (auto → louvain)"
```

State the solution id + source from the JSON. Abort with a concrete next step when:
`db` missing → `convert-xml`; `views_present=false` → the DB predates the graph views, re-run
`convert-xml --batch`; tooling files missing → name the file; neither graphology nor igraph →
`npm install`. Note `level`/`flags`: a `resolution_mismatch` means the current partition was
built at a different granularity than the last sweep winner (a bare `cluster.sh` run) — this run
will heal it. A `no_partition` is fine (first run: Phase D creates the tables).

### B. Sweep + ranking — `scripts/sweep.mjs` (export once, engine N×)

```bash
node .claude/skills/fm-graph-cluster/scripts/sweep.mjs \
  --db="$PWD/db/fm_catalog.duckdb" --tools="$PWD/tools/graph-export" \
  --candidates=0.5,0.75,1.0,1.5,2.0,3.0 --seed=42 --engine=auto
```

Read-only; prints one JSON (`engine`, `engine_reason`, `seed`, `q_available`, `size`, `band`,
`near_tie`, `timings_ms`, `candidates[]` with `resolution, K, Q, largest_share, singleton_share,
band_penalty, score, rank`, `winner`, `runner_up`). Rubric:
`score = 1.0·Q − 1.5·max(0, largest_share−0.25) − 1.0·max(0, singleton_share−0.40) − 0.5·band_penalty`;
band = mean module size 30–150 ⇒ K in `[n_nodes/150, n_nodes/30]`, floor `n_files`. If
`q_available=false` the guardrails alone rank. **Always show the full ranking table.**
`--resolution=X` → run the sweep with `--candidates=X` (X wins by definition; you still get `size`).

### C. Pick

Auto-pick the top score. Ask via `AskUserQuestion` **only** when `near_tie=true` or `--interactive`.

### D. Final run with the winner

```bash
FMLAB_CLUSTER_RESOLUTION=<winner> FMLAB_CLUSTER_SEED=<seed> \
FMLAB_CLUSTER_ENGINE=<engine> FMLAB_CLUSTER_NO_SYNC=1 bash tools/graph-export/cluster.sh
```

Exactly one run, engine/seed from the sweep JSON (same partition as measured). `NO_SYNC=1` — the
Explorer never sees the un-named intermediate state.

> ⚠ `cluster_load.sql` rebuilds `CommunityNames` via `CREATE OR REPLACE` and **wipes semantic
> names**; `cluster.sh` restores them from `SemanticNameCache` by majority vote (log line
> `cache: restored N/M, node-reuse=…`). Naming is therefore the *last* write step, after D.
> `--rename-all`: ask first, then `UPDATE CommunityNames SET Semantic_Name=NULL, Semantic_Description=NULL;`.

### E. Semantic naming

**E.1 Rule-based names first** (unless `--no-rule-names`): communities that are pure
scaffolding — per-file access-rights sets, menu overrides — get their name from SQL, in the
prompt language via templates. On a large corpus this shrinks the hint list from ~150 to ~25
rows the model actually has to read:

```bash
duckdb db/fm_catalog.duckdb -markdown -c "SET VARIABLE engine='<engine>'; SET VARIABLE threshold=<N>; \
  SET VARIABLE tpl_access='Zugriffsrechte {file}'; SET VARIABLE tpl_menu='Menü-Overrides {file} · {menu}';" \
  -c ".read .claude/skills/fm-graph-cluster/scripts/rule_names.sql"           # EN: 'Access rights {file}' / 'Menu overrides {file} · {menu}'
```

**E.2 Hints for the dirty rest** (`Semantic_Name IS NULL`, ≥ threshold) — cache-restored and
rule-named communities are the existing vocabulary, stay consistent with them. Compact output,
read once:

```bash
duckdb db/fm_catalog.duckdb -readonly -markdown -c "SET VARIABLE engine='<engine>'; SET VARIABLE threshold=<N>;" \
  -c ".read .claude/skills/fm-graph-cluster/scripts/naming_hints.sql"
```

Per community: `Dominant_File` (context), `Dominant_Type` (character), `Dominant_Folder` (the
developers' intended module name — strongest hint when present), `Top_Member_Label` (anchor),
`Sample_Labels` (word field). Name the **whole list in one pass** for a coherent vocabulary
(no duplicates). Example: `Kunden · Eingangsdaten laden [Datum] (+141)` → **"Kunden-Import &
Eingangsdaten-Aufbereitung"**. Write all names in **one** bundled call of generated `UPDATE`s
(never `CREATE OR REPLACE`), single quotes doubled (`'` → `''`):

```sql
UPDATE CommunityNames SET Semantic_Name = 'Kunden-Import & Eingangsdaten-Aufbereitung'
  WHERE Community = 7 AND Engine = 'leiden';
```

Below-threshold communities keep `Semantic_Name = NULL` (Explorer falls back to
`COALESCE(Semantic_Name, Heuristic_Name)`). Then refresh the run summary:
`bash .claude/skills/_shared/scripts/cluster_run_named.sh`. **Log** rule-named vs. model-named
vs. cache-restored vs. heuristic.

### F. Persist the granularity

```bash
bash .claude/skills/fm-graph-cluster/scripts/write_cluster_json.sh <engine> <winner> <seed> <Q>
```

Auto-P7, the Rebuild button and `cluster.sh` reuse this `solutions/<id>/state/cluster.json`.

### G. Run protocol + chat summary

Protocol → `output/graph_cluster_run_<solution>_<ts>.md` (`TS=$(date +%Y-%m-%d_%H-%M-%S)`, Write
tool). It is a **protocol, not an analysis** — numbers and tables only:

1. **Metadata** — solution + source, DB path, engine (+ reason), seed, script versions
   (`@version` of `cluster_load.sql`), size (`n_nodes`/`n_edges`/`n_files`), preflight level/flags,
   timings per phase.
2. **Ranking** — full candidate table + chosen resolution + why (score / near-tie / forced).
3. **Naming statistics** — communities total, rule-named (access / menu), model-named,
   cache-restored (node-reuse % from the `cluster.sh` log), left heuristic (below threshold),
   rename-all yes/no.
4. **Hubs** — top 20 by logical cluster degree (`scripts/hubs.sql`, `SET VARIABLE engine`,
   `"limit"`, `-markdown`). Note "degree = logical cluster degree (v2)". Builtins/Calculation instances never
   appear (excluded from `ClusterEdges`). **Same name ≠ same object**: a name recurring across files
   is per-file copies (node key `(uuid, file)`), i.e. duplication — quantify with
   `COUNT(DISTINCT File_Name)`, never call it a shared hub.
5. **Community list** — all communities (`scripts/community_list.sql`): name, semantic yes/no,
   members, dominant file/type.

Chat: **≤ 8 lines** — winner (resolution, K, Q), named N/M (restored R), hubs top-3, link
`[output/graph_cluster_run_<solution>_<ts>.md](output/graph_cluster_run_<solution>_<ts>.md)`, and
the pointer "for a solution description run `/fm-deep-research`".

### H. Sync (once, unless `--no-sync`)

```bash
bash tools/graph-export/sync_db.sh      # resolves the active solution itself; publishes master → rest-api copy + reload
```

## Error cases

| Symptom | Cause | Reaction |
|---|---|---|
| `cluster_state.sh` exit 4 | no master DB | abort → `convert-xml` |
| `views_present=false` | DB built before the graph views | abort → `convert-xml --batch` |
| engine import fails | `npm install` missing / no igraph | abort (louvain) or auto-fallback (leiden→louvain, logged) |
| `cluster.sh` exit 7 | DB locked by convert-xml | abort, retry after the import |
| `cache: restored 0/M` on a re-run | cache empty (force-rebuild recreated the DB) | expected — full naming pass, say so |
| `--deep-research` given | flag moved | explain, offer this run + `fm-deep-research` afterwards |

## Definition of done

Preflight states solution + level; sweep ran once with a full ranking; one final run with the
winner; `Semantic_Name` filled for the dirty rest ≥ threshold via `UPDATE`; `cluster.json` and
`cluster_run.json.n_named` current; protocol written; chat ≤ 8 lines with link; sync exactly once.

## References

- `scripts/sweep.mjs` — sweep driver + rubric (read when the ranking looks odd)
- `scripts/rule_names.sql` (E.1), `scripts/naming_hints.sql`, `scripts/hubs.sql`, `scripts/community_list.sql`, `scripts/write_cluster_json.sh`
- `../_shared/scripts/cluster_state.sh`, `../_shared/scripts/cluster_run_named.sh`, `../_shared/scripts/community_members.sql` (shared with `fm-deep-research`)
- `tools/graph-export/README.md` — engine, cache, `cluster.sh` env knobs
