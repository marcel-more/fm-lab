# Skill: skill-creator

Guides the creation of new skills — or the revision of existing ones — from concrete usage examples to a validated, packaged skill directory: the way to add your own agentic capabilities to FM-Lab.

| | |
|---|---|
| **Category** | Extending FM-Lab |
| **Slash command** | none — ask for a new or improved skill |
| **Say it naturally** | "create a skill for X", "build a skill that…", "improve the skill X" |
| **Input** | what the skill should do, with examples of how you would ask for it |
| **Reads** | the bundled references on workflows and output patterns; existing skills as templates |
| **Writes** | a new skill directory (by default where you point it, e.g. `.claude/skills/<name>/`) and, on request, a packaged `.skill` archive |
| **Prerequisites** | Python 3 for the bundled scripts |
| **Under the hood** | `scripts/init_skill.py <name> --path <dir>` (scaffold), `scripts/quick_validate.py` (frontmatter and structure checks), `scripts/package_skill.py <dir>` (validate and zip) |
| **Skill directory** | `.claude/skills/skill-creator/` |
| **Related** | [Skill create-custom-dashboard](Skill%20create-custom-dashboard.md) · [Skill fm-generate-script](Skill%20fm-generate-script.md) |

## What it does

A skill is an onboarding guide for one kind of task: frontmatter that says *what* and *when*, a body with the workflow, and optional bundled scripts, references and assets (see [What a skill is](Skills.md#what-a-skill-is)). The skill-creator walks through the steps that make such a package effective:

1. **Understand with examples** — what would you say to trigger it, and what should happen? A few concrete requests beat a long specification.
2. **Plan the reusable parts** — which code is rewritten every time (→ a script), which knowledge is re-discovered every time (→ a reference), which files are copied every time (→ an asset).
3. **Initialise** — `init_skill.py` creates the directory with a `SKILL.md` template and example resource folders.
4. **Write** — the frontmatter description carries every trigger and "when to use" statement (it is the only part the agent sees before the skill fires); the body stays under a few hundred lines, in imperative form, with detail moved into references that are linked from the body and read only when needed. Scripts are tested by running them.
5. **Package** — `package_skill.py` validates frontmatter, naming, structure and resource references and produces a `.skill` archive for sharing.
6. **Iterate** — use it on real tasks, notice friction, refine.

Guiding principles: the context window is shared, so add only what the agent does not already know; match the degree of freedom to the task's fragility (free-text guidance for judgement calls, exact scripts for brittle sequences); no auxiliary files such as READMEs or changelogs inside a skill.

## FM-Lab specifics

- **Placement.** Project-level skills live in `.claude/skills/` and take precedence over user-level skills in `~/.claude/skills/`; both are picked up in the next session.
- **House conventions.** Skills that read the catalog follow the rules the bundled ones follow — read-only access, identity as `(UUID, File_Name)`, the bare `duckdb` invocation, the session pin, answers in the user's language with identifiers untouched. The shared building blocks under `.claude/skills/_shared/` (object resolution, response language, short mode, query templates) can be reused by reference.
- **Code-generation skills** — anything that produces FileMaker artifacts — additionally register in `docs/agents/codegen-registry.md`, so the agent selects them deliberately and applies the validation gate on top.
- **Custom dashboards** have their own generator: [create-custom-dashboard](Skill%20create-custom-dashboard.md) writes complete bundles and needs no new skill.

## How to use it

```
create a skill that exports the where-used tree of an object as CSV
improve the fm-summarize skill: add a section for script folders
```

## See also

- [Skills](Skills.md) — how skills work in FM-Lab and the bundled collection
- [Agent framework](../Wiki/Components.md#agent-framework) — system prompt and skills in the component overview
- [Doc Set agents](../docsets/Doc%20Set%20agents.md) — the agent-facing reference a new skill can point to
