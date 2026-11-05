# test.json

Schema: `rest-api/src/services/tests-schemas.js` (`testDefinitionSchema`) —
derive fields from there when in doubt. Vocabularies are served in
`GET /api/tests` → `meta.vocabularies`; never hard-code a value the server
does not list.

## Location

```
rest-api/templates/tests-custom/
├── <id>/test.json                    Tests / Custom / <title>
└── <folder>/                         Tests / Custom / <folder label>
    ├── folder.json                   optional: title, icon, description, order, locales
    └── <id>/test.json
```

- The directory name equals `id`; a mismatch is rejected at load
  (`[tests:<id>] test.json id="…" differs from directory name`).
- Folders up to four levels; without `folder.json` the label is the
  humanized folder name.
- A custom test with the id of a shipped test **overrides** it (badge
  "overrides default"); a community test never does.

## Fields

| Field | Required | Value |
|---|---|---|
| `id` | yes | `[a-zA-Z0-9_-]+`; this skill: lowercase with dashes (`script-error-handling`) |
| `version` | no | `"1.0.0"`; raise it on every later change |
| `title` | yes | English, ≤ 60 characters |
| `description` | no | one paragraph: what is checked, what a finding means, what the members are |
| `keywords` | no | lowercase search terms (`GET /api/tests?q=` and `keyword=` read them) |
| `testType` | yes | `exploration` · `code-quality` · `error-check` · `security` · `inventory` · `performance` · `platform` |
| `objectTypes` | no | `ObjectCatalog.Object_Type` values the test is about; each covered by a member (M3); drives the object tab **Tests** and the overview filter |
| `scopes` | no | `solution` · `file` · `object` · `object-list` · `cluster` (default `solution, file`) |
| `outputs` | no | `count` · `boolean` · `findings-table` · `inventory-table` · `graph` · `text`; each declared by a member (M4, warning) |
| `members` | yes | ≥ 1 × `{ "kind": "dashboard", "ref": "<id>" [, "paramMap": {…}] }` |
| `profiles` | no | named member subsets, see below |
| `locales` | no | inline translations, see below |

Unknown top-level fields are kept but ignored.

## Profiles

```json
"profiles": [
  { "id": "quick", "title": "Quick check", "description": "Only the defect rules.", "members": ["error_code_unknown_literal", "error_code_web_only"] },
  { "id": "full", "title": "Full check" }
]
```

A profile narrows the member list, never extends it (M7: unknown ref or
duplicate profile id = error). A profile without `members` means "all".
`/fm-test <id> --profile quick` and `GET /api/tests/<id>/run?profile=quick`
run it.

## Locales

```json
"locales": {
  "de": { "title": "Fehlerbehandlung in Scripts", "description": "…", "profiles.quick.title": "Schnellprüfung" }
}
```

One entry per language (`de`, `es`, `fr`, `it`, `nl`, `pt`, `sv`, `ja`, `ko`,
`zh-Hans`), each a flat map of override path → text. Valid paths: `title`,
`description`, `profiles.<profileId>.title`, `profiles.<profileId>.description`.
An empty string keeps the English original. Anything else is reported as M8
(warning) and ignored.

## Minimal example

```json
{
  "id": "script-error-handling",
  "version": "1.0.0",
  "title": "Script error handling",
  "description": "Checks how scripts compare Get(LastError): unknown and web-only error-code literals as defects, plus the neutral inventory of every comparison.",
  "keywords": ["error", "lasterror", "error-codes", "script"],
  "testType": "error-check",
  "objectTypes": ["Script"],
  "scopes": ["solution", "file", "object", "object-list", "cluster"],
  "outputs": ["count", "findings-table", "inventory-table"],
  "members": [
    { "kind": "dashboard", "ref": "error_code_unknown_literal" },
    { "kind": "dashboard", "ref": "error_code_web_only" },
    { "kind": "dashboard", "ref": "error_code_inventory" }
  ]
}
```

Full shipped examples: `rest-api/templates/tests/script/script-todos/test.json`
(profiles + 10 locales), `rest-api/templates/tests/layout/layout-hygiene/test.json`
(bundle and single-file members).
