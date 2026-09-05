---
name: fm-deep-research
version: 0.9.0
description: Writes a solution-level research report (executive summary, business context, architecture, technical build, findings, recommendations, segment appendix) from the clustered object graph in `db/fm_catalog.duckdb` and the member objects of its largest segments, rendered from a Markdown template into `output/`; the chat shows only a short summary with a link. Use it to understand a solution you did not build (onboarding, takeover, technical-debt review); use `fm-graph-cluster` to create or re-name the segmentation itself - this skill checks for a usable partition first and asks whether to run it. Triggers (English) - "/fm-deep-research", "deep research on this solution", "describe the architecture of this solution", "write a solution report", "what does this solution do as a whole". Triggers (German) - "Deep Research zur Lösung", "beschreibe die Architektur dieser Lösung", "erstelle einen Lösungsbericht", "was macht diese Lösung insgesamt". Triggers (Spanish) - "describe la arquitectura de esta solución", "informe de la solución". Triggers (French) - "décris l'architecture de cette solution", "rapport de la solution". Triggers (Italian) - "descrivi l'architettura di questa soluzione", "rapporto della soluzione". Triggers (Dutch) - "beschrijf de architectuur van deze oplossing", "oplossingsrapport". Triggers (Portuguese) - "descreva a arquitetura desta solução", "relatório da solução". Triggers (Swedish) - "beskriv lösningens arkitektur", "lösningsrapport". Triggers (Japanese) - "このソリューションのアーキテクチャを説明して", "ソリューションレポートを作成して". Triggers (Korean) - "이 솔루션의 아키텍처를 설명해 줘", "솔루션 보고서를 작성해 줘". Triggers (Chinese) - "描述这个解决方案的架构", "生成解决方案报告".
---

# FileMaker Solution Deep Research

## Purpose

Produce a **written description of a whole solution** — what it is for, how it is built, what
stands out, what to do about it — from the clustered object graph and the real member objects
of its largest segments. The deliverable is a Markdown **report rendered from a template**; the
chat only gets the short summary and the link. `fm-graph-cluster` creates and names the
segmentation (sweep, `Semantic_Name`); this skill consumes it, adds `Semantic_Description` for
the scanned segments and never re-partitions on its own.

## Prerequisites

- Master catalog with the graph views (`ClusterEdges`) — else `convert-xml --batch`.
- A **usable partition** (`ObjectClusters`/`CommunityNames`), checked in R0. Semantic names
  from `fm-graph-cluster` are *not* required (this skill reads the members itself), but the
  **sweep granularity** is: a default-1.0 partition describes fragments, not modules.
- Optional: REST server for `fm-test` and user annotations; DuckDB rules per CLAUDE.md §2
  (plain command; session pin → literal bundle path). Never read `rest-api/db/`.
- **Model and budget.** Run this skill on a strong reasoning model (Claude Fable tier): the
  interpretation sections (business context, findings, recommendations) gain noticeably;
  smaller models produce thinner, more generic findings. Measured on a large corpus (≈ 60
  files, ≈ 38 k graph nodes, 800+ segments, swept partition already in place): **≈ 23 min
  wall-clock, 18 API calls, ≈ 0.3 M fresh tokens** (output ≈ 110 k of which the report text
  ≈ 50 k; new context ≈ 200 k), ≈ 2.9 M tokens processed including cache reads. The duration
  is bound by output generation (≈ 100–120 tokens/s ⇒ ≈ 100 k output ≈ 15 min), not by the
  tools (sweep, engine, tests, `ClusterEdges` scans: seconds) — it only shrinks with a shorter
  report, never with less input. A preceding `fm-graph-cluster` run adds ≈ 5–6 min and its own
  tokens; run inline it also inflates every later call (that is why R0 delegates it). Small
  solutions finish in a few minutes. Every run records its own numbers (B.7).
