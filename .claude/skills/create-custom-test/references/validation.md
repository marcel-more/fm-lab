# Post-write verification gate (T1–T5)

A `test.json` that fails the schema disappears silently from `/api/tests`
(`console.warn` with prefix `[tests:<id>]`). A test that loads can still be
non-runnable — the `validation` block says why. Never announce the test
without this gate.

If the REST API is **not** running on `:3003`: run T0 instead and use the
server-unavailable closing line.

## T0 — Offline check (no server)

```bash
duckdb -c "SELECT id, testType, len(members) AS members FROM read_json('rest-api/templates/tests-custom/<path>/test.json')"
```

Parses the JSON; then check by hand: directory name = `id`, `testType` /
`scopes` / `outputs` from the vocabulary, every member ref resolves
(`references/members.md` §Resolution) and declares a default result. Members
can be probed with the direct path of `.claude/skills/fm-test/references/direct-path.md`.

## T1 — Reload

Test discovery has no time-based refresh — a new test needs a reload:

```bash
curl -s -X POST http://localhost:3003/api/admin/reload >/dev/null
```

(With `ADMIN_RELOAD_TOKEN` configured, send `-H "X-Admin-Token: <token>"`.)

## T2 — The test loads

```bash
curl -s "http://localhost:3003/api/tests/<id>" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d['id'], d['area'], d['folder'], d['overrides'], d['memberCount']); print(json.dumps(d['validation'], indent=1)); [print(m['ref'], m.get('resolved'), (m.get('analysis') or {}).get('defaultResult', {}).get('name')) for m in d['members']]"
```

| Result | Action |
|---|---|
| 200, `area: custom`, folder `custom[/<folder>]` | continue |
| 404 | rejected at load — `tail -100 logs/rest-api.log \| grep -F "[tests:<id>]"` names the field (Joi) or the id/directory mismatch |
| `overrides: true` without an override decision in G1 | wrong id — rename |

## T3 — Validation block

| Rule | Level | Meaning | Fix |
|---|---|---|---|
| M1 | error | member ref does not resolve | typo, or the dashboard is invalid (`GET /api/dashboards/<ref>`) |
| M2 | error | member has no `analysis` block / no `@default_result` | other member, or add the declaration via `/create-custom-dashboard` |
| M3 | error | a `test.objectTypes` entry is declared by no member | remove the type or add a member |
| M6 | error | `defaultResult.dataset` missing in the member manifest | member bug — report, drop the member |
| M7 | error | profile references an unknown member / duplicate profile id | fix `profiles` |
| M4 | warning | `outputs` names a type no member declares | drop it from `outputs` |
| M5, M5a, M5b | warning | object-like scope declared, but a member SQL lacks the S-Block / copies out of sync / wrong anchor | narrow `scopes` or accept and say so |
| M5c | warning | findings dataset without `message`/`_message` | accept (rows without text) or improve the member |
| M8 | warning | unsupported locale language / unknown override path | fix `locales` |

**Auto-heal (one retry, then ask):** M3 → remove the uncovered type; M4 →
remove the uncovered output; M8 → drop the bad key. Re-run T1–T3 once.
Never "fix" an error by editing a member dashboard from this skill.

`validation.status: "errors"` = the test is listed but cannot run — do not
deliver it like that.

## T4 — One run

```bash
curl -s "http://localhost:3003/api/tests/<id>/run?include=findings&findingsLimit=5" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d['context'], d['summary']); [print(r['ref'], r['runStatus'], r['resultState'], (r.get('defaultResult') or {}).get('value'), r.get('error')) for r in d['results']]"
```

Expect every member `runStatus: ran`. `failed` → show the member's `error`
(SQL error, missing reference DB); `skipped` → report with its `skipReason`
(never as passed). When the test declares `object`, run once more in object
scope on one matching object:
`…/run?uuid=<Object_UUID>&file=<File_Name>` — members of other object types
come back `skipped` / `object-type`, which is correct.

## T5 — Overview

`GET /api/tests?q=<keyword>` lists the test; the overview `/tests` shows it
under **Custom / [<folder>]** (folder view) and in the list view. The status
column fills after the first solution-scope run on `/tests/<id>` or via
`/fm-test <id>`.

## Closing message template

```
Test created: rest-api/templates/tests-custom/<path>/test.json

Test ID:     <id>
Title:       <title> (English; locales: <langs | none>)
Overview:    Tests / Custom / [<folder> / …] <title>
Type:        <testType> · objects: <objectTypes> · scopes: <scopes>
Members:     <n>
  <ref> — <default result name> = <value> (<resultState>)
  …
Validation:  ok | warnings: <M-codes with one-line reason>
Verified:    GET /api/tests/<id> → 200; run → <ran>/<n> ran (solution scope)

Open /tests/<id> · run with /fm-test <id> [<object>] · object tab "Tests" for <objectTypes>
```

Server-unavailable mode → `Verified: SKIPPED (REST API not on :3003 — bash
tools/start-servers.sh, then POST /api/admin/reload)`.
