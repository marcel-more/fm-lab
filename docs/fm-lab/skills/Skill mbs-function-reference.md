# Skill: mbs-function-reference

Explains MBS FileMaker Plugin functions — by exact name or by topic — from the local MBS documentation and its SQLite search index, and answers platform-support questions from the bundled plug-in platform map.

| | |
|---|---|
| **Category** | Reference lookup |
| **Slash command** | none — triggered by the question itself |
| **Say it naturally** | "what does `MBS( "List.AddPrefix" )` do?", "explain MBS function X", "which MBS functions exist for the clipboard?" — understood in 11 languages |
| **Input** | an MBS function name (`Component.Function`), a component, or a topic |
| **Reads** | `docs/mbs/docSet.dsidx` (SQLite index), `docs/mbs/Documents/*.html`, `reference/plugin_spec.duckdb` (read-only) for platform questions |
| **Writes** | nothing |
| **Prerequisites** | the MBS documentation under `docs/mbs/` — see [Skill install-mbs-docs](Skill%20install-mbs-docs.md); `sqlite3` on the PATH |
| **Under the hood** | SQLite queries on the docset index for lookup and pattern search, the HTML page for details, DuckDB queries on `plugin_functions` / `plugin_function_platforms` for platform flags |
| **Skill directory** | `.claude/skills/mbs-function-reference/` |
| **Related** | [Skill filemaker-function-reference](Skill%20filemaker-function-reference.md) · [Skill install-mbs-docs](Skill%20install-mbs-docs.md) |

## What it does

- **Direct lookup** — the exact name is looked up in the index (thousands of functions across more than 160 components), the matching page is read, and the answer covers purpose, syntax, parameters, return value, availability (MBS version), platforms, example and notes.
- **Thematic search** — category and prefix searches in the index (`JSON.%`, `DynaPDF.%`), with synonyms widened on demand (PDF → DynaPDF, Clipboard → Pasteboard, Email → SMTP), grouped by component with the most useful functions highlighted.
- **Platform questions** — "does this run on Server / Linux / in an iOS SDK app?" are answered from [plugin-spec](../schema/plugin-spec.md), the structured per-function platform map: binary flags per axis with vendor authority, deprecation status with the documented successor, the release a function was removed in, and the minimum plugin version. Old function names resolve through the alias table. FileMaker Go supports no plug-ins at all; the `ios_sdk` axis means Claris iOS SDK apps, not Go.

The MBS documentation is English only. The skill answers in your language but never translates function names, parameter names, error codes, component prefixes or the `MBS( "…" )` call syntax — they must match the calculation text in your solution.

## How to use it

```
what does MBS("List.AddPrefix") do?
welche MBS-Funktionen gibt es für die Zwischenablage?
show me all DynaPDF functions
does MBS("Shell.Execute") run on FileMaker Server?
```

## Good to know

- MBS calls in a script are recognisable by the `MBS` (or `FM`) prefix and the dotted function name; the catalog resolves them to `PluginFunction` objects, so where-used questions about a specific MBS function are catalog queries, not documentation lookups — see [Object Types](../schema/object-catalog/Object%20Types.md).
- The component-exception table produced by the installer improves the component assignment of functions whose prefix differs from their component.
- Without the local docset the skill cannot answer; install it first. The platform map ships with FM-Lab and works independently.

## See also

- [Doc Set mbs](../docsets/Doc%20Set%20mbs.md) — the docset, its index and integration
- [plugin-spec](../schema/plugin-spec.md) — the plug-in platform map and its vocabulary
- [SCA Platform Compatibility](../sca/SCA%20Platform%20Compatibility.md) — the platform rules that use the same data