- **Context budget.** The cost driver is not the tool output but the cache reads: every API
  call re-reads the whole context, so anything read early and never needed again is paid
  ~20×. Rules that follow from this: (1) keep the naming run (`fm-graph-cluster`) out of this
  session's context — delegate it (R0); (2) compact DuckDB output (`-markdown`, never box
  tables, never `.mode line`), read each result **once**, never re-print it; (3) scan by
  content, not by count — scaffolding segments (access rights, menu overrides) are skipped by
  default; (4) trimmed signal lists, deduplicated anchor scripts, capped step text; (5) filter
  tooling noise and cap findings before they enter the context — the counters carry the
  statement. What must **not** be cut: profile, duplication, hubs, coupling, the domain
  segments, the test counters — every finding comes from them.

## Parameters

| Parameter | Default | Effect |
|---|---|---|
| `--out=<name\|path>` | `output/deep_research_<solution>_<ts>.md` | bare name → `output/<name>.md`; path with a directory → as given. Existing file → ask, or `--force` |
| `--template=<path>` | `references/report-template.md` | custom template (grammar: `references/template-guide.md`) |
| `--top=<N>` | 15 | segments described in Appendix A (rest only listed in Appendix B) |
| `--max-communities=<N>` | 60 | cap of the member scan, largest first, `Member_Count ≥ --name-threshold` — **logged** |
| `--name-threshold=<N>` | 3 | as in `fm-graph-cluster` |
| `--members=<K>` | 12 | anchors per segment (top-K by logical degree) |
| `--include-formulaic` | off | also scan/list scaffolding segments (access rights, menu overrides); default skips them |
| `--max-steps=<N>` | 25 | step-text cap per anchor script |
| `--write` / `--no-write` | `--write` | write `Semantic_Description` (scanned segments) and `Semantic_Name` (only where NULL) back to `CommunityNames`, then sync once. User names in the sidecar are never touched |
| `--tests` / `--no-tests` | `--tests` | Analysis Tests in solution scope for §5 (`references/tests.md`) |
| `--auto-cluster` | off | at L0/L1 run `fm-graph-cluster` without asking |
| `--no-cluster-check` | off | never ask; log the level and continue with what exists (batch use) |
| `--no-sync` | off | skip the rest-api sync after write-back |
| `--lang=<code>` | prompt language | report language; FileMaker identifiers stay original |

## Workflow (R0–R6)

```
R0 Readiness ─▶ [L0/L1: ask → /fm-graph-cluster → R0 again] ─▶ R1 Solution profile
─▶ R2 Segment scan (bounded) ─▶ R3 Findings ─▶ R4 Render ─▶ R5 Write-back + sync ─▶ R6 Chat
```

### R0. Readiness gate

```bash
R0=$(date -u +%FT%TZ); echo "mark R0=$R0"               # run start — repeat at every phase boundary (R1…R6) for B.7
bash .claude/skills/_shared/scripts/cluster_state.sh     # JSON: level L0|L1|L2, flags, partition, sweep, last_run
```

State solution + source. Then, by `level`:

| Level | Meaning | Action |
|---|---|---|
| **L0** | no partition | `AskUserQuestion`: "Run `fm-graph-cluster` now (recommended) / abort". Without a partition there is no report. |
| **L1** | raw partition: `no_sweep`, `resolution_mismatch`, `engine_mismatch` or `no_run_summary` | `AskUserQuestion`: "Run sweep + naming via `fm-graph-cluster` first (recommended — strongly when `k_out_of_band`) / continue with the existing partition". With `in_band=true` and only `no_sweep`, offer "continue" as the first option. |
| **L2** | swept partition | continue. |

