# Code Generation Workflows — Two Axes, Discovery, Language Policy

> Referenced from CLAUDE.md §6. Code generation in fm-lab has **two distinct axes**
> with different rules. Classify the task first, then follow the matching part:
>
> - **Axis A — FileMaker code** (§A): artifacts that run *inside the target solution* —
>   scripts, custom functions, schema (tables/fields), layouts, value lists, snippets.
>   Skill availability varies per installation → capability discovery.
> - **Axis B — fm-lab extensions** (§B): code that extends *the workbench itself* —
>   custom dashboards, analysis queries/datasets, new skills. Project-owned tooling,
>   always available → fixed, deterministic workflows.
>
> Litmus test: *Where does the output run?* In FileMaker → Axis A. In fm-lab
> (DuckDB/REST-API/frontend/Claude harness) → Axis B.

---

# Part A — FileMaker code (target solution)

## A1. Capability model — why discovery instead of fixed skill names

The FileMaker-codegen skill landscape differs per installation and evolves:

| Phase | Situation | What this prompt must do |
|---|---|---|
| **1 — none** | Fresh setup; no FM-codegen skill installed | Fall back to the minimal safety path (A4), tell the user, suggest installing/creating a skill |
| **2 — mixed** | Locally added skills and/or third-party skills the user installed — kind and coverage vary per setup | Discover what is there, select per artifact type, apply it |
| **3 — curated** | The fm-lab curated codegen collection (future release), possibly *alongside* third-party skills | Registry decides precedence; curated skills are the default, explicit user choices still win |

One generic mechanism covers all three phases — this prompt never hard-codes a
FileMaker-codegen skill name. (Axis-B skills like `create-custom-dashboard` ship
with the project and MAY be named directly.)

## A2. Discovery & selection protocol

**Step 1 — Discover.** The available-skills listing (present in every session) is the
source of truth. Candidate = any skill whose description indicates it *generates
FileMaker artifacts*: scripts / script steps, custom functions, layouts, value
lists, fields/tables, fmxmlsnippet or clipboard-XML output. Match on purpose, not
name — third-party skills follow no naming convention. The description is enough to
classify; don't read every SKILL.md up front.

**Step 2 — Select.** Precedence per artifact type:

1. **Registry entry** (`codegen-registry.md`) — an explicit project decision always wins.
2. **Project-level skill** (`.claude/skills/`) — closer to the solution's conventions.
3. **User-level skill** (`~/.claude/skills/`).
4. Still more than one candidate, or candidates conflict → **ask the user once**,
   and offer to record the answer as a registry entry so the question never repeats.

**Step 3 — Apply.** Invoke the selected skill and follow its conventions for the
artifact. Regardless of the skill's origin, the project layer stays in force:
CLAUDE.md §2 rules (master DB, plain DuckDB commands), the validation gate (A5),
and backup-before-overwrite. A third-party skill shapes the artifact — it cannot
override project safety rules.

**Step 4 — Fallback.** No candidate at all (phase 1): state that plainly, then use
the minimal safety path (A4). Never silently pretend a skill ran, and never refuse
the task just because no skill is installed.

## A3. The codegen registry (Axis A only)

`codegen-registry.md` (same directory) maps FileMaker artifact types to preferred
skills and records the target solution's artifact conventions. Plain Markdown, so
users and skills can edit it; the curated collection (phase 3) announces itself
simply by shipping registry entries. Rules:

- Missing file or missing row = no explicit decision → heuristic precedence (A2 Step 2).
- When the user resolves an ambiguity, offer to persist it here.
- Keep entries minimal: artifact type, skill name, source level, one line of notes.

## A4. Minimal safety path (fallback when no FM-codegen skill matches)

Generate the artifact directly, under these ground rules:

1. **Consult the reference skills first** — `filemaker-function-reference` for native
   functions/steps, `mbs-function-reference` for MBS calls. Never guess signatures.
2. **fmxmlsnippet basics:** one well-formed `<fmxmlsnippet type="FMObjectList">`
   snippet, paste-ready; Step-IDs from the reference index (`fm_spec.duckdb`,
   `script_steps.step_id`), never from memory; calculations in CDATA; correct
   XML entity escaping. For steps that carry **lists** (sort levels, find
   requests, import filters, …) the repetition is grounded in
   `step_repeat_groups` (container, per-item template, derived counts) —
   the `step_xml_map` main template shows a single-instance exemplar only.
   The canonical script text notation is **v0.2** (rules T1–T9 incl. the
   repeat-group form, as documented in the `fm-generate-script` skill);
   drafts written in the pre-v0.2 flat form are still accepted by
   `fm-generate-script`, canonical output uses the group form.
3. **Verify references:** every script, layout, field, TO or value list the artifact
   references must exist in `ObjectCatalog` — report anything unresolved instead of
   silently emitting it.
