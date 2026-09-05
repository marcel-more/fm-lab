# Skill: fm-test

Runs curated [Analysis Tests](../Wiki/Analysis%20Tests.md) — declared collections of static-analysis rules and custom queries with a compact pass/fail result model — in solution, file, object, object-list or graph-cluster scope, and reports results and severity-sorted findings. Also discovers matching tests without running them.

| | |
|---|---|
| **Category** | Agentic analysis |
| **Slash command** | `/fm-test <test-id> [<object> \| --file <F> \| --list <a,b,…> \| --cluster <name>] [--profile <id>]` · `/fm-test --find "<keyword>"` |
| **Say it naturally** | "run the error checks on script X", "test this script", "is something wrong with X", "which tests exist for scripts" — understood in 11 languages |
| **Input** | a test id and a scope; or a keyword / object type for discovery |
| **Reads** | the REST API (`GET /api/tests…`) when a server runs; otherwise the test declarations under `rest-api/templates/tests/` and `tests-custom/` plus `db/fm_catalog.duckdb` (read-only) |
| **Writes** | nothing |
| **Prerequisites** | a converted catalog; cluster scope needs a clustered catalog; some platform members need `reference/fm_spec.duckdb` and `reference/plugin_spec.duckdb` |
| **Under the hood** | API path: `GET /api/tests/:id/run?include=findings`; direct path: member SQL executed with `duckdb` and `SET VARIABLE` (recipe in `references/direct-path.md`) |
| **Skill directory** | `.claude/skills/fm-test/` |
| **Related** | [Skill fm-analyze](Skill%20fm-analyze.md) · [Skill fm-show](Skill%20fm-show.md) · [Skill fm-graph-cluster](Skill%20fm-graph-cluster.md) · [Skill fm-deep-research](Skill%20fm-deep-research.md) |

## What it does

A test is what you run when the question is not *show me the findings* but *is anything wrong here?* The skill resolves the requested scope, runs the test's members — each an ordinary rule dashboard or query template — and reports one default result per member, a run status (`ran` / `failed` / `skipped`) and a result state (`error` / `warning` / `neutral` / `ok`), followed by the findings. The same test yields identical results from the web client's Tests tab, from the [Tests API](../rest-api/endpoints/Tests%20API.md) and from this skill, because all three share one execution path.

**Discovery** comes first when you don't know the test id: `--find "<keyword>"` lists matching tests (id, title, type, keywords, scopes); a bare object without a test id lists the tests that apply to its type and runs one directly when the match is unambiguous; `--type error-check <object>` runs every test of one type.

## How to use it

```
/fm-test --find "window"                       # which tests deal with windows?
/fm-test script-error-checks "Create Invoice"  # one test, object scope
/fm-test script-error-checks --file Invoices   # file scope
/fm-test script-error-checks --list "A,B,C"    # explicit object list
/fm-test script-error-checks --cluster "Invoicing"   # a named graph community
/fm-test platform-server --profile compat      # one shipped profile only
/fm-test "Create Invoice"                      # no id: list applicable tests, run if unambiguous
```

Scopes collapse to two parameters at SQL level — a file filter and a UUID list — so any member runs in any declared scope. The skill checks the test's declared scopes first and proposes the nearest supported one when the request does not fit. Objects are resolved like in [fm-summarize](Skill%20fm-summarize.md): identity is `(UUID, File_Name)`, ambiguity produces a selection list.

## Profiles and platform tests

Tests may ship **profiles** — named member subsets such as `quick`, or the two aspects of the platform sets. `--profile <id>` runs that subset; members outside it are reported as *skipped*, never as passed, and an unknown profile is an error rather than a silent full run. In object scope, the members of a test that spans several object types (the *Unfinished Work* family covers scripts, layouts and calculations) run only when they declare the object's type — the others are reported as *not applicable*, never as passed.

The **platform tests** deserve a word: before running them the skill establishes the target environment in three questions (server-side execution, web/mobile clients, API backend), deriving what it can from the call chain — a *Perform Script on Server* boundary means the callee subtree runs server-side. Compatibility and platform *binding* are kept apart in the report: a script the binding aspect marks as iOS-bound explains its server-incompatible steps as "built for another platform", not as broken. Plug-in members degrade explicitly when `plugin_spec.duckdb` is missing, OS members when the reference database lacks the OS layer; a skipped member is never counted as a failure. Details of the two axes and the OS sub-axis: [Platform tests](../Wiki/Analysis%20Tests.md#platform-tests) and [SCA Platform Compatibility](../sca/SCA%20Platform%20Compatibility.md).

## What you get

1. **Result table** — one row per member: title, default result, its meaning, status. Member errors (missing metadata, SQL error) are shown by name; they never invalidate the other members.
2. **Findings** — severity-sorted (`error` → `warning` → `info`), capped per member with an explicit note when truncated: object, step number (1-based), message. Deep-link UUIDs are included only when you work with the frontend.
3. **Observations** — optional prose; several independent rules converging on the same script region is the pattern worth pointing out, marked as interpretation.
4. For list and cluster scope, an aggregate per object comes before the member detail.

Follow-ups are offered where they fit: the object's references in the browser ([fm-show](Skill%20fm-show.md)), the business interpretation ([fm-analyze](Skill%20fm-analyze.md)), or an analysis pattern from `docs/agents/analysis-patterns.md` for reconstruction questions.

## Good to know

- **API preferred, direct path as fallback.** With a running REST API the skill uses it (and sends the session's solution as `X-Solution` when pinned); without one it reads the `test.json` declarations and runs the member SQL itself. The results are the same.
- **Cluster scope** needs the cluster layer; after a forced rebuild of the catalog, re-run [fm-graph-cluster](Skill%20fm-graph-cluster.md) first.
- **Custom tests** under `rest-api/templates/tests-custom/` are discovered like the built-in ones and override a built-in test with the same id.
- Locale independence is built in: members filter on step ids and UUIDs, never on localized step names.

## See also

- [Analysis Tests](../Wiki/Analysis%20Tests.md) — anatomy, result model, scopes, where tests live in the UI
- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — rule categories and the three delivery forms
- [Tests API](../rest-api/endpoints/Tests%20API.md) · [Results API](../rest-api/endpoints/Results%20API.md) — the endpoints behind the API path
- [SCA Healthchecks](../sca/SCA%20Healthchecks.md) — the dashboard view of the same rule results
