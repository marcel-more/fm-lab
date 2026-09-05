# fm-test — Direct path (no REST server)

Fallback recipe when `http://localhost:3003` does not respond. Same semantics
as the API path: the member SQLs only ever see the two params `file` and
`scope_uuids`; all object-like scopes are normalised BEFORE execution.

## 1. Discovery — `read_json` over both tiers

Tests live in `rest-api/templates/tests/<…>/<id>/test.json` (system tier) and
`rest-api/templates/tests-custom/<…>/<id>/test.json` (custom tier). Custom
wins on id collision — dedupe explicitly (`read_json` has no precedence):

```sql
WITH all_tests AS (
  SELECT *, filename,
         filename LIKE '%tests-custom%' AS is_custom
  FROM read_json('rest-api/templates/tests*/**/test.json',
                 union_by_name = true, filename = true)
),
ranked AS (
  SELECT *, row_number() OVER (PARTITION BY id ORDER BY is_custom DESC) AS rn
  FROM all_tests
)
SELECT id, title, testType, keywords, objectTypes, scopes
FROM ranked
WHERE rn = 1
  AND (list_contains(objectTypes, 'Script') OR len(objectTypes) = 0)
  AND (list_contains(keywords, '<keyword>') OR title ILIKE '%<keyword>%');
```

(Adjust the path prefix when not running from the repo root.)

## 2. Member resolution

With `--profile <id>`: look up the profile in the test.json `profiles[]` —
unknown id = hard error (no silent full run). A profile without a `members`
field means "all members"; otherwise only process the listed refs and report
the rest as skipped.

For each `members[]` entry of the chosen `test.json`:

- `kind: "dashboard"` → bundle dir under
  `rest-api/templates/dashboards-custom/**/<ref>/` (custom first, then
  `rest-api/templates/dashboards/**/<ref>/`). Read `manifest.json`:
  - `analysis.defaultResult` names the dataset (usually `summary`) and column
    (usually `finding_count`).
  - dataset SQL file: `datasets[]` entry with that id → `bundle:data/….sql`.
  - findings rows: the dataset with id `findings`.
