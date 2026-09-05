# Skill: fm-deep-research

Writes a description of a whole solution — what it is for, how it is built, what stands out and what to do about it — from the clustered object graph and the real member objects of its largest segments. The result is a Markdown report rendered from a template; the chat shows only a short summary and the link. It is the simplest way to understand a solution you did not build: an onboarding, a takeover, a technical-debt review.

| | |
|---|---|
| **Category** | Agentic analysis |
| **Slash command** | `/fm-deep-research [--out=<name\|path>] [--template=<path>] [--top=<n>] [--max-communities=<n>] [--members=<k>] [--no-write] [--no-tests] [--auto-cluster] [--no-cluster-check] [--no-sync] [--lang=<code>]` |
| **Say it naturally** | "describe the architecture of this solution", "write a solution report", "what does this solution do as a whole" — English and German |
| **Input** | none required; a report name via `--out`, a custom template via `--template` |
| **Reads** | `db/fm_catalog.duckdb` — the partition (`ObjectClusters`, `CommunityNames`), the members of the largest communities with their anchors by logical degree, the solution profile (files, schema, security, plugins, folders, triggers), user-defined community names from the annotations sidecar, and the Analysis Tests in solution scope |
| **Writes** | the report (default `output/deep_research_<solution>_<timestamp>.md`); unless `--no-write`, `Semantic_Description` for every scanned segment and `Semantic_Name` where none existed in `CommunityNames`, then one sync to the REST API's read copy |
| **Prerequisites** | a catalog built with the graph views; a partition at the sweep granularity — the skill checks and offers to run [fm-graph-cluster](Skill%20fm-graph-cluster.md) when it is missing |
| **Under the hood** | the shared readiness script `_shared/scripts/cluster_state.sh`, the shared member query `_shared/scripts/community_members.sql`, the skill's profile/signal/duplication/step queries, [fm-test](Skill%20fm-test.md) for the measured findings, the template under `references/report-template.md` |
| **Skill directory** | `.claude/skills/fm-deep-research/` |
| **Related** | [Skill fm-graph-cluster](Skill%20fm-graph-cluster.md) (creates and names the partition) · [Skill fm-test](Skill%20fm-test.md) · [Skill fm-analyze](Skill%20fm-analyze.md) (one object instead of the whole solution) |

## Readiness first

A report is only as good as the segmentation under it. The skill therefore starts with a readiness check of the cluster layer and reacts in three levels:

| Level | Situation | What happens |
|---|---|---|
| **L0** | no partition | the skill asks whether to run [fm-graph-cluster](Skill%20fm-graph-cluster.md) now; without a partition there is no report |
| **L1** | a raw partition — never swept for a fitting resolution, or built at a different granularity than the last sweep winner | the skill asks whether to run the sweep and naming first (recommended, strongly when the module count is outside the band that fits the solution's size) or to continue with what exists |
| **L2** | a partition at the sweep granularity | the skill continues without asking |

Semantic names from an earlier `fm-graph-cluster` run are welcome but not required: the skill reads the member objects itself and derives its own names and descriptions for the segments it scans. Names the user gave to communities in the cluster overview are the strongest signal of all and are used first. `--auto-cluster` answers the question with "run"; `--no-cluster-check` answers it with "continue" and records the level in the report.

## What the skill looks at

- **The solution profile** — files and FileMaker versions, DDR-Info availability, object counts, base tables with their field counts and occurrence fan-out, external data sources, privilege sets and accounts, full-access and hidden scripts, plugin functions, the script and layout folders, script triggers per file, the cross-cutting nodes that were removed from the cluster graph, the shape of the partition, and how well the developers' folders line up with the detected communities.
- **The largest segments** — for each (by default up to 60, largest first, scaffolding segments such as per-file access-rights sets and menu overrides skipped) the anchor objects by logical cluster degree, the object-type mix, files, the dominant folder, short lists of scripts, layouts, tables, fields and variables, script comments, and for the anchor scripts of the top segments a bounded plain-text step dump — each script read once, even when it recurs per file.
- **Duplication** — scripts with the same name in several files are counted as per-file copies with their cross-file call count (usually zero), never mistaken for a shared dependency.
- **Measured findings** — the default set of Analysis Tests in solution scope (error checks, code quality, performance; twelve tests, the counters plus at most five findings per check, tooling add-on scripts filtered out), plus metrics such as modularity, singletons, largest share and folder alignment.

Every bound is explicit: how many segments were scanned and how many were skipped, which tests ran, what was cut — in the chat line and in the report's protocol appendix.

## The report

Rendered from a template with fixed sections. The default template ships with the skill; a custom one can be passed with `--template` and may drop or add sections as long as the executive summary and the segment appendix remain.

1. **Header** — date, solution, files, catalog size, segments with engine/resolution/modularity, scan coverage, fm-lab and skill versions, report language.
2. **Contents** — generated.
3. **Executive summary** — purpose, business value, technical maturity with its evidence, the most important findings, the headline recommendation. One page at most.
4. **Business context** — core entities, actors and roles, core workflows, integrations, the presumed purpose.
5. **Architecture** — the module map, file topology, granularity and decoupling, intended (folders) versus detected (communities) modularity, hubs and cross-cutting nodes.
6. **Technical description** — conventions, script patterns, UI, data, APIs and plugins, security model, platform footprint.
7. **Findings** — measured first, interpreted second; each numbered `F-nn` with evidence and impact.
8. **Recommendations** — each numbered `R-nn`, tied to at least one finding, with a horizon and a theme.
9. **Open questions and assumptions** — what the catalog cannot show.
10. **Appendix A — Segments** — the top segments with name, description, members, dominant file and type, anchors and business domain.
11. **Appendix B — Run protocol and metrics** — readiness level, engine and resolution, caps, tests, catalog caveats, hubs, the **segment inventory** (only segments that carry a user or semantic name and are not scaffolding, row by row; rule-named access-rights and menu segments and the heuristic long tail folded into one aggregate per dominant type with a totals line — the complete list stays in the cluster overview), the **run metrics** (wall-clock overall and per phase, API and tool calls, tokens: output, cache writes, cache reads, fresh content, total processed), and sources and versions.

Interpretations are hedged in the report language; FileMaker identifiers stay original. Facts from the catalog are stated plainly. Read it the way you would read a senior developer's write-up after a week with the solution: the structure is measured, the meaning is derived from names, comments and code — well-founded, and worth a human review where the naming in the solution is inconsistent or the business rules live only in operational context (see [Limitations](../Wiki/How%20it%20works.md#limitations)).

## What you see in the chat

Only the summary: the solution and its size, the purpose in one sentence, the maturity with its evidence, the top findings, the headline recommendation, the link to the report, and one protocol line with readiness level, scan coverage, tests run, write-back status, wall-clock and fresh tokens.

## Model, duration and cost

Run the skill on a strong reasoning model (the Claude Fable tier). The measured parts of the report — profile, metrics, tests — come out the same on any model; the interpretation sections (business context, findings, recommendations) gain noticeably with a strong model, and smaller models produce thinner, more generic findings.

Run the segmentation first, separately. The naming run of `fm-graph-cluster` produces hint lists, vocabulary and a protocol that a report session would otherwise carry in its context for every later call; the skill therefore delegates it to a sub-agent when the readiness check asks for it, and the cheapest path is to run `/fm-graph-cluster` in its own session before starting the report. Inside the run the skill keeps its own context small: compact query output read once, scaffolding segments skipped, trimmed signal lists, capped and filtered test findings.

Plan for a long run on a large solution. Measured on a corpus of about 60 files, 38 000 graph nodes and 800 segments with the segmentation already in place: about 23 minutes wall-clock, 18 API calls, about 0.3 million fresh tokens (output around 110 000, of which the report text is about half; new context around 200 000) and about 2.9 million tokens processed including cache reads. The time is bound by output generation — the model writes roughly 100 to 120 tokens per second, so 100 000 output tokens alone take about 15 minutes — not by the tools, which finish in seconds; a shorter report is the only lever on duration. A preceding `fm-graph-cluster` run adds five to six minutes and its own tokens. Small solutions finish in a few minutes. Every run records its own numbers in the report's metrics appendix, so the estimate improves with the solutions you actually analyse.

## How to use it

```
/fm-deep-research                                   # readiness check, scan, report, write-back, sync
/fm-deep-research --out=onboarding-erp             # report as output/onboarding-erp.md
/fm-deep-research --template=solutions/erp/templates/audit.md --no-write
/fm-deep-research --auto-cluster --top=25          # never ask; describe 25 segments in Appendix A
```

Or ask: *"describe the architecture of this solution"*, *"erstelle einen Lösungsbericht"*.

## Options

| Option | Default | Effect |
|---|---|---|
| `--out=<name\|path>` | `output/deep_research_<solution>_<timestamp>.md` | A bare name becomes `output/<name>.md`; a path with a directory is used as given. An existing file is never overwritten without asking or `--force` |
| `--template=<path>` | the shipped template | Custom report template |
| `--top=<n>` | `15` | Segments described in Appendix A; the rest appear in the community list of Appendix B |
| `--max-communities=<n>` | `60` | Cap of the member scan, largest first — logged, never silent |
| `--name-threshold=<n>` | `3` | Minimum member count for a segment to be scanned |
| `--members=<k>` | `12` | Anchor objects per segment |
| `--include-formulaic` | off | Also scan and list scaffolding segments (access rights, menu overrides) |
| `--max-steps=<n>` | `25` | Step-text cap per anchor script |
| `--no-write` | off | Do not write descriptions back to the catalog (and skip the sync) |
| `--no-tests` | off | Skip the Analysis Tests block |
| `--auto-cluster` | off | Run `fm-graph-cluster` without asking when the partition is missing or raw |
| `--no-cluster-check` | off | Never ask; continue with what exists and record the level |
| `--no-sync` | off | Skip the sync after write-back |
| `--lang=<code>` | prompt language | Report language |