`--auto-cluster` answers "run"; `--no-cluster-check` answers "continue" and records the level.
On "run": **delegate** the `fm-graph-cluster` run to a sub-agent (Agent tool, general-purpose;
prompt: "Run the fm-graph-cluster skill for solution <id> with its defaults; reply with the
chat summary only") — its hints, vocabulary and protocol must not enter this session's context,
where every later call would re-read them. Keep only the sub-agent's summary line, re-run
`cluster_state.sh`, continue. Recommended even better: the user runs `/fm-graph-cluster` in a
separate session before starting this skill. Never call `cluster.sh` directly from here (it
would re-partition at the wrong granularity), never run the naming inline. Note `unnamed` and `partition_older_than_import` as protocol facts,
not gates. Keep `engine`, `resolution`, `modularity_q`, `n_nodes`, `n_edges`, `k`, `named`,
`user_named` for the header.

### R1. Solution profile (read-only, bounded)

```bash
duckdb db/fm_catalog.duckdb -readonly -markdown -c "SET VARIABLE engine='<engine>';" \
  -c ".read .claude/skills/fm-deep-research/scripts/solution_profile.sql"      # 11 result sets
duckdb db/fm_catalog.duckdb -readonly -markdown -c ".read .claude/skills/fm-deep-research/scripts/duplication.sql"
duckdb db/fm_catalog.duckdb -readonly -markdown -c "SET VARIABLE engine='<engine>'; SET VARIABLE \"limit\"=20;" \
  -c ".read .claude/skills/fm-graph-cluster/scripts/hubs.sql"
sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' version.json | head -n1                  # {{fmlab_version}}
```

Profile sets: #1 files/versions/DDR · #2 object counts · #3 data core + totals · #4 external
sources · #5 security (privilege sets, full-access/hidden scripts) · #6 plugins · #7 folders
(intended structure) · #8 triggers per file · #9 cross-cutting nodes (`ClusterGodNodes`) ·
#10 partition shape · #11 folder↔community alignment. Duplication: same name in several files
= per-file copies (node key `(uuid, file)`), never a shared hub — quantify, do not merge.

### R2. Segment scan (bounded, sequential)

```bash
duckdb db/fm_catalog.duckdb -readonly -markdown \
  -c "SET VARIABLE engine='<engine>'; SET VARIABLE k=<members>; SET VARIABLE min_members=<threshold>; SET VARIABLE max_communities=<N>;" \
  -c ".read .claude/skills/_shared/scripts/community_members.sql"                 # anchors by logical degree — read ONCE
duckdb db/fm_catalog.duckdb -readonly -markdown \
  -c "SET VARIABLE engine='<engine>'; SET VARIABLE min_members=<threshold>; SET VARIABLE max_communities=<N>;" \
  -c ".read .claude/skills/fm-deep-research/scripts/community_signals.sql"        # prior names, histogram, folder, trimmed lists, comments
```

Both queries skip scaffolding segments (dominant type access rights / menu overrides) unless
`--include-formulaic` (`SET VARIABLE include_formulaic=true`); on a large corpus that turns
60 scanned segments into ~35 without losing a single finding. Log **selected / skipped by
type / skipped by cap**. Step text: for the anchor scripts of the **top 10** segments, ≤ 2
scripts each, **each script name once** across all segments (the same utility recurs per file
— read one copy), `SET VARIABLE file='<File>'; SET VARIABLE script='<Script>'; SET VARIABLE max_steps=<N>;`
+ `.read .claude/skills/fm-deep-research/scripts/script_steps.sql`. **User annotations**
(strongest prior, best-effort, only rows that carry a name):
`duckdb solutions/<id>/db/fm_annotations.duckdb -readonly -markdown -c "SELECT Community, User_Name, left(User_Notes,120) AS notes FROM CommunityAnnotation WHERE Engine='<engine>' AND User_Name IS NOT NULL"`;
if the sidecar is locked by the server, fetch `GET http://localhost:3003/api/graph/communities`
**through a filter** (python one-liner printing only `community, user_name, user_notes` where
`user_name` is set — never dump the full list into the context); if neither works, log "user
annotations unavailable". Result per segment: `{Community, Name, Description (1–2 sentences),
Domain, Anchors[]}` — name priority when writing prose: `User_Name` > existing `Semantic_Name`
> your own; stay consistent with the existing vocabulary. Hedge everything inferred
(`_shared/response-language.md`). Sub-agents for the scan only on explicit request.

### R3. Findings

- **Measured** — run the default tests of `references/tests.md` through the `fm-test` skill in
  solution scope (max 12 tests; per member the **counters** plus at most **5** findings,
  severity-sorted; drop findings that belong to tooling add-ons such as scripts named after
  an IDE plugin before they enter the context; say what was cut).
  Metrics: #9 god-nodes, #10 shape (singletons, largest share, Q), #11 alignment, duplication,
  hubs. Skip with `--no-tests` (protocol says so).
- **Interpreted** — from R2: patterns/anti-patterns, comprehensibility, coupling, security
  smells, platform footprint (`reference/fm_spec.duckdb` `step_compat` for anchor steps when the
  platform matters — never from memory).
- Number `F-01 …` (importance first), each with `Evidence:` and `Impact:`; recommendations
  `R-01 …` each citing ≥ 1 F-id with horizon and theme. No recommendation without a finding.

### R4. Render

Appendix B data: `scripts/segment_inventory.sql` (`SET VARIABLE engine`, `-markdown`) — B.6
lists **only** semantic/user-named, non-formulaic segments row by row; scaffolding segments
(rule-named or not) and the heuristic long tail are one aggregate per layer and dominant type
plus a totals line (never hundreds of rows; the complete list lives in `/cluster`).
Read `references/template-guide.md`, then the template (`--template` or the default). Validate
the mandatory markers (`summary`, `segments`) — missing → stop and name it. Render headings in
the report language, fill `{{placeholders}}` (unknown ones stay and are listed in Appendix B),
remove instruction comments, generate the `toc` from the rendered H2/H3, write the file with the
Write tool. Existing target → `AskUserQuestion` (overwrite / new name) unless `--force`.

### R5. Write-back + sync (default on)

One bundled `duckdb` call of generated `UPDATE`s (quotes doubled `'` → `''`):
`Semantic_Description` for every scanned segment; `Semantic_Name` only `WHERE Semantic_Name IS NULL`.
Then `bash .claude/skills/_shared/scripts/cluster_run_named.sh` and, unless `--no-sync`,
`bash tools/graph-export/sync_db.sh`. `--no-write` skips all three. Skip write-back (report still
written) when `solutions/<id>/state/xml_convert.lock` is held.

