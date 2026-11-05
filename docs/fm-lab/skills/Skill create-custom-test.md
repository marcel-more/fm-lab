# Skill: create-custom-test

Builds an own [Analysis Test](../Wiki/Analysis%20Tests.md) interactively — clarifies what the test should check, looks for an existing test first, proposes member dashboards, writes the `test.json` under `rest-api/templates/tests-custom/`, validates it through the API and runs it once before declaring success.

| | |
|---|---|
| **Category** | Extending FM-Lab |
| **Slash command** | `/create-custom-test [<topic>]` |
| **Say it naturally** | "create a test for X", "new analysis test", "bundle these checks into a test", "make a test from these dashboards" — English and German |
| **Input** | what the test should check, then your answers at three confirmation gates |
| **Reads** | the REST API (`GET /api/tests`, `/api/results/registry`, `/api/dashboards/<id>`), the test and dashboard directories for candidates and id collisions; without a server the `test.json` and manifest files directly |
| **Writes** | `rest-api/templates/tests-custom/[<folder>/…]<id>/test.json`; optionally a `folder.json` for a new folder |
| **Prerequisites** | a converted catalog; the REST API running for validation and the test run |
| **Under the hood** | three bundled references (members, `test.json`, validation); validation via `GET /api/tests/<id>` (rules M1–M8), one run via `GET /api/tests/<id>/run` |
| **Skill directory** | `.claude/skills/create-custom-test/` |
| **Related** | [Skill create-custom-dashboard](Skill%20create-custom-dashboard.md) · [Skill fm-test](Skill%20fm-test.md) |

## What it does

A test references dashboards; it contains no SQL. The skill assembles one from what the dashboard system already has — rule bundles and [single-file dashboards](../templates/Single-file%20Dashboards.md) with a declared default result — and gives it a test type, object types, scopes and outputs. It writes exclusively to your own directory `rest-api/templates/tests-custom/`; the shipped tests stay untouched, and git as well as updates leave your tests alone. When a check you need does not exist yet, the skill sends you to [create-custom-dashboard](Skill%20create-custom-dashboard.md) first (single-file form with a default result) and continues with the new dashboard.

The conversation runs through **three gates**:

| Gate | After | You confirm |
|---|---|---|
| **G1** | the search for existing tests | that a new test is needed — or you run, copy or deliberately override an existing one |
| **G2** | the member proposal | which dashboards the test contains |
| **G3** | the definition proposal | id, title, test type, object types, scopes and folder |

**Members.** Each member is written as `{ "kind": "dashboard", "ref": "<id>" }` — for bundles and single files alike. The skill lists candidates with their default result, supported scopes and severity, and warns before you confirm when a member cannot run on a single object (no scope block in its SQL) or targets another object type.

**Definition.** The skill derives the scopes from what every member supports, the object types from the members' declarations, and the outputs from their output types, so the validation rules hold from the start. Title and description are English; a `locales` block carries the translation for your language (all ten on request).

## How to use it

```
/create-custom-test
/create-custom-test error handling in scripts
/create-custom-test documentation coverage of fields and tables
```

## What you get

```
rest-api/templates/tests-custom/[<folder>/]<id>/
└── test.json     # id, title, description, testType, objectTypes, scopes, outputs, members[, profiles, locales]
```

The **verification gate** reloads the server's test list, loads the test through `GET /api/tests/<id>`, reads the validation block — errors (unresolved member, member without default result, uncovered object type, broken profile) block delivery and are fixed or asked about; warnings (outputs, scope blocks, locales) are reported — and runs the test once in solution scope, plus once on a single object when it declares object scope. The closing message names the place in the overview (`Tests / Custom / …`), the link `/tests/<id>`, every member's value from the run and how to run it again: `/fm-test <id>`, or the **Tests** tab of an object.

## Good to know

- An id of a shipped test overrides it — only when you ask for it; the overview then marks yours with *overrides standard*. Community tests are never overridden.
- The status column of the [test overview](../Wiki/Components.md#test-overview) fills after the first solution-scope run.
- Profiles (named member subsets such as `quick`) can be added to the definition; `/fm-test <id> --profile quick` runs them.
- Older `test.json` files with `"kind": "query"` keep working — the skill always writes `dashboard`.

## See also

- [Analysis Tests](../Wiki/Analysis%20Tests.md) — the test model, scopes and result semantics
- [Tests API](../rest-api/endpoints/Tests%20API.md) — listing, validation and runs
- [Single-file Dashboards](../templates/Single-file%20Dashboards.md) — the lightest member form
