# Analysis Tests — Reference

> Referenced from CLAUDE.md §5 (offer), `analysis-workflows.md` (skill
> selection) and the `fm-test` skill. Not to be confused with the converter
> quality tests (`tools/tests/quality/`) — those test the import pipeline;
> Analysis Tests analyse the imported FileMaker solution.

## Concept

A **Test** is a declared, executable collection of dashboards and/or custom
queries with a compact result model: one named **default result** per member
(e.g. `finding_count`), optionally enriched with the member's findings rows.
A **pattern** (`analysis-patterns.md`) is a documented procedure without
execution semantics; the `fm-test` skill is the interpreting bracket.

## Storage (two tiers, custom-first)

| Tier | Path | Write access |
|---|---|---|
| System | `rest-api/templates/tests/<folder>/<id>/test.json` | repo/release only |
| Custom | `rest-api/templates/tests-custom/<folder>/<id>/test.json` | editor API (v1.1), package install (v1.2) |

Folders without `test.json` are category folders (optional `folder.json` with
`title`/`icon`/`description`/`order`/`locales`). Custom wins on id collision
(`overridesSystem` flag in the list response).

## test.json

```json
{
  "id": "script-error-checks",
  "version": "1.0.0",
  "title": "Script Error Checks",
  "description": "…",
  "keywords": ["error", "script"],
  "testType": "error-check",
  "objectTypes": ["Script"],
  "scopes": ["solution", "file", "object", "object-list", "cluster"],
  "outputs": ["count", "findings-table"],
  "members": [
    { "kind": "dashboard", "ref": "exit_script_in_loop" },
    { "kind": "query", "ref": "script_todo_scan", "paramMap": { "file": "file" } }
  ]
}
```

Vocabularies (single source: `rest-api/src/services/tests-schemas.js`, served
in the `GET /api/tests` meta): `testType` = exploration | code-quality |
error-check | security | inventory | performance | platform · `outputs` =
count | boolean | findings-table | inventory-table | graph | text · `scopes` =
solution | file | object | object-list | cluster.

## Member metadata

- **Dashboard**: `manifest.json → analysis` block (objectTypes, outputTypes,
  `scope { supported, anchor, mode }`, `defaultResult { dataset, column, type,
  name, meaning }`). No `analysis` block = not test-capable (M2).
- **Custom query**: SQL frontmatter `@object_types:` / `@output_types:` /
  `@scope:` (comma lists) and `@default_result:` (one-line JSON with
  `aggregate: "row_count" | "first_row:<column>"`).

## Scope mechanics (S-Block)

Five logical scopes collapse to **two SQL params**: the existing `file` and
`scope_uuids` (CSV of Object_UUIDs). Normalisation happens at the run boundary
(`tests.service` / `fm-test` direct path): object → `file`+`scope_uuids`,
object-list → `scope_uuids`, cluster → expansion via `ObjectClusters`
(cap 5000). The canonical in-SQL form, placed exactly where the file filter
sits:

```sql
AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
AND (getvariable('scope_uuids') IS NULL
     OR t.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
```

Absent params collapse to TRUE — solution scope is bit-identical to the
pre-scope behavior. Full authoring rules (anchor visibility, aggregation
determinacy, the M5a/M5b textual checks):
`.claude/skills/create-custom-dashboard/references/sql-rules.md`.

## Consistency rules (checked at load, reported as `validation`)

M1 member resolves · M2 member has analysis/@default_result · M3 every
`test.objectTypes` entry is supported by at least one member (the union — a
test may span scripts, layouts and calculations; in object scope the runner
skips the members that do not declare the object's type, `skipReason:
"object-type"`) · M4 outputs covered (warning) ·
M5/M5a/M5b scope declarations vs. SQL text (warnings) · M6 defaultResult
dataset exists. Errors make a test non-runnable (still listed with
`validation.status: "errors"`); warnings only badge it.

## API

```
GET /api/tests                        ?objectType=&testType=&scope=&keyword=&q=&folder=&lang=
GET /api/tests/:id                    definition + resolved members + validation
GET /api/tests/:id/run                ?uuid=&file=&uuids=&cluster=&object_type=
                                      &include=findings&findingsLimit=20
GET /api/tests/:id/run/:memberIndex   single member
```

`object_type` is optional in object scope — the server resolves it from
`ObjectCatalog` when omitted. Members whose declared object types do not
include it come back as `runStatus: "skipped"` with `skipReason:
"object-type"` (single-member runs included); never read such a skip as a
pass.

`include=findings` adds severity-sorted (`error`→`warning`→`info`), capped
findings rows per member with value > 0 — the agentic mode: the default result
is a number, the finding is in the rows. `openTarget` per member is the ready
frontend deep link (dashboard/query with context params).

## Frontend

- Object detail tab **Tests** (`/object/:uuid?tab=tests`) — lists
  object-scoped tests for the object's type, runs on click.
- Overview `/tests` (`tests_overview` bundle + home tile) — tiles link into
  the detail view.
- Detail `/tests/:id` (`test_detail` bundle) — metadata header, the contained
  members with their resolved title/section/severity and a link to each
  member's original entry (`/dashboard/<ref>` resp. `/query/<ref>`), shipped
  profiles and the validation findings. Read-only; runs stay in the object
  tab and the skill.

## CLI / skill fallback without server

`read_json('rest-api/templates/tests*/**/test.json')` with custom-first dedupe
on `id`; member SQLs via `duckdb` + `SET VARIABLE` — recipe in
`.claude/skills/fm-test/references/direct-path.md`.
