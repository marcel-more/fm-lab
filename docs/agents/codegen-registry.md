# Codegen Registry — FileMaker Artifact Types → Preferred Skills

> Referenced from CLAUDE.md §6a and `codegen-workflows.md` A3. **Axis A only** —
> this registry governs FileMaker-code generation (artifacts that run in the target
> solution). fm-lab extensions (dashboards, queries, skills) are project-owned and
> need no registry.
>
> Semantics: a row here is an **explicit project decision** and beats heuristic
> skill discovery. No row for an artifact type = discover per protocol
> (`codegen-workflows.md` A2). Users and skills may edit this file; the curated
> fm-lab collection (phase 3) will announce itself by shipping rows here.
> When the user resolves a skill ambiguity in conversation, offer to persist the
> decision as a row.

## Skill mapping

| Artifact type | Preferred skill | Level | Notes |
|---|---|---|---|
| Script (fmxmlsnippet) | `fm-generate-script` | project | Reference-driven pipeline (lint → resolve → table-driven emit → gate); canonical text notation v0.2 (T1–T9, repeat-group form); NOT in `publish-manifest.json` `include_skills` — in published setups this row dangles and falls back to discovery (A2), which is intended |
| Custom function | — | — | No skill → fallback path (A4) |
| Schema (table/field) | — | — | No skill → fallback path (A4) |
| Layout / layout objects | — | — | Deliberately no skill (generation too unreliable without live feedback) → fallback path with explicit caveat |
| Value list | — | — | No skill → fallback path (A4) |

## Target-solution conventions (artifact-internals language layer)

Consulted by every codegen path (skill or fallback) — see language policy
(`codegen-workflows.md` §L). Fill in what is known; anything left as `auto` is
derived from the catalog (existing script names, step texts, field comments) at
generation time.

| Convention | Value | Source |
|---|---|---|
| FM calc function-name locale | solution displays `de`; **generated snippet calcs use canonical EN function names** (`Get`, not `Hole`) | maintainer decision |
| Script/object naming language | `auto` | derive from ScriptCatalog naming |
| Comment language in generated scripts | `auto` | derive from existing script comments |
| MBS plugin in use | yes | PluginFunctionUsages non-empty |
| `variable_init_check` | `off` | maintainer decision — see below |
| Target FileMaker version / shape coverage | `auto` — from `FilesCatalog.FileMaker_Version` of the target file (22.x → coverage 22, 26.x → 26) | catalog; explicit `--coverage`/`--target-version` only as a named override (`codegen-workflows.md` §A5) |

`variable_init_check` is a **house convention**, not FileMaker semantics: a step
that writes into `$x` / `$$x` creates the variable by itself, so requiring a
preceding `Set Variable` is a typo net some teams want and others do not. Set it
to `on` only where the team actually follows the convention — otherwise the check
warns on perfectly correct scripts. `fm-generate-script` reads this row in P0 and
passes it on as `--check-var-init` / `FMGEN_CHECK_VAR_INIT`; left at `off` the
gate reports `G305-var-init` as *skipped*, never as passed.

## Maintenance

- One row per artifact type; keep notes to one line.
- Remove a row when its skill is uninstalled (a dangling row falls back to
  discovery with a warning, it does not fail).
- Maintenance checks should lint this file: referenced skills exist, no duplicate
  artifact types.
