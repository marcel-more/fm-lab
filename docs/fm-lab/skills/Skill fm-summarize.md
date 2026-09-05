# Skill: fm-summarize

Produces a structured, technical description of one FileMaker object — what it is, what it contains, its step-by-step flow, what it uses and what uses it — straight from the object catalog.

| | |
|---|---|
| **Category** | Agentic analysis |
| **Slash command** | `/fm-summarize <object> [--short]` |
| **Say it naturally** | "describe the script X", "summarize the field X", "explain the layout X technically", "describe X briefly" — understood in 11 languages |
| **Input** | an object name, a UUID, or the object under discussion in the conversation |
| **Reads** | `db/fm_catalog.duckdb` (read-only) |
| **Writes** | nothing — the summary is printed in the chat |
| **Prerequisites** | a converted catalog ([Skill convert-xml](Skill%20convert-xml.md)) |
| **Under the hood** | the shared object-resolution contract, the per-type query templates in `_shared/scripts/type_queries.sql`, and the dependency queries on [ObjectLinks](../schema/object-catalog/ObjectLinks.md) |
| **Skill directory** | `.claude/skills/fm-summarize/` |
| **Related** | [Skill fm-analyze](Skill%20fm-analyze.md) · [Skill fm-test](Skill%20fm-test.md) · [Skill fm-show](Skill%20fm-show.md) |

## What it does

The summary answers *what does this object do, technically?* for any catalog object: scripts, fields, layouts, custom functions, value lists, base tables, table occurrences, relationships, calculation instances and every other type, with a generic fallback for the rest.

The run always starts with **identification**: the input is resolved to exactly one `(UUID, File_Name)` pair. Several matches — a common script name in several files, a UUID shared by cloned files — produce a numbered selection list, and the skill waits for your pick rather than guessing. A type hint in the request ("the *layout* Customers") narrows the search.

Then the type-specific data is collected and rendered:

- **Scripts** — the numbered flow is the centrepiece. Step numbers are the ones you see in FileMaker's Script Workspace (1-based); disabled steps are marked; when the export carries DDR-Info, the human-readable step text with resolved field names and parameters is used ([DDR_ScriptSteps](../schema/catalog-tables/DDR_ScriptSteps.md)).
- **Fields** — type, data type, comment, storage, auto-enter and validation details, calculation text, and every place the field is displayed, set or used as a lookup or relationship key.
- **Layouts** — parts, an aggregated object inventory (never hundreds of objects listed individually), triggers and referenced objects.
- **Custom functions, value lists, tables, occurrences, relationships, calculations** — their defining data plus callers and users.

Dependencies are reported in both directions from the operational links of the catalog — *Uses* grouped by link role (`calls_script`, `sets_field`, `navigates_to_layout`, …) and *Used by* likewise — with cross-file links called out explicitly. See [Link Roles and Subroles](../schema/object-catalog/Link%20Roles%20and%20Subroles.md) for what each role means.

## How to use it

```
/fm-summarize "Create Invoice"
/fm-summarize Customers::Email
/fm-summarize 8075DF6B-… --file Customers        # clone-safe: UUID plus file
/fm-summarize "Create Invoice" --short
describe the last of those fields                # from the conversation context
```

## Standard vs. short mode

| Section | Standard | `--short` |
|---|---|---|
| Header (name, type, file, UUID) | ✓ | inline in prose |
| Purpose | ✓ | ✓ — the core of the output |
| Technical details | ✓ | — |
| Flow (scripts) | numbered, complete | at most a half-sentence |
| Uses / Used by | grouped by link role | at most a count |
| Notes | ✓ | only critical ones |

Short mode is one or two paragraphs of prose without headers, lists, tables or code, activated by `--short` or by words such as *briefly*, *kurz*, *TL;DR* in any of eleven languages. It runs only the header query and two counts, which makes it cheap to use as a first look.

## Good to know

- **Response language** follows your prompt; object names, link roles and SQL stay original.
- **DDR-Info matters.** Without it the flow falls back to step names and raw calculation text; the summary says so. Check the `Has_DDR_INFO` flag in [FilesCatalog](../schema/object-catalog/FilesCatalog.md) if a summary looks thin.
- **Facts, not guesses.** The Purpose section is derived from the stored comment where one exists; otherwise the skill says that it was inferred from behaviour. Everything else is reported from the catalog.
- **Downstream skills read the header.** The `UUID` and `File` lines of a summary are the context token the navigation skills pick up — "show this in FM-Lab" right after a summary needs no further arguments.
- For *is something wrong with this object?* the skill points you to [fm-test](Skill%20fm-test.md) instead of guessing.

## See also

- [Skill fm-analyze](Skill%20fm-analyze.md) — the business-purpose counterpart
- [ObjectCatalog](../schema/object-catalog/ObjectCatalog.md) · [ObjectLinks](../schema/object-catalog/ObjectLinks.md) — the tables the summary is built from
- [Objects API](../rest-api/endpoints/Objects%20API.md) · [References API](../rest-api/endpoints/References%20API.md) — the same data over HTTP
- [Agentic analysis and code generation](../Wiki/4%20Code%20Analysis%20Approaches.md#4-agentic-analysis-and-code-generation)