### R6. Run metrics + chat summary

```bash
bash .claude/skills/fm-deep-research/scripts/session_usage.sh --since "$R0" \
  --marks "R0=$R0,R1=$R1,R2=$R2,R3=$R3,R4=$R4,R5=$R5,R6=$R6"     # DuckDB-only → paste the tables into B.7 (Edit tool)
```

The window includes user wait time at the gate — say so in B.7 when it matters; if the
transcript is unavailable write "n/a" and why. Then the chat — nothing else:

```
Deep research done — `<solution>` · <n_files> files · <K> segments (<n_deep> scanned) · Q <q>
- Purpose: <1 sentence>
- Maturity: <level> — <evidence, 1 sentence>
- Top findings: F-01 … · F-02 … · F-03 …
- Headline recommendation: R-01 …
→ Report: [output/<file>.md](output/<file>.md)
Protocol: readiness <level> · scanned <n_deep>/<K> · tests <n> run · write-back <n> descriptions, sync ✓/– · <duration> · <fresh tokens> fresh tokens
```

## Error cases

| Symptom | Cause | Reaction |
|---|---|---|
| `cluster_state.sh` exit 4 / `views_present=false` | no catalog / pre-view DB | abort → `convert-xml` / `convert-xml --batch` |
| L0 and the user declines | no partition | abort with the `fm-graph-cluster` hint |
| template lacks `summary`/`segments` | custom template | abort, name the marker |
| target file exists | re-run | ask or `--force` |
| sidecar locked / no server | annotations unavailable | continue, say so in Appendix B |
| server down and `--tests` | no API | `fm-test` direct path; if that fails, "tests not run" in Appendix B |
| `xml_convert.lock` held | import running | write report, skip write-back, say so |

## References

- `references/report-template.md` — default template (read before R4)
- `references/template-guide.md` — grammar, placeholders, section checklist, maturity scale (read before R4 and for any `--template`)
- `references/tests.md` — default test set for R3 (read at R3)
- `scripts/solution_profile.sql`, `scripts/community_signals.sql`, `scripts/script_steps.sql`, `scripts/duplication.sql`, `scripts/segment_inventory.sql` (B.6), `scripts/session_usage.sh` + `session_usage.sql` (B.7 run metrics from the session transcript, DuckDB only)
- `../_shared/scripts/cluster_state.sh`, `../_shared/scripts/community_members.sql`, `../_shared/scripts/cluster_run_named.sh`; `../fm-graph-cluster/scripts/hubs.sql`
- `../_shared/response-language.md` — hedging vocabulary per language
