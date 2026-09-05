# plugin-spec — the plug-in platform map

Part of the [FM-Lab schema](Schema.md) · `reference/plugin_spec.duckdb`

Where [fm-spec](../Wiki/fm-spec.md) describes the native FileMaker language, **plugin-spec** describes the platform surface of plug-in functions: on which operating systems a plug-in function exists, whether it is available under the FileMaker Server script engine, its deprecation state and its historical names. The first covered vendor is the MBS FileMaker Plugin — at ~7,800 functions the largest plug-in surface in the ecosystem — but the schema is plugin-agnostic by design.

Like fm-spec, plugin-spec is **bundled with every fm-lab release**: `reference/plugin_spec.duckdb` is derived by the maintainer from the [MBS documentation mirror](../docsets/Doc%20Set%20mbs.md) — the per-function platform tables, old names and deprecation markers are parsed deterministically, so two derivations over the same mirror produce bit-identical content — and ships as a release artifact. A public installation never regenerates it: installing or updating the mirror refreshes the function documentation and the component table, while the platform map stays at its release state until the next fm-lab update; functions newer than the bundled map are reported as *unresolved* by the platform tests. The database records its own provenance in the table `reference_meta` (schema version, deriver version, mirror date). The REST API attaches it read-only under the alias `plugref`, next to fm-spec's `ref`.

## Two layers: verbatim flags, curated interpretation

The design separates what the *vendor* states from what FM-Lab *concludes*:

- **Verbatim layer** — `plugin_function_platforms` keeps the MBS documentation flags untouched: one binary value per function and vendor axis (`macos`, `windows`, `linux`, `server`, `ios_sdk`). These flags are **binary with vendor authority** — they never share the tri-state semantics of the Claris [step_compat](fm-spec-tables/step_compat.md) table (a `NULL` = Partial exists only there).
- **Interpretation layer** — small curated tables translate the vendor vocabulary into FM-Lab's platform model, each row with its provenance:
  - `plugin_runtime_map` — which runtime a flag statement applies to: *Server = No* excludes a function from every environment that executes scripts under the FileMaker Server script engine (Server schedules, WebDirect, Data API, Custom Web Publishing).
  - `plugin_generic_rules` — vendor-independent rules, currently one: **FileMaker Go supports no plug-ins at all**, so every plug-in call fails on Go regardless of any flag. This is also why the vendor's `ios_sdk` axis must never be read as a Go statement — it covers Claris iOS SDK apps only.
  - `plugin_os_map` (since plugin-spec schema 1.1.0) — folds the vendor platform axes into the OS vocabulary of the [fm-spec OS layer](fm-spec-tables/step_os_affinity.md): `macos`/`windows`/`linux` map 1:1, `ios_sdk` maps to the OS `ios` with the qualifier `sdk-only`, and `server` gets **no** OS row at all — it is a runtime statement, not an operating system. With this map, Claris and plug-in OS signals land in one shared vocabulary (`macos` | `windows` | `linux` | `ios`).

## Tables

| Table | Content |
|---|---|
| `plugins` | Registered plug-ins: id, name, detection prefix, doc-mirror version stamp |
| `plugin_functions` | One row per function: component, introduced-in version, status (`active` / `deprecated` / `removed`) |
| `plugin_function_platforms` | Verbatim per-axis support flags (`macos`, `windows`, `linux`, `server`, `ios_sdk`; binary) plus the vendor's qualifier text where one exists |
| `plugin_function_aliases` | Historical names ("old name: …") → canonical function name |
| `plugin_runtime_map` | Curated: flag predicate → affected FileMaker runtime, with effect and provenance |
| `plugin_generic_rules` | Curated vendor-independent rules (the Go rule) |
| `plugin_os_map` | Curated: vendor platform axis → OS vocabulary (`ios_sdk` → `ios`, qualifier `sdk-only`; no row for `server`) |
| `reference_meta` | Schema version, deriver version, source doc version, attribution |

## Consumers

The plug-in members of the [platform test sets](../Wiki/Analysis%20Tests.md#platform-tests): the compatibility members (functions that fail under a server-side script engine or on FileMaker Go), the **Server × OS cross-refinement** (*Server = Yes* but missing on a server OS — practically Linux — reported as conditionally server-compatible via [runtime_os_matrix](fm-spec-tables/runtime_os_matrix.md)), and the OS-binding member of the platform-os-binding set. The web frontend renders the verbatim flags as a platform badge on PluginFunction detail views and resolves old names through the alias table.

If the MBS docs mirror is not installed, the database is simply absent — the affected test members report `skipped` with reason `missing-plugin-spec` (an install state, never an error), and everything else works unchanged.

**See also:** [fm-spec](../Wiki/fm-spec.md) · [Doc Set mbs](../docsets/Doc%20Set%20mbs.md) · [step_os_affinity](fm-spec-tables/step_os_affinity.md) · [runtime_os_matrix](fm-spec-tables/runtime_os_matrix.md)