- `kind: "query"` → `rest-api/templates/sql-custom/<ref>.sql`; frontmatter
  `@default_result` gives `{ type, name, meaning, aggregate }`
  (`row_count` = number of rows, `first_row:<col>` = first row's column).

## 3. Scope params → `SET VARIABLE`

```bash
duckdb db/fm_catalog.duckdb \
  -c "SET VARIABLE file = 'MyDatabase'" \
  -c "SET VARIABLE scope_uuids = '<uuid1>,<uuid2>'" \
  -c ".mode markdown" \
  -c ".read rest-api/templates/dashboards-custom/static-code-analysis/error_prone/exit_script_in_loop/data/summary.sql"
```

- Solution scope: set NO variables (unset `getvariable` → NULL → predicates
  collapse; behavior identical to the dashboard).
- Object scope: `scope_uuids = '<uuid>'` **plus** `file` (identity is
  (UUID, File_Name) — clones!). Run only the members whose declared
  `objectTypes` / `@object_types` include the object's type; report the
  others as `skipped` / `object-type` (never as 0 = passed). Members without
  a declared list are universal.
- Object-list scope: CSV in `scope_uuids`; set `file` only when all objects
  come from one file.
- The `limit` variable stays unset (SQL default 500) unless the user asks.

## 4. Cluster expansion (cluster scope)

```sql
-- active engine = the partition with the most rows
WITH eng AS (
  SELECT Engine FROM ObjectClusters WHERE Engine IS NOT NULL
  GROUP BY Engine ORDER BY COUNT(*) DESC LIMIT 1
)
SELECT string_agg(Object_UUID, ',') AS scope_uuids, COUNT(*) AS n
FROM ObjectClusters, eng
WHERE ObjectClusters.Engine = eng.Engine
  AND Community = (
    SELECT Community FROM CommunityNames, eng
    WHERE CommunityNames.Engine = eng.Engine
      AND (lower(Semantic_Name) = lower('<ref>')
           OR lower(Heuristic_Name) = lower('<ref>')
           OR CAST(Community AS VARCHAR) = '<ref>')
    LIMIT 1
  );
```

Guard: abort with a clear message above **5000** UUIDs ("scope too large — use
file or solution scope"). Missing `ObjectClusters`/`CommunityNames` tables →
tell the user to run `fm-graph-cluster` (a `--force-rebuild` import wipes the
cluster layer).

## 4b. Platform sets (`platform-*`)

The platform bundles read `ref.step_compat` / `ref.script_steps`. The API
attaches the reference DB automatically; on the direct path attach it first:

```bash
duckdb db/fm_catalog.duckdb \
  -c "ATTACH 'reference/fm_spec.duckdb' AS ref (READ_ONLY)" \
  -c "SET VARIABLE scope_uuids = '<uuid>'" -c "SET VARIABLE file = '<file>'" \
  -c ".read rest-api/templates/dashboards-custom/static-code-analysis/platform/platform_compat_server/data/summary.sql"
```

Aspect profiles: `platform-ios`/`platform-server` ship two members —
`platform_compat_<env>` (aspect a, compatibility) and `platform_specific_<env>`
(aspect b, platform binding; severity always `info`, default result
`script_count` with unit `scripts`). `--profile compat`/`--profile specific`
selects one member, no profile runs both; the binding bundles need the same
`ref` ATTACH. The specific-server bundle has a third dataset `callsites.sql`
(caller → target detail) — run it when the user asks WHO calls a server-bound
script. Since schema 1.20.0 the server bundle resolves its targets over the
`calls_script` edges with `Link_Subrole IN ('on_server','on_server_callback')`
— on a pre-1.20.0 catalog the resolved rows come back empty (rebuild first).
Ad-hoc: "which scripts run server-side?" is a one-edge query on that subrole.

**Plug-in members** (`platform_compat_plugins_<env>`, bundle
`platform_specific_os` of the `platform-os-binding` set) read
`plugref.plugin_functions` / `plugin_function_platforms` /
`plugin_function_aliases` / `plugin_runtime_map` / `plugin_generic_rules` /
`plugin_os_map` — attach the plugin-spec DB alongside `ref` (the server
member needs BOTH since v7: its Server × OS cross-refinement reads
`ref.runtime_os_matrix`):

```bash
duckdb db/fm_catalog.duckdb \
  -c "ATTACH 'reference/fm_spec.duckdb' AS ref (READ_ONLY)" \
  -c "ATTACH 'reference/plugin_spec.duckdb' AS plugref (READ_ONLY)" \
  -c ".read rest-api/templates/dashboards-custom/static-code-analysis/platform/platform_compat_plugins_server/data/summary.sql"
```

If `reference/plugin_spec.duckdb` is missing, skip those members with the
explanation "plug-in platform map not installed — run `install-mbs-docs`"
(the API reports them as `skipped`/`missing-plugin-spec`); never guess plug-in
platform support from memory.

**Plug-in maintenance members** (`plugin_deprecated_call` /
`plugin_removed_call` / `plugin_version` of the `script-plugin-maintenance`
set) need only `plugref` (no `ref`), same ATTACH and the same
`missing-plugin-spec` skip. `plugin_version` is parameterised: set the
optional check version before the `.read` via
`-c "SET VARIABLE installed_version = '9.0'"` — unset means inventory only
(empty findings), an unparseable value degrades to one info hint row. Its
defaultResult is text (`required_version` from the `summary` dataset), and
version comparisons run on `since_version_num`, never on the string
(plugin_spec ≥ 1.2.0).

**OS-binding members** (`platform_os_steps` / `platform_os_functions` of the
`platform-os-binding` set) read `ref.step_os_affinity` /
`ref.function_os_affinity` / `ref.runtime_os_matrix` — fm_spec ≥ 1.13.0. On
an older reference the tables are absent: skip those members with the
explanation "reference predates 1.13.0 — re-run
`tools/fm-reference/pull-reference.sh`" (the API reports them as
`skipped`/`missing-fm-spec-os`); never derive OS bindings from step names or
doc grep ("Windows" in prose usually means window objects).

## 5. Findings

Run the `findings` dataset with the same variables, then sort by severity
(`error` → `warning` → `info`) and cap at ~20 rows per member for the report;
mention truncation. `step_no` in the outputs is already 1-based.
