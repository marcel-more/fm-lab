# Post-write validation gate

The bundle loader fails **silently** on schema violations (Joi rejects →
`console.warn` → bundle disappears from `/api/dashboards`). Never announce the
dashboard as available without running this gate. Bundles, SQL templates and
locale files are hot-reloaded by mtime — no server restart needed; a new
bundle or file appears within two seconds.

Bundle form: V1–V6 below. Single-file form: §Single-file gate (F1–F5) at the
end, then the matching closing message.

## V1 — Trigger the cache reload

```bash
curl -s -X POST http://localhost:3003/api/admin/reload >/dev/null
```

If the REST API is **not** running on `:3003`: skip V2–V5, jump to the closing
message with a clearly-labelled warning ("start with `bash tools/start-servers.sh`,
then reload the browser"). Do not try to verify without the server.

## V2 — Verify the bundle loads

```bash
HTTP=$(curl -s -o /tmp/fmlab_dashboard_check.json -w "%{http_code}" \
       http://localhost:3003/api/dashboards/<id>)
echo "HTTP $HTTP"
```

| Result | Action |
|---|---|
| 200 with `"success":true` and `data.manifest.id == "<id>"` | continue |
| 404 `TEMPLATE_NOT_FOUND` | bundle rejected at load — V3 |
| 5xx / curl error | server problem, unrelated to the bundle — show it, don't auto-fix |

## V3 — Read the real cause from the log

```bash
tail -100 logs/rest-api.log | grep -F "[dashboard:<id>]" | tail -5
```

The Joi message names the offending field. Also grep once for locale warnings —
they don't fail the load but mean broken translations:

```bash
tail -200 logs/rest-api.log | grep -F "[dashboard-i18n]" | tail -5
```

(`unresolved override key` = typo in a locale key or missing node `id`.)

## V4 — Auto-heal the top-3 root causes (one retry)

Patch on disk, re-run V1+V2 **once**. If it fails again, stop and surface the log
line — don't loop.

| Log contains | Fix |
|---|---|
| `params[N].type must be one of [string, number, boolean]` | rewrite `integer`/`int`/`float` → `number`, `bool` → `boolean` |
| `manifest.id="X" differs from directory name` | set `id` to the directory basename (never rename the directory) |
| `datasets[N].source … fails to match the required pattern` | prepend `bundle:` if the value looks like a path; otherwise ask the user |

Anything else (layout schema, dataset-name mismatch, JSON parse error): do NOT
auto-fix — show the log line and ask.

## V5 — Probe each dataset (DuckDB CLI)

If the DuckDB binary is reachable (resolution per CLAUDE.md §2 /
`docs/agents/tooling.md`; honour a session pin's literal bundle path).
`<path>` is the bundle's location inside `dashboards-custom/` — `<id>`, or
`<folder>/…/<id>` when it is grouped:

**a) Default run** — unset variables are `NULL` in the CLI, matching the API's
behaviour for absent params, so the plain query must already work:

```bash
duckdb -readonly db/fm_catalog.duckdb -csv -c \
  "$(cat rest-api/templates/dashboards-custom/<path>/data/<file>.sql)" | head -5
```

**b) Param run — once per declared filter param.** The API replaces
`getvariable('p')` textually; the CLI equivalent is `SET VARIABLE`:

```bash
duckdb -readonly db/fm_catalog.duckdb -csv -c \
  "SET VARIABLE <param> = '<example value>';
   $(cat rest-api/templates/dashboards-custom/<path>/data/<file>.sql)" | head -5
```

Use a value that exists (e.g. a `File_Name` from `FilesCatalog`, a subset value
the KPI strip sends). Expect: no error, and for filter params a row count ≤ the
default run. A DuckDB error here means the SQL is broken even though the manifest
validates — report it, do not silently ship.

