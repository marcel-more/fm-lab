# Skills

**Skills** are the agent's procedural know-how: small, self-contained instruction packages that tell Claude Code (or other Agents) *how* to carry out a recurring FM-Lab task — converting an XML export, describing a script, running a test set, opening an object in FileMaker Pro. FM-Lab ships a curated collection of them, and you can add your own.

- [What a skill is](#what-a-skill-is)
- [How an agentic session uses skills](#how-an-agentic-session-uses-skills)
- [Modular and extensible](#modular-and-extensible)
- [The bundled collection](#the-bundled-collection)
- [Shared building blocks](#shared-building-blocks)
- [Conventions every skill follows](#conventions-every-skill-follows)
- [Adding your own skills](#adding-your-own-skills)

---

## What a skill is

A skill is a directory under `.claude/skills/<name>/` with one required file, `SKILL.md`, and optional bundled resources:

```
.claude/skills/fm-show/
├── SKILL.md          # frontmatter (name, description with trigger phrases) + the workflow
├── scripts/          # deterministic helpers the agent executes (shell, Python, SQL)
└── references/       # detail material the agent reads only when a step needs it
```

The frontmatter is what the agent sees at all times: the skill's name and a description that states what it does and lists the natural-language phrases it responds to — in up to eleven languages. The body — the step-by-step workflow, ground rules, prepared queries and output format — is loaded only when the skill is triggered. Bundled scripts run without ever entering the context window. This progressive disclosure keeps the agent's context lean while still giving it deep procedural knowledge on demand.

Skills are a standard mechanism of [Claude Code](https://code.claude.com/docs/en/skills); FM-Lab uses it as the delivery format for everything agentic that goes beyond a free-form question.

## How an agentic session uses skills

An agentic session in FM-Lab rests on three layers: the system prompt (`CLAUDE.md`) sets the operating rules and points to the agent-facing reference ([Doc Set agents](../docsets/Doc%20Set%20agents.md)); the object catalog and the reference databases hold the facts; skills encode the procedures.

You trigger a skill either explicitly, as a slash command (`/fm-analyze Create Invoice`), or implicitly by phrasing the request naturally (*"what is the purpose of the script Create Invoice?"*). The agent matches the request against the skill descriptions, loads the matching skill and follows its workflow:

1. **Identify** — resolve the input (a name, a UUID, or "the script we just discussed") to exactly one catalog object. Ambiguous names produce a selection list, never a guess.
2. **Query** — run the prepared SQL or scripts against `db/fm_catalog.duckdb`, the reference databases or the REST API.
3. **Interpret** — turn the results into the skill's output format: a structured summary, a findings table, a deep link, a generated artifact.
4. **Report** — answer in your language; FileMaker identifiers, SQL and link roles stay as they are in the solution.

What a skill adds over a free-form conversation is *reproducibility*: the resolution logic, the dependency queries and the guardrails (read-only catalog access, mandatory identification, hedged interpretations, confirmation gates before files are written) are the same on every run. Free-form questions remain possible at any time — skills are the well-trodden paths, not a fence. See [Agentic Code Analytics](../Wiki/Workflow.md#agentic-code-analytics) for how this changes the way you interact with the solution metadata.

## Modular and extensible

Because each skill is one directory with a declared interface, the collection grows and changes piece by piece:

- **Retrofit** — a new agentic feature arrives as a new directory. Nothing else in the workbench needs to change for the agent to pick it up.
- **Iterate** — a skill is refined in place: a better query, an extra flag, a new guardrail. Each skill carries its own version in its frontmatter, and the workspace's version manifest (`version.json`) lists every bundled skill with its version.
- **Compose** — skills refer to one another (*"for the why, use fm-analyze"*, *"for object types fmIDE cannot address, use fm-show"*) and draw on [Shared building blocks](#shared-building-blocks), so behaviour stays consistent across the collection.
- **Layer** — the REST API, the web frontend, the CLI scripts and the skills all sit on the same catalog and templates. A skill is often the agent-facing entry to a capability that also exists as an endpoint or a dashboard: `fm-test` runs the same [Analysis Tests](../Wiki/Analysis%20Tests.md) as the Tests tab, `fm-graph-cluster` drives the same clustering tooling as the Graph Explorer's rebuild button, `convert-xml` runs the same script as the web client's import button.

## The bundled collection

FM-Lab ships the following skills with every release under `.claude/skills/`. Each links to its own page with a uniform header (invocation, input, prerequisites, what it reads and writes), usage examples and options.

### Setup & workspace

- [select-solution](Skill%20select-solution.md) — Switch the active solution of the workspace
- [install-claris-docs](Skill%20install-claris-docs.md) — Install the Claris FileMaker Pro help mirror, up to 11 languages
- [install-mbs-docs](Skill%20install-mbs-docs.md) — Install the MBS Plugin documentation
- [install-fmide-docs](Skill%20install-fmide-docs.md) — Install the fmIDE wiki
- [install-duckdb-docs](Skill%20install-duckdb-docs.md) — Install the DuckDB documentation mirror (fallback doc set)

### Ingestion

- [convert-xml](Skill%20convert-xml.md) — Convert FileMaker XML exports into the DuckDB object catalog
- [test-convert-xml](Skill%20test-convert-xml.md) — Run the conversion against the reference corpus into a separate test database
- [install-ooe-fm](Skill%20install-ooe-fm.md) — Clone the "One of Everything" reference solution — the converter's test corpus
- [install-fm-xml-export-exploder](Skill%20install-fm-xml-export-exploder.md) — Clone the XML exploder reference tool

### Reference lookup

- [filemaker-function-reference](Skill%20filemaker-function-reference.md) — Explain FileMaker functions and script steps, by name or by topic, in any supported language
- [mbs-function-reference](Skill%20mbs-function-reference.md) — Explain MBS Plugin functions, by name or by topic, including platform support

### Agentic analysis

- [fm-summarize](Skill%20fm-summarize.md) — Technical description of one object: structure, flow, dependencies
- [fm-analyze](Skill%20fm-analyze.md) — Business purpose of one object, derived from its context
- [fm-test](Skill%20fm-test.md) — Run curated Analysis Tests in solution, file, object, list or cluster scope
- [fm-graph-cluster](Skill%20fm-graph-cluster.md) — Segment the object graph into semantically named modules
- [fm-deep-research](Skill%20fm-deep-research.md) — Describe a whole solution: purpose, architecture, technical build, findings and recommendations as a report

### Navigation

- [fm-show](Skill%20fm-show.md) — Open the object in the web frontend: detail view, references or graph
- [fm-trace](Skill%20fm-trace.md) — Open the selective flow graph (trace) of a script or layout
- [fm-open](Skill%20fm-open.md) — Jump to the object in FileMaker Pro through fmIDE

### Code generation

- [fm-generate-script](Skill%20fm-generate-script.md) — Generate paste-ready FileMaker scripts through a reference-driven, validated pipeline

### Extending FM-Lab

- [create-custom-dashboard](Skill%20create-custom-dashboard.md) — Scaffold a new dashboard bundle interactively, with a verification gate
- [skill-creator](Skill%20skill-creator.md) — Build, validate and package your own skills

## Shared building blocks

`.claude/skills/_shared/` is not a skill but the library several skills draw on:

- `resolve-object.md` and `scripts/resolve_object.sql` — the object-resolution contract: input → exactly one `(Object_UUID, File_Name)` pair, selection lists on ambiguity, context detection from earlier skill outputs.
- `response-language.md` — what is rendered in your language (section headers, prose, hedging vocabulary) and what never is (FileMaker identifiers, link roles, SQL, flags).
- `short-mode.md` — the `--short` flag of the analysis skills and its natural-language trigger words in eleven languages.
- `scripts/type_queries.sql` and `scripts/call_chain.sql` — the per-type detail queries and the recursive call-chain queries behind `fm-summarize` and `fm-analyze`.
- `scripts/resolve_duckdb_bin.sh` and `scripts/open_url.sh` — DuckDB binary resolution and the single mechanism that opens a URL on the host, also from inside a container.

## Conventions every skill follows

- **The catalog stays read-only** for analysis, lookup and navigation skills. Only `convert-xml`, `fm-graph-cluster` and `fm-deep-research` (segment descriptions) write to the object catalog; the generating skills write to their own output locations; the installers write to `docs/`.
- **Identity is the pair (UUID, File_Name).** Cloned files share object UUIDs; only the file name makes an object unique. Skills ask instead of picking the first match.
- **Your language, their names.** Answers follow the language of your prompt; object names, SQL identifiers and link roles stay as they appear in the solution.
- **Solution context is honoured.** Skills follow the active solution and a session pin (`FMLAB_SOLUTION`), and deep links carry the solution id — see [Multi-solution workspaces](../rest-api/REST%20API%20Overview.md#multi-solution-workspaces).
- **Servers are optional and never started silently.** Navigation and test skills prefer the REST API or the web frontend when they run and degrade to direct DuckDB access when they do not; starting a server is your call.
- **Lookups are grounded.** Documentation questions are answered from the local doc sets and reference databases ([Doc Sets](../docsets/Doc%20Sets.md), [fm-spec](../Wiki/fm-spec.md), [plugin-spec](../schema/plugin-spec.md)), not from the model's memory.

## Adding your own skills

Skills are plain directories: anything you place under `.claude/skills/<name>/` with a valid `SKILL.md` is available in the next session. Project-level skills (`.claude/skills/`) take precedence over user-level ones (`~/.claude/skills/`). The [skill-creator](Skill%20skill-creator.md) skill scaffolds, validates and packages new skills.

Skills that generate FileMaker artifacts additionally register in the code-generation registry (`docs/agents/codegen-registry.md`), so the agent knows which skill governs which kind of artifact and which naming conventions apply. Bundled skills can be adapted as well — they are text, and the more specific they are to your solution, the better the results.

## See also

- [Agent framework](../Wiki/Components.md#agent-framework) — skills in the component overview
- [Agentic analytics](../Wiki/How%20it%20works.md#agentic-analytics) · [4 Code Analysis Approaches](../Wiki/4%20Code%20Analysis%20Approaches.md#4-agentic-analysis-and-code-generation) — the approach behind agentic analysis
- [The AI agent (Claude Code)](../Wiki/Installation.md#the-ai-agent-claude-code) — starting the agent
- [Doc Set agents](../docsets/Doc%20Set%20agents.md) — the reference material the system prompt points to
- [Analysis Tests](../Wiki/Analysis%20Tests.md) · [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the test layer behind `fm-test`
