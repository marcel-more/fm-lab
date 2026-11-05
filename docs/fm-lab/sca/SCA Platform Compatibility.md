# SCA Platform Compatibility

**Rubric:** [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) · 19 bundles · `rest-api/templates/dashboards/static-code-analysis/platform/`

The platform rubric answers deployment questions from documentation evidence instead of trial and error. It covers **two orthogonal axes** — *compatibility* ("can this run under environment X?") and *platform binding* ("was this built for X?") — plus the operating-system sub-axis ("does this assume macOS / Windows / Linux / iOS?"). Every statement traces back to curated reference data: the Claris step-compatibility table and OS-affinity curation in [fm-spec](../Wiki/fm-spec.md), and the vendor platform flags in [plugin-spec](../schema/plugin-spec.md) — never guessed from names.

## When to use it

- Before hosting scripts on FileMaker Server, exposing them via Data API/OData/WebDirect, or shipping to FileMaker Go — the compat members list every step and plug-in call that won't survive the move.
- Planning a migration to a **Linux-based** FileMaker Server: the Linux-readiness view consolidates exactly the delta that works on macOS/Windows servers but not on Linux.
- Understanding a solution's shape: the binding and OS-profile views show what the solution was *built for*, which explains compat findings instead of just counting them.

## Reading the results

The two axes must not be confused. **Compatibility** members are checks (`warning`): steps marked *No* are errors, *Partial* are warnings — and in the Claris source, an empty statement means *Partial: conditionally supported*, never "undocumented". Plug-in compat members add the vendor's binary flags, including the Server × OS refinement (functions that run on the server, but not on Linux). FileMaker Go is special: it supports no plug-ins at all, from any vendor. **Binding** members are neutral inventories (`info` or chipless) — an iOS-bound script failing the Server check is not broken; it was built for another platform. On the OS axis, `ios` always means the operating system (hosting both FileMaker Go and iOS SDK apps), never the Go runtime; and absence of an OS statement means "Claris states nothing", never "runs everywhere". These bundles double as members of the platform [Analysis Tests](../Wiki/Analysis%20Tests.md), where per-environment runs build the step × environment matrix.

## Bundles

| Bundle | Severity | What it covers | Evidence source |
|---|---|---|---|
| Platform compatibility: FileMaker Server | warning | Steps that don't run, run partially, or have no statement on Server | [step_compat](../schema/fm-spec-tables/step_compat.md) |
| Platform compatibility: FileMaker Go (iOS) | warning | Same check against the Go column | [step_compat](../schema/fm-spec-tables/step_compat.md) |
| Platform compatibility: FileMaker WebDirect | warning | Same check against the WebDirect column | [step_compat](../schema/fm-spec-tables/step_compat.md) |
| Platform compatibility: FileMaker Cloud | warning | Same check against the Cloud column | [step_compat](../schema/fm-spec-tables/step_compat.md) |
| Platform compatibility: FileMaker Data API | warning | Same check against the Data API column | [step_compat](../schema/fm-spec-tables/step_compat.md) |
| Platform compatibility: Custom Web Publishing | warning | Same check against the CWP column | [step_compat](../schema/fm-spec-tables/step_compat.md) |
| Platform compatibility: OData | warning | Server-borrowed step base (Claris publishes no per-step OData data) plus derivable OData rules | [step_compat](../schema/fm-spec-tables/step_compat.md) + catalog |
| Plug-in compatibility: FileMaker Server | warning | Functions with Server=No, plus the Server × OS refinement (runs on the server, not on Linux) | [plugin-spec](../schema/plugin-spec.md) |
| Plug-in compatibility: FileMaker WebDirect | warning | Functions excluded from the server-side script engine | [plugin-spec](../schema/plugin-spec.md) |
| Plug-in compatibility: FileMaker Data API | warning | Functions excluded from the server-side script engine | [plugin-spec](../schema/plugin-spec.md) |
| Plug-in compatibility: Custom Web Publishing | warning | Functions excluded from the server-side script engine | [plugin-spec](../schema/plugin-spec.md) |
| Plug-in compatibility: FileMaker Go (iOS) | warning | Every plug-in call — Go supports no plug-ins, regardless of vendor | generic rule |
| Platform-specific usage: FileMaker Go (iOS) | info | Scripts built for iOS: exclusive steps plus iOS-dedicated functions, CF-transitive | [step_compat](../schema/fm-spec-tables/step_compat.md) + [function_platform_affinity](../schema/fm-spec-tables/function_platform_affinity.md) |
| Platform-specific usage: FileMaker Server | info | Scripts that demonstrably run server-side: Perform Script on Server targets | catalog (`on_server` links) |
| OS binding: script steps | info | Scripts bound to an OS through steps (Perform AppleScript → macOS, Send DDE → Windows, …) | [step_os_affinity](../schema/fm-spec-tables/step_os_affinity.md) |
| OS binding: builtin functions | info | Scripts bound through functions (Core ML → macOS+iOS, touch/gesture → Windows+iOS), CF-transitive | [function_os_affinity](../schema/fm-spec-tables/function_os_affinity.md) |
| OS binding: plug-in functions | info | Scripts bound through plug-in calls missing on at least one OS | [plugin-spec](../schema/plugin-spec.md) via OS map |
| Platform profile: OS bindings | — | Consolidated OS profile over all three evidence sources, with per-OS filter tiles | all three |
| Linux server readiness | — | The inverse deployment question: everything that works on macOS/Windows FileMaker Server but not on Linux | [plugin-spec](../schema/plugin-spec.md) + fm-spec |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [Analysis Tests](../Wiki/Analysis%20Tests.md) — the platform test sets built from these bundles, and the two-axis model in detail
- [fm-spec](../Wiki/fm-spec.md) · [plugin-spec](../schema/plugin-spec.md) · [runtime_os_matrix](../schema/fm-spec-tables/runtime_os_matrix.md) — the reference data behind every statement
