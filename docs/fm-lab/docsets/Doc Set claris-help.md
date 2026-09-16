# Doc Set: claris-help

A complete offline mirror of the **Claris FileMaker Pro online help** — the authoritative vendor documentation for every native function, script step and product feature — installable in up to 11 languages and deeply integrated with the [fm-spec](../Wiki/fm-spec.md) reference index.

| | |
|---|---|
| **Status** | recommended — install on demand |
| **Original source** | [help.claris.com](https://help.claris.com) — FileMaker Pro Help (`/<lang>/pro-help/`) |
| **Copyright / license** | © Claris International Inc. — proprietary vendor documentation, mirrored as a local cache; FileMaker and Claris are trademarks of Claris |
| **Storage directory** | `docs/claris-help/<lang>/` |
| **Source format** | online help HTML, crawled recursively incl. CSS/JS/images |
| **Installed format** | raw HTML mirror per language (offline-capable), plus `manifest.json` and per-language `.version` markers |
| **Scope** | 1,074 help pages per language · 11 languages · index: 367 functions + 207 script steps |
| **Index DB** | ✓ `reference/fm_spec.duckdb` (shipped with FM-Lab — not built by the installer) |
| **Rubrics** | ✓ 19 function categories + 13 script-step categories, localized |
| **Pseudo object types** | ✓ `BuiltinFunction`, `ScriptStepType` (see [Object Types](../schema/object-catalog/Object%20Types.md)) |

## Description

The mirror is a faithful copy of the online help: each language lives in its own directory with the same page slugs as the website, so a help URL maps 1:1 to a local file:

```
https://help.claris.com/<lang>/pro-help/content/<slug>.html
↕
docs/claris-help/<lang>/content/<slug>.html
```

What makes this doc set more than a pile of HTML is the division of labour with the index: **structured facts come from the database, prose comes from the page.** Names, signatures, parameters, categories, compatibility and deep-link URLs are queried from `fm_spec.duckdb`; the mirrored HTML page is only opened for the human-readable details (descriptions, examples, related topics).

## Integration with fm-spec

The [fm-spec](../Wiki/fm-spec.md) reference index is the retrieval layer for this doc set:

- **Deep links as data.** Every function and script step carries its help-page slug (`url_slug`) and per-language URL (`functions_lang.url`, `script_steps_lang.url`) as columns — resolving an object to its documentation page is a join, not a search.
- **Locale-independent name resolution.** The lookup tables (`function_name_lookup`, `script_step_name_lookup`) map a name in *any* supported language — including localized parameter aliases — to the canonical ID. A German `MusterAnzahl` finds the same page as `PatternCount`.
- **Localized display layer.** The `*_lang` tables hold display names, signatures and descriptions per locale, so results are presented in the user's language while identity stays canonical.
- **Rubrics.** The 19 function and 13 script-step categories (with localized labels) power thematic search and the docs browser's navigation.

Because the index also feeds the object catalog's pseudo types, every documented function and step type is cross-referenced with your solution: from a help entry to every place it is used, and from a code reference back to the help page.

## Language locales

Eleven languages are supported: `en`, `de`, `es`, `fr`, `it`, `ja`, `ko`, `nl`, `pt`, `sv`, `zh` — installable individually or all at once. English is always installed as the reference and fallback language: when a page or language is missing locally, resolution falls back to `en` (recorded as `fallback_language` in `manifest.json`). Each installed language carries its own `.version` marker, so languages update independently.

Two details worth knowing: the index uses the locale code `zh-Hans` where the mirror directory is `zh`; and function texts cover 10 locales while script steps cover all 11.

## Official Markdown sources (llms.txt)

Claris now also publishes its documentation for AI consumption: [help.claris.com/llms.txt](https://help.claris.com/llms.txt) follows the llms.txt convention and points to full Markdown mirrors of every help page (`/markdown/<lang>/pro-help/…`), enumerated across all locales in [llms-full.txt](https://help.claris.com/llms-full.txt).

FM-Lab deliberately stays with the HTML mirror plus index for now. The reasons are architectural rather than a judgement on the format: retrieval in FM-Lab is **index-first** — lookups resolve through `fm_spec.duckdb` and only then open a page, so a Markdown corpus would not improve lookup quality; the web frontend embeds the mirrored HTML pages including their assets, which the Markdown mirror does not carry; and the installer's update mechanics are built around the HTML tree's slugs and version headers, which are exactly what the index links against. The Markdown source remains an attractive future ingestion path — smaller downloads and cleaner text for agents — once slug and locale parity with the index are verified.

## Installation

- **Skill** — `install-claris-docs`; prompts per language before replacing an existing set.
- **CLI** — `.claude/skills/install-claris-docs/scripts/install_claris_docs.sh` with `--lang=<code>`, `--langs=<a,b,c>` or `--all`, plus `--check`, `--force`, `--list-languages`.
- **Web frontend** — the Docs pages install and update the set via `POST /api/docs/install/claris-help` with live progress; language selection included.

## Lookup and browsing

- **Skill** — `filemaker-function-reference`: resolves a name in any language through the lookup tables, answers from the index, and opens the local HTML page for details (falling back local `en` → online → online `en`). Also supports thematic search across categories.
- **CLI** — query `reference/fm_spec.duckdb` directly with the `duckdb` CLI; open the mirrored page under `docs/claris-help/<lang>/content/`.
- **Web frontend** — the docs browser at `/docs/claris-help` (search, categories, localized entries with embedded help pages), plus the interactive [fm-spec](../Wiki/fm-spec.md) schema viewer at `/fm-spec`. Both are linked per entry in either direction, resolved by the internal step/function id and therefore independent of the display language: a help page carries an "fm-spec" chip next to its online link, and a schema-viewer page carries a "Claris Help" link in its title. Each link appears only when its target exists — the doc set is installed and the mirror holds the page; topic pages, which have no schema entry, carry none.

## See also

- [Doc Sets](Doc%20Sets.md) — the doc-set overview
- [fm-spec](../Wiki/fm-spec.md) — the reference index this doc set is built around
- [Object Types](../schema/object-catalog/Object%20Types.md) — pseudo object types in the object catalog
