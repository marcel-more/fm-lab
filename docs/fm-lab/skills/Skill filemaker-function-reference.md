# Skill: filemaker-function-reference

Explains native FileMaker functions and script steps — by name in any supported language, or by topic — from the shipped reference index and the local Claris help mirror, with an online fallback.

| | |
|---|---|
| **Category** | Reference lookup |
| **Slash command** | none — triggered by the question itself |
| **Say it naturally** | "what does `PatternCount` do?", "explain the script step *Set Variable*", "which FileMaker functions exist for JSON?" — understood in 11 languages |
| **Input** | a function or script-step name (any locale, e.g. `MusterAnzahl` or `PatternCount`), or a topic |
| **Reads** | `reference/fm_spec.duckdb` (read-only), `docs/claris-help/<lang>/content/<slug>.html`, and `help.claris.com` as fallback |
| **Writes** | nothing |
| **Prerequisites** | none for the index; the local mirror ([Skill install-claris-docs](Skill%20install-claris-docs.md)) for offline detail pages |
| **Under the hood** | DuckDB queries on the lookup tables `function_name_lookup` / `script_step_name_lookup` and the `*_lang` tables; the mirrored page only for prose |
| **Skill directory** | `.claude/skills/filemaker-function-reference/` |
| **Related** | [Skill mbs-function-reference](Skill%20mbs-function-reference.md) · [Skill install-claris-docs](Skill%20install-claris-docs.md) |

## What it does

The skill is index-first: a name in any of the eleven supported languages — including localized parameter aliases — resolves through the lookup tables to the canonical function or step, then signature, parameters, purpose, return type, origin version and the deep-link slug are read from the [fm-spec](../Wiki/fm-spec.md) database in your language. Only when you ask for more (further examples, related topics) is the mirrored help page opened, in this order: local page in the target language → local English page → online page → online English page. If the target language is not installed locally, the skill says so once and suggests `install-claris-docs --lang=<code>`.

Two modes:

- **Direct lookup** — one function or step: purpose, syntax, parameters, return value, availability, example, notes and the source page.
- **Thematic search** — a topic ("text", "JSON", "records", "container"): matching categories from the 19 function and 13 script-step rubrics, a grouped overview of matching functions and steps (searched across canonical and localized names, aliases, purpose and description), the most commonly used ones, and the offer to open any of them in detail.

The lookup is used implicitly, too: when the analysis skills encounter a function inside a script, this is how they check what it does.

## How to use it

```
what does Substitute do?
erkläre mir die Funktion MusterAnzahl
which script steps exist for records?
show all JSON functions
```

Answers follow the language of your question; function and step names stay canonical. The response can also explain the function in the context of the script under discussion — how it is used there, likely pitfalls, best practice.

## Good to know

- Function texts exist in ten locales, script steps in eleven (Simplified Chinese is available for steps only); English is always present as the canonical name.
- Native functions never use dot notation — a dotted name (`List.AddPrefix`) is an MBS function and belongs to [mbs-function-reference](Skill%20mbs-function-reference.md).
- Platform questions ("does this step run on FileMaker Server?") are answered from the compatibility tables of [fm-spec](../Wiki/fm-spec.md), not from the help prose; note that the vendor's table is tri-state and a `NULL` there means *partially supported* — see [step_compat](../schema/fm-spec-tables/step_compat.md).

## See also

- [Doc Set claris-help](../docsets/Doc%20Set%20claris-help.md) — the mirror and its integration with the index
- [fm-spec](../Wiki/fm-spec.md) — the reference index, its language layer and coverage
- [Reference Database API](../rest-api/endpoints/Reference%20Database%20API.md) — the same lookups over HTTP
