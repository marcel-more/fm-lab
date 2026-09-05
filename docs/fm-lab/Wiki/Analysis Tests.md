# Analysis Tests

**Analysis Tests** are [curated, declared checks](Static%20Code%20Analysis.md) over the solution catalog. Where a [dashboard](Static%20Code%20Analysis.md#rule-dashboards) is something you *open* and a [query](Static%20Code%20Analysis.md#custom-queries) is something you *run*, a test is something the solution can *pass or fail*: a named collection of rule dashboards and custom queries with a compact result model on top — one default result per member, a derived state per run, and a consolidated verdict per test.

Tests don't introduce a new analysis engine. Every member is an ordinary dashboard bundle or query template from the dashboard system; the test layer contributes the declaration (what belongs together, for which object types, in which scopes), the execution contract and the result semantics. That makes tests reproducible and curatable: the same check runs identically from the web frontend, from the REST API and from the agent skill.

## Anatomy

A test is a `test.json` declaration: id, title, description, keywords, a `testType` (one of `exploration`, `code-quality`, `error-check`, `security`, `inventory`, `performance`, `platform`), the supported object types and scopes, and its **members** — references to dashboard bundles or query templates. Tests ship in two tiers: built-in definitions under `rest-api/templates/tests/`, user-defined ones under `rest-api/templates/tests-custom/` (a custom test with the same id overrides the built-in). Each definition is validated on load (member resolution, scope consistency, profile integrity); a test with validation errors is listed but refuses to run. A test may bundle members for different object types — the *Unfinished Work* family spans script comments, layout texts and calculation comments; in object scope only the members that declare the object's type run, the others report *skipped*.

**Scopes.** Every test declares where it can run: the whole solution, one file, a single object, an explicit object list, or a graph cluster (a named community from the graph-clustering layer). At SQL level all scopes collapse to two parameters — a file filter and a UUID list — so member SQL stays scope-agnostic.

**Profiles.** A test can ship named member subsets ("run only this aspect"). A profile can only narrow the member list, never extend it; members outside the selected profile are reported as *skipped*, keeping the result shape stable.

## The result model

Each member run produces a value (its declared default result — for example a finding count) plus a **two-axis state**: `runStatus` (ran / failed / skipped) says whether the member executed, `resultState` (error / warning / neutral / ok) judges what a successful run means. The state derives from the member's findings and severity — a rule with severity `info` can only ever reach `neutral`, which is how inventory-style members coexist with error checks without polluting any traffic light. Per test, the member states aggregate into a summary; per solution, the [results layer](../rest-api/endpoints/Results%20API.md) consolidates cached results along the folder hierarchy, summing values only within one declared unit (findings never mix with, say, script counts).

## Platform tests

The `platform` test type covers one target environment per test set and answers **two orthogonal questions**:

- **Compatibility** — *can this script run under environment X?* Every step in scope is checked against the Claris step-compatibility table ([step_compat](../schema/fm-spec-tables/step_compat.md)): steps marked *No* are errors, *Partial* are warnings (conditionally supported — never "undocumented"), missing statements are informational. Available for FileMaker Server, Go (iOS), WebDirect, Cloud, Data API, Custom Web Publishing and OData (the OData set borrows the Server base — Claris publishes no per-step OData data — and adds the derivable OData rules). The server, WebDirect, Data API and CWP sets additionally carry a **plug-in member**: functions whose vendor flags exclude them from the server-side script engine ([plugin-spec](../schema/plugin-spec.md)), and — the Server × OS cross-refinement — functions that run on the server but not on every server OS (practically: *Linux = No*), reported as warnings with the carrying OS set instead of silently passing. On FileMaker Go every plug-in call is an error: Go supports no plug-ins at all, regardless of vendor.
- **Platform binding** — *was this script built for X?* A neutral inventory (never red): scripts using iOS-exclusive steps or iOS-dedicated functions ([function_platform_affinity](../schema/fm-spec-tables/function_platform_affinity.md), including functions reached through custom functions), and scripts that demonstrably run server-side because they are Perform Script on Server targets (the `on_server` [link subrole](../schema/object-catalog/Link%20Roles%20and%20Subroles.md)). Binding evidence exists for iOS, Server and the OS sub-axis below — for the other environments no honest signal source exists, and none is invented.

The two axes explain each other: an iOS-bound script failing the Server compatibility check is not broken — it was built for another platform. In the sets for iOS and Server both aspects ship as members of one test, selectable via the profiles `compat` and `specific`.

### The OS sub-axis

The binding aspect has a second dimension: not *which runtime*, but *which operating system* a script assumes. One test set (`platform-os-binding`) consolidates three evidence sources into a single OS matrix per solution:

- **Claris script steps** ([step_os_affinity](../schema/fm-spec-tables/step_os_affinity.md)) — *Perform AppleScript* binds to macOS, *Send DDE Execute* to Windows; inverse statements like "Dial Phone is not supported in macOS" resolve against the host OS of the step's runtimes via [runtime_os_matrix](../schema/fm-spec-tables/runtime_os_matrix.md); *Send Event* is the dual-variant (one step, two OS-exclusive option sets).
- **Claris calculation functions** ([function_os_affinity](../schema/fm-spec-tables/function_os_affinity.md)) — the Core ML trio binds to macOS + iOS, the touch-keyboard and gesture functions to Windows + iOS; custom-function wrappers are followed transitively.
- **Plug-in functions** ([plugin-spec](../schema/plugin-spec.md)) — vendor OS flags folded into the shared vocabulary through the curated OS map.

All three members share one profile vocabulary (`macos-only`, `windows-only`, `desktop-only`, `apple-only`, `ios-only`, …) and stay neutral inventory (severity `info`). On the OS axis `ios` always means the *operating system* — it hosts both FileMaker Go and Claris iOS SDK apps; runtime terms never mix in. The platform-detection functions (`Get(SystemPlatform)` & co) are deliberately **not** bindings: they are the guard idiom developers use to make OS-bound scripts safe, and the reference marks them as probes.

Members degrade individually when their reference layer is missing: the plug-in member skips without the MBS docs mirror (`missing-plugin-spec`), the Claris members skip on a reference database older than fm-spec schema 1.13.0 (`missing-fm-spec-os`) — install states, never failures.

## Where tests live in the UI

- **Tests tab** on every object detail view: tests matching the object's type, grouped by category section, with run buttons, cached results (per solution, object and catalog state), member findings, profile selection, and per-solution target-environment chips for the platform section — including a step × environment compatibility matrix once several platform runs exist, and a consolidated OS × evidence-source matrix (distinct scripts bound per operating system) once the OS-binding set has run. Scripts named in an OS-binding finding additionally carry an OS badge in their detail-view header.
- **Tests overview** (`/tests`): all tests with validation state and latest solution-scope results.
- **Test detail** (`/tests/<id>`): metadata, members with links to their original dashboards/queries, and the shipped profiles.
- **Platform dashboards** complement the per-test view in the dashboard library. The two per-platform usage profiles double as test members and full dashboards: the iOS profile adds a feature breakdown (which iOS features — sensors, location, media — bind how many scripts) to its script list, the Server profile adds the caller-to-target callsite drill-down and the plug-in functions whose server support is conditional on the server OS. *Platform profile: OS bindings* profiles the OS axis — bound scripts per operating system, with counter tiles that double as filters for the OS-bound script list; the per-OS counters follow an OS-specific rule (only bindings confined to at most two operating systems mark a script as bound to an OS, so broad restrictions like "everything except Linux" stay visible without polluting the per-OS view). *Linux server readiness* answers the inverse deployment question: everything that works on macOS/Windows FileMaker Server but not on a Linux-based server — plug-in functions without a Linux build plus Claris features documented as unsupported on Linux hosts.

Agents use the same layer through the `fm-test` skill, which prefers the [REST API](../rest-api/endpoints/Tests%20API.md) and falls back to running the member SQL directly when no server is up.

**See also:** [Tests API](../rest-api/endpoints/Tests%20API.md) · [Results API](../rest-api/endpoints/Results%20API.md) · [fm-spec](fm-spec.md) · [Features](Features.md)