Probe the **value shapes**, not just happy-path strings (sql-rules.md §3):
- KPI reset value: `SET VARIABLE <param> = '';` — must behave like the default run;
- every `datasets[].params` numeric default **as a number**:
  `SET VARIABLE limit = 100;` (no quotes — the API injects JSON numbers unquoted,
  which is exactly what a string-only probe fails to catch).

If DuckDB is not reachable, skip silently — the runtime will surface SQL errors
when the user opens the dashboard.

**b2) API-side probe (when the server is up — preferred, it exercises the real
preprocessor):**

```bash
curl -s "http://localhost:3003/api/dashboards/<id>/data?<param>=<value>" \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['data']['datasets']; \
      [print(k, len(v.get('data',[])), v.get('error')) for k,v in d.items()]"
```

Any non-`None` `error` fails the gate. Repeat for the default URL (no params) and
one URL per filter param.

**c) KPI/detail consistency (P2/P3 bundles):** compare the summary count of one
subset with the detail row count under the same param value. Mismatch = the
shared-CTE rule was violated (sql-rules.md §5) — fix before delivering.

## V6 — Interactivity self-check

Before the closing message, verify against the generated `layout.json`:

- [ ] I1: every object-row primitive has `openObject` with `uuid` + `file`
      (+ `type` where mixed)
- [ ] I2: every partition shown as numbers is clickable (or consciously waived)
- [ ] I3: every List/Table/TileGrid has `searchable: "auto"` +
      `searchAutoThreshold: 3` (or is a documented Top-N exception)
- [ ] every node has an `id`; locale files use ID-form keys
- [ ] no `:word` sequence anywhere in the SQL files
      (`grep -nE ':[A-Za-z0-9_]' data/*.sql` — hits need the split-literal fix)
- [ ] every statement that joins tables qualifies every column with its alias,
      no `SELECT *` / `t.*` over a join (sql-rules.md §1) — a bare column breaks
      once a later schema version adds the same name to a joined table
- [ ] if the manifest declares `analysis.scope.supported` with `object`/
      `object-list`/`cluster`: every native dataset carries the S-Block, the
      count of `getvariable('scope_uuids')` equals the count of
      `getvariable('file')` per file (M5a), and the S-Block anchor column
      matches `analysis.scope.anchor` (M5b) — see `sql-rules.md` §3.

Each conscious waiver gets a one-line justification in the closing message.

## Closing message template

```
Dashboard bundle created: rest-api/templates/dashboards-custom/<path>/
  ├── manifest.json
  ├── layout.json
  ├── data/<dataset>.sql (…)
  └── locales/ (de, es, fr, it, nl, pt, sv, ja, ko, zh-Hans)

Dashboard ID:   <id>
Title:          <title> (English default; 10 translations)
Overview:       Dashboards / Custom / [<folder> / …] <title>
Pattern:        <P# name(s)>
Datasets:       <name> (preview: N rows), …
Filter params:  <param>=<values>  → try /dashboard/<id>?<param>=<value>
Verified:       GET /api/dashboards/<id> → HTTP 200; dataset probes OK (default + params)
Interactivity:  I1 ✓ / I2 ✓ / I3 ✓ (waivers: <none | reason>)

Live at /dashboard/<id> — browser reload (Ctrl+R) picks it up.
```

Server-unavailable mode → replace `Verified:` with
`SKIPPED (REST API not on :3003 — bash tools/start-servers.sh, then reload)`.
Auto-heal applied → add one line, e.g.
`Auto-heal: manifest.params[].type "integer" → "number" (re-verified OK)`.

---

## Single-file gate (F1–F5)

`<path>` is the file's location inside `dashboards-custom/` — `<id>.sql`, or
`<folder>/…/<id>.sql` when it is grouped.

### F1 — Header self-check (before and after writing)

- [ ] `@template_type: report`, `@title`, `@description` present; no
      `@category`
- [ ] every `getvariable('<p>')` of the SQL is named in `@params`
      (`grep -o "getvariable('[a-z_]*')" <file> | sort -u`)
