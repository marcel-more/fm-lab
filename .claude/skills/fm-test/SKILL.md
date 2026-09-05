---
name: fm-test
version: 0.1.0
description: Runs Analysis Tests (curated, declared collections of SCA rule dashboards and custom queries with a compact result model) against the DuckDB catalog `db/fm_catalog.duckdb` — in solution, file, object, object-list or cluster scope — and reports the default results plus severity-sorted findings. Also discovers matching tests without running them (`--find`). Prefers the REST API (`GET /api/tests/:id/run`), falls back to a direct duckdb path when no server runs. Triggers (English) - "/fm-test", "run the error checks on script X", "test this script", "is something wrong with X", "which tests exist for scripts". Triggers (German) - "/fm-test", "führe die Error-Checks auf Script X aus", "teste dieses Script", "stimmt mit X etwas nicht", "welche Tests gibt es für Scripts". Triggers (Spanish) - "ejecuta las pruebas en el script X", "¿qué pruebas existen para scripts?". Triggers (French) - "exécute les tests sur le script X", "quels tests existent pour les scripts ?". Triggers (Italian) - "esegui i test sullo script X", "quali test esistono per gli script?". Triggers (Dutch) - "voer de tests uit op script X", "welke tests bestaan er voor scripts?". Triggers (Portuguese) - "execute os testes no script X", "quais testes existem para scripts?". Triggers (Swedish) - "kör testerna på skript X", "vilka tester finns för skript?". Triggers (Japanese) - "スクリプトXのテストを実行して", "スクリプト用のテストは何がありますか". Triggers (Korean) - "스크립트 X 테스트 실행해 줘", "스크립트용 테스트는 무엇이 있나요". Triggers (Chinese) - "对脚本 X 运行测试", "有哪些针对脚本的测试".
---

# Analysis Tests Runner

Run one or more **Analysis Tests** — declared collections of dashboards /
custom queries with a per-member default result — in a chosen scope and report
findings. Tests deliver reproducible, curated checks; interpretation of the
findings stays with you (offer `fm-analyze` for the "why").

## Invocation forms

```
/fm-test <test-id>                          # solution scope
/fm-test <test-id> <object name|UUID>       # object scope (resolution like fm-summarize)
/fm-test <test-id> --file <FileName>        # file scope
/fm-test <test-id> --list <obj1,obj2,…>     # object-list scope
/fm-test <test-id> --cluster <name|id>      # cluster scope
/fm-test --type error-check <object>        # all tests of one testType for an object
/fm-test <test-id> --profile <profile-id>   # run only this shipped profile's member subset
/fm-test --find "<keyword>"                 # discovery only — list matching tests, run nothing
/fm-test <object>                           # no test id: list matching tests, run when unambiguous
```

## Ground rules

- **Database**: read-only against the master catalog `db/fm_catalog.duckdb` via a plain `duckdb db/fm_catalog.duckdb -c "<SQL>"` (Bash). With an active session pin (`FMLAB_SOLUTION`/`FMLAB_CONTEXT`, CLAUDE.md §2) use the literal bundle path `duckdb solutions/<id>/db/fm_catalog.duckdb` instead (resolve once via `tools/solution.sh current`). Never read the `rest-api/db` copies directly; never install DuckDB.
- **Read-only**: never UPDATE/INSERT/DELETE.
- **Locale independence**: filter on `Step_ID`/UUIDs, never on localized names.
- **Step numbers are 1-based in prose**: render `Step_Index + 1`.
- **Response language**: follows the user's prompt language — identifiers, SQL and rule ids stay English. Policy: [`_shared/response-language.md`](../_shared/response-language.md).
- This skill is an **analysis** skill — it does NOT register in the codegen registry.

## Execution strategy

