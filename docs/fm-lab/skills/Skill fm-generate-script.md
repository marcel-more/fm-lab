# Skill: fm-generate-script

Generates FileMaker scripts as paste-ready `fmxmlsnippet` XML through a reference-driven pipeline: a canonical text draft, a deterministic lint, resolution of every object reference against your catalog (real IDs, not guesses), table-driven XML emission from the language reference, and a validation gate before delivery.

| | |
|---|---|
| **Category** | Code generation |
| **Slash command** | none — triggered by the request; the pipeline runs `scripts/fmgen.py` |
| **Say it naturally** | "create a FileMaker script that…", "generate a script for X", "build a script snippet" — English and German |
| **Input** | the task in plain language, the target file, and the objects the script touches |
| **Reads** | `reference/fm_spec.duckdb` (syntax, grammar, XML templates), `db/fm_catalog.duckdb` (object IDs and conventions), `docs/agents/codegen-registry.md` (conventions block) |
| **Writes** | `output/codegen/<name>/` — the snippet `.xml`, the parsed IR `.ir.json`, the resolved IR with report `.resolved.json`, the gate protocol `.gate.json`; the draft `.fmscript` |
| **Prerequisites** | Python 3; the reference database (ships with FM-Lab); a converted catalog for the target file — without it references degrade to placeholders |
| **Under the hood** | `python3 .claude/skills/fm-generate-script/scripts/fmgen.py run <draft>.fmscript --file "<TargetFile>" --out-dir output/codegen/<name>`; phases `parse`, `resolve`, `emit`, `gate`, plus `decompile` and the experimental `actionscript` target |
| **Skill directory** | `.claude/skills/fm-generate-script/` |
| **Related** | [Skill filemaker-function-reference](Skill%20filemaker-function-reference.md) · [Skill mbs-function-reference](Skill%20mbs-function-reference.md) · [Skill fm-summarize](Skill%20fm-summarize.md) |

## What it does

Snippet XML is never hand-written from memory. The XML shape of every step comes from the [fm-spec](../Wiki/fm-spec.md) emission layer ([step_xml_map](../schema/fm-spec-tables/step_xml_map.md) and its option bindings), the IDs of every layout, field, script and value list come from your catalog, and the result passes a gate before it reaches you.

```
P0 CONTEXT   conventions + target objects, verified in the catalog
P1 DRAFT     the script in canonical text form, one step per line
P2–P6        fmgen.py run: normalize → lint → resolve → emit → gate
P7 DELIVER   snippet + resolution report + gate protocol + redelivery warning
```

A failure in lint, resolve or gate goes back to the draft with the findings; the pipeline never "continues with a warning" unless you decide so.

**Context first.** Naming language and function-name locale are taken from the code-generation registry or derived from the catalog (existing script names, comments) — never from the language of the conversation. Every object the script will touch is verified in the catalog before drafting; an ambiguous target file is asked for.

**The canonical text form** is the human-readable intermediate you can review: one step per line, step names in any of the eleven locales (canonicalised by lookup), parameters in one bracket group (`Set Variable [ $x ; Value: … ]`), fields as `TO::Field`, layouts as `"Name" (TO)`, scripts as `"Name"`, comments as `# text`, disabled steps with a `//` prefix. Calculations use canonical English function names. Objects that do not exist yet are declared as `{{NEW:Field:TO::Name}}` and surface in the report as *create before paste*; the same marker inside a calculation declares a custom function that is not in the catalog yet. List-carrying steps (sort orders, find requests, import field maps) repeat a group label per item.

**Resolution** replaces names with the real IDs of the target file and produces a machine-readable report: resolved references, objects to create first, assumptions. If the catalog holds no data for the target file, placeholders are used and the delivery says so explicitly.

**The gate** checks the emitted XML step by step and reports each check by name — including warnings you have to act on: enum values documented but not round-trip verified, custom functions called with the wrong number of arguments, variables used as a step target without a prior `Set Variable` (an opt-in house convention), steps with an entry in the registry of known FileMaker bugs ([step_constraints](../schema/fm-spec-tables/step_constraints.md) — the snippet is valid, FileMaker itself may lose or skew the marked data on copy or paste), boolean attributes outside `True`/`False`, and options that were parsed but did not materialise in the emission. A skipped check is reported as skipped, never as passed.

## What you get

1. The snippet file path (and the XML inline when short).
2. The resolution report — resolved references with real IDs, new objects to create before pasting, assumptions.
3. The gate protocol summary — every failed, warned or skipped check by name.
4. The redelivery warning: pasting a snippet twice creates a second copy; snippet paste can only *add* scripts, not edit in place.
5. A verification recipe: paste, save, copy back to the clipboard and diff against the generated XML.

**Paste path.** FileMaker Pro → Scripts panel → paste. With the MBS Plugin installed, `MBS("Clipboard.SetMonitorEnabled"; 1)` converts XML on the clipboard into a FileMaker script object; without plug-ins, see the delivery notes in `references/paste-semantics.md`.

## Good to know

- **Editing existing scripts.** Before an existing artifact file is touched, a timestamped backup is written next to it. A re-pasted snippet is still a new copy of the script in FileMaker.
- **Exotic steps.** When the table-driven emitter cannot render an option, that step is authored against the reference's own example XML, spliced in, and the whole snippet runs through the gate again; the delivery says which step was hand-authored.
- **Session pin.** With `FMLAB_SOLUTION` set, the pipeline resolves against that solution's catalog (`--catalog-db solutions/<id>/db/fm_catalog.duckdb`).
- **fmIDE ActionScript** is an experimental second target (`fmgen.py actionscript`): the parsed steps are translated into fmIDE's action JSON with its own hard gate. Delivery requires a running fmIDE in the target file and is outside this skill's validation; the artifact comes with capability notes.
- **Reverse direction.** `fmgen.py decompile` turns a snippet back into the canonical text form and attaches notes to steps whose slots a clipboard round trip may already have lost.
- The bundled references cover paste semantics and silent-failure catalog, MBS usage guidelines and a full worked example.

## See also

- [Codegen API](../rest-api/endpoints/Codegen%20API.md) — lint, compile and decompile over HTTP
- [fm-spec schema](../Wiki/fm-spec.md#simplified-schema) — canonical core, language layer and emission layer of the reference
- [Agentic coding](../Wiki/How%20it%20works.md#agentic-coding) — why generation is grounded in the catalog and the reference
- [Features](../Wiki/Features.md) — AI code generation in the feature overview
