# Custom Analysis Tests

This folder holds **your own** Analysis Tests. Every test you put here appears
in the test overview under **Custom**, either directly on that level or
grouped in sub-folders (up to four levels deep).

- Only this README, `folder.json` and `.gitkeep` are tracked by git. Your
  tests are ignored, so `git pull` and fm-lab updates never touch them.
- Create a test with the `/create-custom-test` skill: it proposes member
  dashboards, validates the definition and runs it once.
- A test is a directory named after its id that contains a `test.json`; the
  directory name must equal the `id` field. Members are dashboards
  (`{ "kind": "dashboard", "ref": "<id>" }`) — bundles or single-file
  dashboards with a default result. The shipped tests in `../tests/` are
  working examples.
- Group tests in sub-folders. An optional `folder.json` in a sub-folder sets
  its label (`title`, `locales`), `description` and sort `order`.
- An id that matches a shipped test overrides it; the overview marks your test
  as overriding the default.

```
tests-custom/
├── my-test/
│   └── test.json          Tests / Custom / <title>
└── team/                  Tests / Custom / Team
    ├── folder.json        optional: title, description, order, locales
    └── weekly-check/
        └── test.json      Tests / Custom / Team / <title>
```