1. **API path (preferred).** If the REST server responds
   (`curl -s http://localhost:3003/api/version`), use it — identical semantics
   to the frontend, one code path:
   - Discovery: `GET /api/tests?q=…&objectType=…&testType=…&scope=…`
   - Detail: `GET /api/tests/:id`
   - Run: `GET /api/tests/:id/run?include=findings&findingsLimit=20` plus the
     scope params (see below). Multi-solution setups: send `X-Solution: <id>`
     when a session pin targets a non-default solution.
   - Profiles: tests may ship named member subsets (`profiles` in the list/
     detail response, e.g. `quick`). `--profile <id>` maps to `&profile=<id>`;
     members outside the profile come back as `runStatus: skipped` — report
     them as skipped, not as passed. Unknown profile ids are a 400, not a
     silent full run.
   - Object scope: members whose declared object types do not include the
     target's type come back as `runStatus: skipped` / `skipReason:
     object-type` — a test may span several types (`unfinished-work`: scripts,
     layouts, calculations). Report them as "not applicable", never as passed.
     `object_type` is optional; the server resolves it from the catalog.
   - Result model: each member carries `runStatus` (ran|failed|skipped) and
     `resultState` (error|warning|neutral|ok); the response's `summary` block
     aggregates them — use it for the report header instead of re-counting.
2. **Direct path (fallback, no server).** Read the `test.json`, resolve member
   SQLs and execute them with `duckdb` + `SET VARIABLE` statements — exact
   recipe in [`references/direct-path.md`](references/direct-path.md).

## Scope resolution (before running)

| User input | Normalised params |
|---|---|
| nothing | solution scope — no params |
| file name | `file=<name>` |
| object name/UUID | resolve via `ObjectCatalog` (like fm-summarize; on ambiguity ask, identity is **(UUID, File_Name)**) → `uuid=<uuid>&file=<file>` (+ optional `object_type=<Type>`; the server resolves it when omitted) |
| object list | resolve each → `uuids=<csv>` (+ `file` only if all from one file) |
| cluster name/id | API path: `cluster=<ref>` (server expands). Direct path: expand via `ObjectClusters`/`CommunityNames` (see references), cap 5000 UUIDs |

Check the test's declared `scopes` first (`GET /api/tests/:id` or the
`test.json`) — offer the nearest supported scope when the requested one is not
declared. Cluster scope needs a clustered catalog (after
`convert-xml --force-rebuild` re-run `fm-graph-cluster`).

### Platform context tests (`platform-*`)

Before running platform test sets, establish the target environment — ask in
**three groups**, not seven questions:

1. "Does this also run server-side (FileMaker Server / Cloud)?" — *derivable*:
   a `Perform Script on Server` boundary (Step_ID 164/210) in the call chain
   means the callee subtree runs server-side; state the derivation and confirm.
2. "Are there web/mobile clients (WebDirect / Go)?"
3. "Is the solution used as an API backend (Data API / CWP / OData)?"

Without an answer run only the local (client) context plus a derived server
context. `step_compat` semantics: `false` = No, **NULL = Partial (conditionally
supported — deep-link the step's help page), never "undocumented"**; a missing
row is the genuine no-statement case (CLAUDE.md §7).

**Aspect profiles (`compat` / `specific`):** `platform-ios` and
`platform-server` carry two members for two orthogonal aspects — a)
*compatibility* ("can this run under X?", findings are obstacles: error/
warning/info) and b) *platform binding* ("was this built for X?", a **neutral
inventory**: severity `info`, unit `scripts`, never a defect). No profile =
both aspects; `--profile compat` / `--profile specific` runs one alone. The
other five environments have no binding signal source (documented asymmetry) —
their sets stay single-member for the Claris axes. In the report, keep the two aspects apart and
draw the cross-connection where it explains findings: a script the binding
aspect marks iOS-bound *explains* its exclusive-step errors under
`platform-server --profile compat` as "built for another platform", not
broken. Binding findings for Server mean "is called via Perform Script on
Server", not "uses server features" — repeat that derivation in the report.

**Plug-in evidence (members `platform_compat_plugins_<env>`):** the
go/server/webdirect/dataapi/cwp sets carry a plug-in compatibility member
under the `compat` profile — MBS functions with `Server=No` fail under the
server-side script engine; FileMaker Go supports no plug-ins at all (every
vendor; the MBS `ios_sdk` axis means Claris iOS SDK apps, **not** Go). The
server member additionally carries the **Server × OS cross-refinement**
(v7): `Server=Yes` functions missing on a server OS (practically Linux)
surface as `warning` with `finding_kind='os_conditional'` and the carrying
OS set in `os_condition` — "runs on the server, but not on Linux FMS".

**OS sub-axis (set `platform-os-binding`, three members):**
`platform_os_steps` (Claris steps: Perform AppleScript → macOS, Send DDE
Execute → Windows, inverse "not supported in macOS" statements, Send Event
dual-variant), `platform_os_functions` (Core ML trio → macOS+iOS, touch
functions → Windows+iOS, incl. CF-transitive wrappers) and
`platform_specific_os` (plug-in functions via `plugin_os_map`). Shared
`os_profile` vocabulary (macos-only, windows-only, linux-only, ios-only,
desktop-only, apple-only, desktop-variant, mixed); severity `info`, unit
`scripts`; `ios` always means the OPERATING SYSTEM (Go and iOS SDK apps).
Degrades per member: the plug-in member needs
`reference/plugin_spec.duckdb` (skip reason `missing-plugin-spec` →
suggest `install-mbs-docs`); the Claris members need fm_spec ≥ 1.13.0
(skip reason `missing-fm-spec-os` → suggest
`tools/fm-reference/pull-reference.sh`). Never treat a skip as a failure.
Find keywords: "MBS", "plugin", "macOS-gebunden"/"OS binding",
"AppleScript", "DDE", "Windows-only", "Linux-Server"/"Linux FMS",
"Core ML".

**Plug-in maintenance (set `script-plugin-maintenance`, three members):**
the maintenance axis of plug-in usage, strictly separate from the platform
axis — `plugin_deprecated_call` (warning; the documented successor per row
in `replacement`, unresolved functions surface here as info),
`plugin_removed_call` (error; the call fails with any current plugin,
`removed_in` carries the removal release) and `plugin_version` (neutral
inventory; defaultResult is **text** — the minimum plugin version the scope
requires, derived as max `since_version` over the functions in use; pass
`installed_version` (major.minor) to turn it into a check — the catalog
knows no installed plugin version, never assume one). Profiles: `checks`
(R1+R2) / `inventory` (R3). All members need `reference/plugin_spec.duckdb`
(skip reason `missing-plugin-spec` → suggest `install-mbs-docs`). Find
keywords: "deprecated", "removed", "veraltet", "Plugin-Version",
"maintenance"/"Wartung", "Mindestversion".

## Discovery (`--find`, `--type`, bare object)

- API path: `GET /api/tests?q=<keyword>` / `?testType=…&objectType=…`.
- Direct path: `read_json` scan over both tiers with custom-first dedupe —
  query in [`references/direct-path.md`](references/direct-path.md).
- Report matches as a short table (id, title, testType, keywords, scopes) and
  run nothing. With a bare object and exactly one matching test, run it
  directly; with several, list and let the user pick.
- Binding questions map to the platform sets, not to a separate test:
  "platform-specific", "plattformspezifisch", "built/gebaut für iOS/Server",
  "iOS-Anteil", "server batch layer" → `platform-ios` / `platform-server`
  with `--profile specific`.

## Report format

Per test:

1. **Result table** — one row per member: member (title or ref), default
   result value, meaning, status (`ok`/`error` — errors are shown, never
   swallowed).
2. **Findings** — below the table, severity-sorted (`error` → `warning` →
   `info`), capped (default 20/member, say when truncated): script, step
   number (1-based), message. Include `step_uuid`/`nav_uuid` only when the
   user works with the frontend/fm-show (deep links), not as noise.
3. **Observations (optional prose)** — convergence is signal: several
   independent rules pointing at the same script/step region is exactly the
   pattern that sorts an investigation. Mark interpretations as such.
4. For `--list`/cluster scope: aggregate per object (which objects have
   findings at all) before the member detail.
5. Members with `status: error` (missing metadata, SQL error): name the member
   and the error — a member error never invalidates the other results.

Offer follow-ups where they fit: `fm-show <object> --references` (deep link),
`fm-analyze <object>` (business interpretation), or the matching pattern from
`docs/agents/analysis-patterns.md` for reconstruction questions.