- [ ] `@object_types` names the object type the click opens; `@click_args`
      carries `uuid`, `type`, `file` (I1)
- [ ] `@default_result` is valid one-line JSON (`aggregate`, `type`, `name`,
      `meaning`) when the dashboard should show a findings value or serve as a
      test member; then the SQL also returns `_message`
- [ ] `@scope` lists object-like scopes only when the SQL carries the S-Block
      (one `scope_uuids` per `file` filter)
- [ ] paging keys (`@page_param`, `@search_param`, `@sort_param`,
      `@page_size`) only together with the paging frame; `/*@sort*/` present
- [ ] no `:word` sequence in the SQL body
      (`grep -nE ':[A-Za-z0-9_]' <file> | grep -v '^[0-9]*:-- @'` — header
      lines are parsed from the raw file and are exempt)

### F2 — The dashboard loads

```bash
curl -s http://localhost:3003/api/dashboards/<id> | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; m=d['manifest']; print(m['id'], m['title'], [x['source'] for x in m['datasets']], m.get('analysis',{}).get('defaultResult'), d['nav']['crumbs'])"
```

Expect the id, the title, the sources `builtin:query_meta` and
`custom:<id>`, the `defaultResult` when declared, and the crumbs
`Custom / [<folder> / …]`. A 404 means the file was discarded: read the
reason from the log (`tail -100 logs/rest-api.log | grep -F "[dashboard:<id>]"`)
— id collides with an internal template, invalid file name, or the derived
manifest failed validation. A `ignoring invalid @default_result` /
`ignoring unknown @scope value(s)` warning means the dashboard loads without
that declaration: fix the header, re-run F2.

If the REST API is **not** running on `:3003`: skip F2/F3, run F4 and use the
server-unavailable closing line.

### F3 — Data through the API

```bash
curl -s "http://localhost:3003/api/query?template=<id>&format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success'), len(d.get('data') or []), (d.get('error') or {}).get('message'))"
curl -s "http://localhost:3003/api/dashboards/<id>/data" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']['datasets']; [print(k, len(v.get('data',[])), v.get('error')) for k,v in d.items()]"
```

Repeat the second call once per filter param (`?<param>=<value>`, the chip
param, `?q=<term>` for a paged file). Any error fails the gate.

### F4 — Direct DuckDB run (always; the only check without a server)

```bash
duckdb -readonly -csv db/fm_catalog.duckdb -c ".read rest-api/templates/dashboards-custom/<path>" | head -5
duckdb -readonly -csv db/fm_catalog.duckdb -cmd "SET VARIABLE file = '<File_Name>'" -c ".read rest-api/templates/dashboards-custom/<path>" | head -5
```

Unset variables are `NULL`, as in the API. Param names that are SQL keywords
need quotes (`SET VARIABLE "limit" = 5`). Honour a session pin's literal
bundle path.

### F5 — Findings value

With `@default_result`, the value in the overview equals the F3 row count
(`row_count`) or the column of the first row (`first_row:<column>`); with the
paging frame `row_count` counts at most one page. The overview runs it on
"Run all" or when the user opens the dashboard.

## Closing message — single-file form

```
Single-file dashboard created: rest-api/templates/dashboards-custom/<path>

Dashboard ID:   <id>
Title:          <title> (English)
Overview:       Dashboards / Custom / [<folder> / …] <title>
Columns:        <output columns>  · row click: <action> (<type>)
Findings value: <name> = <value> (<meaning>) | none
Filter params:  <param>=<values>  → try /dashboard/<id>?<param>=<value>
Verified:       GET /api/dashboards/<id> → HTTP 200; /api/query?template=<id> → N rows; duckdb .read OK

Live at /dashboard/<id> — browser reload (Ctrl+R) picks it up.
```

Then offer, in one line each: adding it as a member of an own test
(`/create-custom-test`, only with `@default_result`), and growing it into a
bundle later (KPI tiles, several panels, translations) without rewriting the
SQL.