4. **Follow the target solution's conventions** (§L, artifact layer).
5. **Backup before overwrite** when writing into existing files.
6. **Label the result** as generated without a specialized codegen skill and point
   to the options: install one, or build one with `skill-creator`.

## A5. Validation gate (EVERY generated FileMaker artifact, any skill)

Before delivering: well-formed XML check; Step-/Function-IDs verified against the
reference index; object references verified against `ObjectCatalog`; conventions
check (§L). If a check cannot be run (e.g. reference index not installed), say so
in the delivery — never present unverified output as verified.

---

# Part B — fm-lab extensions (the workbench itself)

Project-owned workflows — no discovery, no registry; the tooling ships with fm-lab.
fm-lab code standards apply (English identifiers/comments, project skill
conventions), NOT the target solution's FileMaker conventions.

## B1. Custom dashboards

Use the **`create-custom-dashboard`** skill for new dashboard bundles. It interviews
for the content, drafts the SQL, shows sample results and generates the bundle under
`rest-api/templates/dashboards-custom/<id>/`.

Constraints for dashboard SQL (REST API layer):

- ⚠️ **`:param` preprocessor:** the API's parameter preprocessor NULLs **every** `:word`
  token in the SQL — avoid DuckDB slices (`list[1:3]`), `::`-casts written as `:type`,
  and regex patterns containing `:x`. Use `list_slice()`, `CAST(x AS type)` and
  character classes instead.
- The API DB runs in `READ_ONLY` mode with tight memory — avoid multi-evaluating
  expensive views (materialize or pre-aggregate; see `ClusterEdgesBaseMat` precedent).
- Bundle IDs must be flat-unique across all dashboard folders.
- Locale files: every bundle ships per-language locale JSONs (key parity across
  languages); localized labels come from the bundle, never hard-coded in SQL.
- Rule bundles under `static-code-analysis/` are **hand-maintained** — edit bundle
  + all locale files together.

## B2. Custom queries & analysis SQL (converter, datasets, tools)

- DuckDB syntax; verify uncertain functions/syntax via `duckdb-skills:duckdb-docs`
  instead of guessing. Reusable queries: promote into
  `rest-api/templates/sql-custom/`; the cookbook lives at
  `docs/agents/sql/sample_queries.sql` (see `query-cookbook.md`).
- Locale independence: never gate on `Step_Name`/`Step/@name` literals — use `Step_ID`
  (`ScriptStepRoleMap`, `step_metadata`).
- Pipeline placement rules: P1 is the only XML reader; no schema changes/UPDATEs on
  source tables in P2 (partitioned read-only slices); volatile derived layers
  (analysis views, universal catalogs) are rebuilt every run. Details:
  `pipeline-reference.md`.

## B3. New skills (extending the agent)

Use **`skill-creator`** plus the fm-lab skill conventions: kebab-case English names,
a description that states WHAT + WHEN in two sentences before the trigger phrases,
a lean body (< 200 lines; details into `references/`, deterministic work into
`scripts/`), reuse of shared helpers (`.claude/skills/_shared/`), and defined test
cases before building. New FileMaker-codegen skills additionally register
themselves in `codegen-registry.md` (A3).

## B4. Publishing hygiene

Publicly published artifacts (Dockerfiles, compose files, public README, skills,
templates) must not contain internal planning references, bug-report numbers or
tester/customer names. Use the **`comment-cleaner`** skill before publishing.

---

# Shared

## L. Language policy — three independent layers

Never mix these up; each has its own source of truth:

| Layer | Rule | Source |
|---|---|---|
| **Conversation & reports** | The working language: auto-detected from the user's prompts, or pinned via the `language:` setting in CLAUDE.md §2 | CLAUDE.md §2 |
| **Skill authoring** | fm-lab's own skills are written in English; third-party skills may be written in any language. A skill's body language has **zero** influence on the response or artifact language | fm-lab skill conventions |
| **Artifact internals** | **Axis A:** identifier language, FileMaker function-name locale (e.g. German calc function names), comment language *inside generated scripts* follow the **target solution's existing convention** — derive it from the catalog (existing script names, step texts, field comments) or read it from the registry's conventions block; never from the conversation language. **Axis B:** fm-lab standards — English code/comments; user-visible labels via locale JSONs | Axis A: `codegen-registry.md` / catalog inspection · Axis B: project standards |

Practical consequence: a Spanish-speaking user with an English third-party skill
working on a German-convention solution gets Spanish prose, generated FileMaker
scripts that follow the German solution conventions — and any dashboard built along
the way in English code with localized labels.

## S. General code style

- Match the surrounding code's comment density, naming and idiom.
- Comments state constraints the code can't show — not change history.
