# Report template — grammar, placeholders, section checklist

Read this before rendering (R4) and whenever a custom template is passed with `--template`.

## Grammar

- **Section markers** — `<!-- section:<id> -->` … `<!-- /section -->`. Known ids: `header`,
  `toc`, `summary`, `business`, `architecture`, `technical`, `findings`, `recommendations`,
  `open`, `segments`, `protocol`. **Mandatory:** `summary` and `segments` — a template without
  them is rejected (name the missing marker, stop).
- **Instruction comments** — any `<!-- … -->` inside a section tells the writer what the
  section must contain. They are **removed** from the rendered report.
- **Placeholders** — `{{name}}`, filled from the run (table below). Unknown placeholders are
  left as-is and reported in the protocol.
- **Headings** — English in the template; render them in the report language (same rule as the
  section headers of `fm-analyze`, see `_shared/response-language.md`). Numbering stays.
- **Custom templates** — unknown section ids and any text outside markers are copied verbatim
  (static text); sections missing from the template are not produced. A custom template may
  use every placeholder of the standard. Recommended location: `solutions/<id>/templates/` or
  `output/templates/`.
- **Template id** — first line `<!-- template: <name>/<version> … -->`; it is echoed in the
  header (`{{template_id}}`) and in Appendix B.

## Placeholders

| Placeholder | Source |
|---|---|
| `{{solution}}` | `cluster_state.sh` → `solution` |
| `{{date}}` | run date (ISO, local) |
| `{{n_files}}`, `{{fm_versions}}`, `{{ddr}}` | `solution_profile.sql` #1 (FilesCatalog): count, distinct versions, DDR yes/no/partial |
| `{{n_objects}}` | `solution_profile.sql` #2 total |
| `{{n_nodes}}`, `{{n_edges}}`, `{{n_communities}}`, `{{engine}}`, `{{resolution}}`, `{{modularity_q}}` | `cluster_state.sh` → `partition` / `last_run` |
| `{{n_deep}}` | communities actually scanned in R2 |
| `{{n_named}}`, `{{n_user}}` | `cluster_state.sh` → `partition.named` / `partition.user_named` |
| `{{fmlab_version}}` | `version.json` → `version` |
| `{{skill_version}}` | this skill's frontmatter `version` |
| `{{template_id}}` | template first line |
| `{{lang}}` | report language code |
| `{{top_n}}` | `--top` |
| `{{run_duration}}`, `{{fresh_tokens}}` | `session_usage.sh` (wall-clock of the run window; output + cache writes + uncached input) — used in B.7 and the chat protocol line |

## Section checklist (what the writer must not skip)

| Section | Must contain | Source | Bound |
|---|---|---|---|
| summary | purpose · value · maturity + evidence · 3–5 findings (F-ids) · headline recommendation (R-id) | all | ≤ 1 page |
| business | core entities · actors/roles · core workflows · integrations · presumed purpose (hedged) | R1 #3–#6, R2 | — |
| architecture | module map · file topology · granularity (K, sizes, singletons, largest share, Q) · folders vs. communities (alignment %) · hubs/god-nodes | R0, R1 #7–#11, R2, hubs | metrics cited |
| technical | conventions · script patterns · UI · data · APIs/plugins · security · platform footprint | R1, R2, script_steps | — |
| findings | 5.1 measured (tests + metrics) · 5.2 interpreted; each with Evidence + Impact | R3 | top 15 in body, rest in Appendix B; ≤ 5 findings per test member, tooling noise filtered |
| recommendations | R-nn → F-nn · horizon · theme | 5 | — |
| open | what the catalog cannot show · verification tasks | 2–6 | — |
| segments | per segment: name · description · members · dominant file/type · anchors · domain | R2 | `--top` |
| protocol | B.1 level/flags · B.2 caps + scanned/skipped · B.3 tests · B.4 caveats · B.5 hubs · B.6 **segment inventory** (semantic segments row by row, long tail as one aggregate per dominant type + totals line) · B.7 **run metrics** (wall-clock per phase, API/tool calls, tokens) · B.8 sources/versions | R0–R3, `segment_inventory.sql`, `session_usage.sh` | no heuristic-only rows |

## Maturity scale (qualitative, evidence-backed)

| Level | Typical evidence |
|---|---|
| foundational | few scripts/layouts per table, no error handling pattern, no folders, default privilege sets only |
| established | consistent naming and folders, error handling in most scripts, roles beyond Admin, some tests findings of medium severity |
| mature | modular segments aligned with folders, transactions/error handling systematic, security model with extended privileges, few high-severity findings, documented (comments/TODO discipline) |

Never present maturity as a number. One level, one evidence sentence.

## Finding and recommendation ids

- `F-01 …` in order of importance; measured findings before interpreted ones of equal weight.
- `R-01 …`; each line ends with `(→ F-nn[, F-mm])`, horizon and theme in brackets.
- Interpreted statements use the hedging vocabulary of the report language
  (`_shared/response-language.md`). Facts from the catalog are stated plainly.

## Segment inventory rule (B.6)

The former "complete community list" is gone: on a large corpus it ran to 800+ rows of which
80 % were two-member pairs (per-file menu items, privilege scaffolds) without any semantic
signal, and of the named rest three quarters were rule-shaped ("access rights <file>", "menu
overrides <file> · <menu>"). B.6 lists **only** segments with a user name or `Semantic_Name`
whose dominant type is **not** scaffolding, then folds everything else — rule-named scaffolding
and the heuristic long tail — into one aggregate row per layer and dominant type (segments,
members, size range, files) and one totals line (segments total, semantic segments, semantic
share of members). Nothing is dropped silently — the counts are there — but the noise never
fills pages. The complete list lives in the cluster overview (`/cluster`) and in `CommunityNames`.

## Context budget rules (apply while collecting, not while writing)

- Read every DuckDB result **once**, in `-markdown` output; never re-print a table, never
  `.mode line`, never box tables (they double the tokens for the same content).
- Scaffolding segments (access rights, menu overrides) are skipped in the scan by default —
  they never produced a finding; `--include-formulaic` brings them back.
- Anchor scripts: each script name once across all segments; step text capped (`--max-steps`).
- Tests: counters first; at most 5 findings per member; tooling add-on scripts filtered out
  before the rows enter the context.
- User annotations: only rows that carry a name; the REST fallback goes through a filter.
- The naming run (`fm-graph-cluster`) never runs inline in the report session.

## Run metrics rule (B.7)

Record `date -u +%FT%TZ` at R0 start and at every phase boundary (R1, R2, R3, R4, R5, R6).
After the report is written call
`bash .claude/skills/fm-deep-research/scripts/session_usage.sh --since <R0> --marks "R0=…,R1=…,…"`
(DuckDB reads the session transcript — no Python, no Node)
and paste its two tables into B.7. The window counts everything in the session between the
marks — including the user's answer time at the readiness gate; say so when it is significant.
Tool runtimes (sweep, engine, tests, ClusterEdges scans) are usually seconds; the wall-clock is
dominated by model generation (≈ 100–120 output tokens/s) and reading results — state which.
The measurement cannot include itself: the metrics call and the B.7 edit come after the window,
so add "≈ 2 more calls" to the totals in one sentence rather than re-measuring.
