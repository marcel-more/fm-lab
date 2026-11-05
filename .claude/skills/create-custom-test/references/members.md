# Members

A member is a **dashboard** — a bundle or a single-file dashboard — addressed by
its id:

```json
{ "kind": "dashboard", "ref": "<dashboard id>" }
```

`kind: "query"` is a read alias of older files; never write it. The optional
`paramMap` (`{ "<context param>": "<member param>" }`) renames a context param
for one member; the default is identity, so it is rarely needed.

## What makes a dashboard test-capable

| Form | Declaration | Value | Findings rows |
|---|---|---|---|
| Bundle | `manifest.json → analysis` with `defaultResult { dataset, column, type, name, meaning }`; rule bundles carry `rule.severity` | `column` of the first row of `dataset` (usually `summary.finding_count`) | dataset `findings` |
| Single-file dashboard | header `@default_result` (one-line JSON with `aggregate`), plus `@object_types`, `@output_types`, `@scope` | `row_count` = returned rows, `first_row:<column>` = that column of the first row | the result rows |

Without a declaration the member fails validation (M2) and the test cannot
run. A single-file dashboard has no severity — its result state is neutral; a
bundle rule reports `error`/`warning`/`info` from its severity.

Resolution order of `ref` (the id is unique across both forms):
`dashboards-custom/**` → `dashboards/**` → `dashboards-community/**`, then the
old location `sql-custom/` (own queries the cleanup has not moved yet). A
custom dashboard with a shipped id overrides the shipped one for every test.

## Finding candidates

**API path (server on :3003)** — the result registry lists every dashboard
with a result declaration; the dashboard list adds object types, form and
folder:

```bash
python3 - <<'EOF'
import json, urllib.request
get = lambda u: json.load(urllib.request.urlopen('http://localhost:3003' + u))['data']
TYPE, WORD = 'Script', 'error'            # adapt: object type, keyword ('' = any)
rows = {d['id']: d for d in get('/api/dashboards/dashboards/data/dashboards')}
for r in get('/api/results/registry'):
    d = rows.get(r['ref']['id'])
    if r['ref']['kind'] != 'dashboard' or not d: continue
    if TYPE and TYPE not in (d.get('object_types') or []): continue
    text = ' '.join([d['id'], d['title'], d.get('description') or '', ' '.join(d.get('tags') or [])]).lower()
    if WORD and WORD not in text: continue
    print(d['id'], '|', d['title'], '|', d['unit'], '|', d.get('folder'), '|', r.get('name'), '|', r.get('severity'))
EOF
```

Then read the declaration of each shortlisted candidate:

```bash
curl -s http://localhost:3003/api/dashboards/<id> | python3 -c "import json,sys; m=json.load(sys.stdin)['data']['manifest']; a=m.get('analysis') or {}; print(m['id'], a.get('objectTypes'), a.get('outputTypes'), (a.get('scope') or {}).get('supported'), a.get('defaultResult'))"
```

**Direct path (no server)** — bundles from their manifests, single files from
their headers:

```bash
duckdb -c "SELECT regexp_extract(filename, '([^/]+)/manifest\.json$', 1) AS id, title, analysis.objectTypes AS object_types, analysis.scope.supported AS scopes, analysis.defaultResult.name AS result FROM read_json('rest-api/templates/dashboards*/**/manifest.json', union_by_name = true, filename = true) WHERE analysis.defaultResult IS NOT NULL AND filename NOT LIKE '%/dashboards-removed/%' AND list_contains(analysis.objectTypes, 'Script') ORDER BY id"
grep -rl --include='*.sql' '^-- @default_result' rest-api/templates/dashboards rest-api/templates/dashboards-custom rest-api/templates/dashboards-community | grep -v '/data/\|/queries/'
```

(The second list: read `@title`, `@object_types`, `@scope` from each file's
header.)

The overview `/dashboard` shows the same candidates with the object-type
filter (`?type=Script`); a value in the *Findings* column marks a declared
default result.

## Scope conventions

A test runs in the scopes it declares (`scopes`); the run boundary turns them
into two SQL params:

| Scope | Params |
|---|---|
| solution | none |
| file | `file` |
| object | `scope_uuids` (one UUID) + `file` |
| object-list | `scope_uuids` (CSV) (+ `file` when all objects share one file) |
| cluster | `scope_uuids` expanded from the cluster |

A member supports object-like scopes only when its SQL carries the S-Block
next to every file filter (`scope_uuids` count = `file` count, M5/M5a) on the
declared anchor column (M5b). Members without it:

- keep the test at `solution, file`, **or**
- accept that object runs skip/ignore them — say so in the test description.

In object scope the runner skips every member whose declared object types do
not include the object's type (`skipReason: object-type`) — a mixed test (e.g.
Script + Layout members) is fine; `objectTypes` of the test lists the types it
is about, each covered by at least one member (M3).

## Consistency checklist before G2

- [ ] every candidate resolves (`GET /api/dashboards/<id>` 200) and declares a
      default result
- [ ] object types of the members cover the intended test object types
- [ ] the scopes the user wants are supported by every member (or the skip is
      accepted)
- [ ] findings members return a `message`/`_message` column (M5c, warning
      only — rows otherwise render without text)
- [ ] no two members measure the same thing (duplicate rules inflate sums)
- [ ] the members' `meaning` texts say whether they count defects or
      inventory — a test mixing both explains it in its description
