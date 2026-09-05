<!-- template: fm-deep-research/1
     Section markers: <!-- section:<id> --> … <!-- /section -->. Mandatory sections: summary, segments.
     Headings are English placeholders — the skill renders them in the report language.
     {{placeholders}} are filled from the run; instruction comments like this one are removed
     from the rendered report. Grammar, placeholder list and per-section checklist: template-guide.md. -->
# {{solution}} — Deep Research Report

<!-- section:header -->
| | |
|---|---|
| Date | {{date}} |
| Solution | `{{solution}}` · {{n_files}} files · FileMaker {{fm_versions}} · DDR-Info {{ddr}} |
| Catalog | {{n_objects}} objects · {{n_nodes}} graph nodes · {{n_edges}} edges |
| Segments | {{n_communities}} ({{engine}}, resolution {{resolution}}, Q {{modularity_q}}) · deep-scanned {{n_deep}} · semantic names {{n_named}} · user names {{n_user}} |
| Versions | fm-lab {{fmlab_version}} · fm-deep-research {{skill_version}} · template {{template_id}} |
| Language | {{lang}} |
<!-- /section -->

<!-- section:toc -->
## Contents
<!-- Generated from the H2/H3 headings of the rendered report (numbered list with anchors). -->
<!-- /section -->

<!-- section:summary -->
## 1 Executive summary
<!-- At most one page, in this order:
     · Purpose of the solution in 1–2 sentences (hedged where inferred)
     · Business value — what it enables, for whom
     · Technical maturity — one of: foundational / established / mature — plus ONE evidence sentence
     · The 3–5 most important findings, each linked as F-nn
     · The headline recommendation, linked as R-nn -->
<!-- /section -->

<!-- section:business -->
## 2 Business context
<!-- What the solution was built for and which business goals it supports. Cover:
     · Core entities — the base tables that carry the business (names, field counts)
     · Actors and roles — accounts, privilege sets, extended privileges
     · Core workflows — the scripts and layouts that anchor the largest segments
     · Integrations — plugins, external data sources, URLs/APIs, import/export
     · Presumed purpose and users — hedging vocabulary is mandatory for everything inferred
     Sources: solution profile (R1), segment scan (R2). -->
<!-- /section -->

<!-- section:architecture -->
## 3 Architecture
<!-- Macro view — how the solution is cut. Cover:
     · Module map — the top segments and how they connect (shared objects, cross-segment calls)
     · File topology — single-file vs. multi-file, per-file duplication of utility scripts
     · Granularity and decoupling — K, size distribution, singletons, largest share, modularity Q
     · Intended vs. detected modularity — script/layout folders vs. communities (alignment)
     · Hubs and cross-cutting nodes — top logical-degree nodes, ClusterGodNodes
     Every claim cites a metric or an object. Sources: R0, R1, R2. -->
<!-- /section -->

<!-- section:technical -->
## 4 Technical description
<!-- Micro view — how things are built, as far as the catalog shows it. Cover:
     · Conventions — naming, folder structure, comment/TODO practice
     · Script patterns — parameters/results, error handling, transactions, loops, windows
     · UI — layouts per file, themes, script triggers, popovers/portals
     · Data — field types, auto-enter/validation/calculation practice, relationships, TO fan-out
     · APIs and plugins — plugin functions, Insert from URL, external data sources
     · Security model — accounts, privilege sets, extended privileges, full-access scripts
     · Platform footprint — steps with Server/WebDirect/Go constraints (fm_spec step_compat)
     Sources: R1, R2, script_steps.sql for anchor scripts. -->
<!-- /section -->

<!-- section:findings -->
## 5 Findings
<!-- Numbered F-01 …, most important first, in two sub-lists:
     5.1 Measured — Analysis Tests (solution scope) and metrics: test id, count, severity, evidence
     5.2 Interpreted — patterns/anti-patterns, comprehensibility, coupling: hedged
     Every finding carries one "Evidence:" line (object names / numbers) and one "Impact:" line. -->
<!-- /section -->

<!-- section:recommendations -->
## 6 Recommendations
<!-- Numbered R-01 …; each cites ≥ 1 finding (F-nn), names a horizon (quick win / mid-term /
     strategic) and a theme (structure, security, performance, maintainability, extension stages).
     No recommendation without a finding. -->
<!-- /section -->

<!-- section:open -->
## 7 Open questions and assumptions
<!-- What the catalog cannot answer (runtime behaviour, data volumes, business rules held outside
     the code) and what a human should verify. -->
<!-- /section -->

<!-- section:segments -->
## Appendix A — Segments (top {{top_n}})
<!-- One entry per segment, largest first. Heading = display name (user name > semantic name),
     then: description (1–2 sentences), members, dominant file/type, anchor objects (top members
     by logical degree), business domain. Segments beyond top_n appear only in Appendix B. -->
<!-- /section -->

<!-- section:protocol -->
## Appendix B — Run protocol and metrics
<!-- Sub-sections in this order:
     B.1 Readiness and partition — level and flags · engine/resolution/seed/Q · nodes/edges
     B.2 Caps and scan coverage — max_communities, members, max_steps, top, findings per test,
         formulaic skip: value and effect, selected / skipped by type / skipped by cap — never silent
     B.3 Tests — ids executed (or why not), summary counts per test (the counters carry the
         statement), ≤ 5 findings per member, tooling-add-on rows filtered — say what was cut
     B.4 Catalog caveats — DDR-Info gaps, uuid-integrity, unavailable annotations
     B.5 Hubs — top 20 by logical cluster degree
     B.6 Segment inventory — ONLY segments that carry meaning (user name or Semantic_Name)
         and are not scaffolding: community, name, members, dominant file/type, described
         yes/no. Everything else — rule-named scaffolding (access rights, menu overrides) and
         the heuristic long tail — is one aggregate table per layer and dominant type
         (segments, members, size range, files) plus one totals line (segments, semantic
         share of members). Never list those row by row; point to the cluster overview for
         the complete list. Source: segment_inventory.sql.
     B.7 Run metrics — wall-clock of the whole run and per phase (R0…R6, from the recorded
         marks), API calls, tool calls, tokens: output (thinking), cache writes, cache reads,
         uncached input, fresh content, total processed — the tables printed by
         session_usage.sh, plus one sentence on what dominated (model generation vs. tool
         time; user wait time at the gate). If the transcript is unavailable: "n/a" + why.
     B.8 Sources and versions — cluster protocol link, script versions, fm-lab/skill/template
         versions, write-back summary. -->
<!-- /section -->
