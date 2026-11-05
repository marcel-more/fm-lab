# Maintenance API

Endpoints under `/api/maintenance/*` keep the workspace itself in order. They are independent of the selected solution — the `X-Solution` header plays no role (an invalid one is still rejected up front, see [Solution scoping](../REST%20API%20Conventions.md#solution-scoping-x-solution)). Errors follow [Error responses](../REST%20API%20Conventions.md#error-responses).

## Dashboard cleanup

Earlier versions kept the app pages directly in `rest-api/templates/dashboards/`, the shipped rubrics (Static Code Analysis, Modularization, …) in `rest-api/templates/dashboards-custom/` and the custom queries in `rest-api/templates/sql-custom/`. `git pull` moves tracked files but leaves directories with untracked rests behind, and an update by copying files keeps complete old copies. Old copies in `dashboards-custom/` are the serious case: they replace the shipped dashboards as your own bundles (badge *overrides standard*) without showing up in `git status`.

The cleanup compares the installed tree with `rest-api/templates/dashboards/inventory.json` — the list of every bundle and folder the release ships — and sorts each leftover into one of these cases:

| Case | Where | What | Moves to |
|---|---|---|---|
| `a1` | `dashboards/` | Old copy of a shipped bundle at its earlier place (e.g. `dashboards/home` beside `dashboards/system/home`) | `dashboards-removed/<timestamp>/dashboards/…` |
| `a2` | `dashboards-custom/` | Old copy at the path of a shipped bundle with the same id; `modified: true` when its files differ from the shipped bundle | `dashboards-removed/<timestamp>/dashboards-custom/…` |
| `a3` | both | Folder left over without bundles — an old rubric folder with only `folder.json` or system files, or a folder named like a shipped bundle | `dashboards-removed/<timestamp>/…` |
| `b1` | `dashboards/` | Your own bundle, or a folder of your own bundles, at the old place | `dashboards-custom/…` (same relative path, appears under **Custom**) |
| `b2` | `dashboards/` | Any other folder that the release does not ship | `dashboards-removed/<timestamp>/dashboards/…` |
| `b3` | `dashboards/` | Your own bundle whose id or target path already exists in `dashboards-custom/` (`conflict: true`) | `dashboards-removed/<timestamp>/dashboards/…` |

Single-file dashboards (the former custom queries) add five cases. The **old query folders** `sql-custom/`, `sql/` and `sql-custom-details/` next to `dashboards/` take part; a name counts as *known* when the dashboard inventory lists it as a single-file dashboard or `rest-api/templates/queries/inventory.json` lists it as an internal template:

| Case | Where | What | Moves to |
|---|---|---|---|
| `f1` | old query folder | Old copy of a shipped query or internal template (known name); `modified: true` when it differs from the shipped file (`@category` lines ignored), `canonical` names the shipped file | `dashboards-removed/<timestamp>/<old folder>/…` |
| `f2` | old query folder | Your own query (unknown name) — from `sql/` with `note: "report_template"` | `dashboards-custom/<name>.sql` (appears under **Custom**) |
| `f3` | — | Like `f2` or `f5`, but `dashboards-custom/` already has a dashboard with that id (`conflict: true`) | `dashboards-removed/<timestamp>/…` |
| `f4` | old query folder | Rests: files that are not `.sql`, empty folders, an old folder without any `.sql` (one entry) | `dashboards-removed/<timestamp>/…`; an old folder left empty by the run is removed |
| `f5` | `dashboards/` | A `.sql` file outside a bundle that is not at its inventory path — unknown: your own file; known: an old copy | unknown → `dashboards-custom/<same path>`; known → `dashboards-removed/<timestamp>/…` |

**Own versions.** An old copy you edited (`a2`, or `f1` of a shipped single-file dashboard) is first copied to `dashboards-custom/<id>-local` (`.sql` for a file; `-local-2`, … when taken) with the new id and the title suffix *(own version)* in `manifest.json` and every `locales/*.json`, then moved aside like any other old copy. Nothing stays at the old path: a locally edited tracked file there would stop the next `git pull` that deletes it. The copies sit on the top level of `dashboards-custom/`, because an old rubric folder may move aside as a whole in the same run. Copies of internal templates (`queries/`) only move aside.

**Frozen index.** Every release ships `rest-api/templates/frozen-legacy.json`: the files an earlier release tracked at the old places, path → git blob id of that release. Old copies stay behind where an update did not go through `git pull` — files copied over an old folder, or a stopped pull completed with `tools/update.sh`. With the index, `modified` means *edited by you* — not *differs from the shipped version*, which the release may have changed itself — and an unedited old copy whose id is no longer shipped moves aside instead of being taken for your own content. Without the file, the comparison with the shipped version applies.

**At server start.** The REST API runs the dashboard and the test cleanup once before it serves the first request (`STARTUP_CLEANUP_ENABLED=false` turns this off) and records `"trigger": "startup"` in `cleanup.json`; runs through the endpoint record `"manual"`. Afterwards it takes over the units `tools/update.sh` saved below `.fmlab/update-backup/<timestamp>/units/` — edited shipped dashboards and tests — as own versions `<id>-local`, once per backup folder (marker `imported.json`; a unit identical to the shipped version is skipped).

Never touched: everything the inventory lists, your own bundles, files and folders in `dashboards-custom/` outside the old rubric paths (deliberate overrides included), `dashboards-community/` and `rest-api/templates/queries/`. An old query folder configured elsewhere (`TEMPLATE_CUSTOM_DIR`) is not moved; its files stay visible with the badge *old location*. Nothing is deleted — each run gets its own time-stamped folder below `rest-api/templates/dashboards-removed/` (ignored by git, never listed in the overview) with a protocol `cleanup.json`. Without a usable `inventory.json` nothing is classified.

### Item shape

```json
{
  "case": "a2",
  "from": "dashboards-custom/static-code-analysis/unused_code/unused_layout",
  "to": "dashboards-removed/2026-11-02T14-30-05Z/dashboards-custom/static-code-analysis/unused_code/unused_layout",
  "target": "removed",
  "id": "unused_layout",
  "ids": ["unused_layout"],
  "modified": false,
  "conflict": false
}
```

| Field | Description |
|---|---|
| `from`, `to` | Paths relative to `rest-api/templates/` |
| `target` | `custom` (own dashboard moving to `dashboards-custom/`) or `removed` |
| `id` / `ids` | Dashboard id when `from` is a bundle or file (`null` for a folder) / every id moved with the entry |
| `modified` | `a2`, `f1`: you edited the copy (with the frozen index), else: it differs from the shipped one — then also true for an unchanged copy of an older release |
| `fork`, `fork_id` | Only on a `modified` copy that lives on as an own version: its target path (relative to `rest-api/templates/`) and new id |
| `conflict` | `b3`, `f3`: the entry could not move to `dashboards-custom/` |
| `canonical` | `f1`: the shipped file the copy was compared with |
| `note` | `report_template` for an own file from `sql/`, otherwise `null` |

### GET /api/maintenance/dashboards/cleanup

Read-only check. Answers with `inventory` (false when no usable inventory exists), `stamp` (the run folder name a cleanup started now would use), `items`, a `summary` (`total`, `to_custom`, `to_removed`, `modified`, `conflicts`, `forked`) and `running`. An empty `items` list means there is nothing to clean up.

Two more fields report what happened at server start, `null` when there is nothing: `last_startup_run` — the newest automatic run (`stamp`, `created_at`, `trigger`, `removed_dir`, `summary`, `forks` with `from`, `fork`, `fork_id`) — and `last_update_import` — the newest backup of `tools/update.sh` that produced own versions of this kind (`stamp`, `backup`, `forks` with `kind`, `unit`, `fork`, `fork_id`). The overview shows both once.

```bash
curl "http://localhost:3003/api/maintenance/dashboards/cleanup"
```

### POST /api/maintenance/dashboards/cleanup

Runs the cleanup. The server classifies anew — a client list is never taken over. The optional body names `from` values of the preview to leave in place; such an entry also keeps its parent folders where they are.

```bash
curl -X POST "http://localhost:3003/api/maintenance/dashboards/cleanup" \
  -H "Content-Type: application/json" \
  -d '{"exclude": ["dashboards-custom/static-code-analysis/unused_code/unused_script"]}'
```

Before the first move every source and target is checked; a source that vanished, an occupied target in `dashboards-custom/` or a target on another file system stops the run before anything moves. The answer lists `moved`, `skipped` (entries not moved because of an error), `errors` (`from`, `message`), the `summary` of the moved entries and `removed_dir`, the run folder with `cleanup.json` (`null` when nothing moved). The dashboard list, the template lookup and the results reload automatically.

| Status | Code | When |
|---|---|---|
| 200 | — | Run finished (also when there was nothing to do) |
| 400 | `VALIDATION_ERROR` | `exclude` is not an array of strings |
| 401 | `UNAUTHORIZED` | `ADMIN_RELOAD_TOKEN` is set and the `X-Admin-Token` header is missing or wrong |
| 409 | `CLEANUP_RUNNING` | Another cleanup run is still active |

## Test cleanup

The same routine for [Analysis Tests](../../Wiki/Analysis%20Tests.md): it compares `rest-api/templates/tests/` with `rest-api/templates/tests/inventory.json` and moves leftovers. `tests-custom/` and `tests-community/` are never touched.

| Case | Where | What | Moves to |
|---|---|---|---|
| `t1` | `tests/` | Old copy of a shipped test away from its inventory path (known id) | `tests-removed/<timestamp>/…` |
| `t2` | `tests/` | Your own test (unknown id) in the shipped tree | `tests-custom/<same path>` (appears under **Tests / Custom**) |
| `t3` | `tests/` | Like `t2`, but `tests-custom/` already has that id (`conflict: true`) | `tests-removed/<timestamp>/…` |
| `t4` | `tests/` | Rests: folders and files that are neither a shipped test nor a test of your own | `tests-removed/<timestamp>/…` |

`GET /api/maintenance/tests/cleanup` and `POST /api/maintenance/tests/cleanup` take and return exactly the shapes of the dashboard routes; the run reloads the test list and the results. Each routine has its own lock — a running dashboard cleanup does not block the test cleanup. The web client shows the box on `/tests` only when there is something to do.

## See also

- [Dashboard overview](../../Wiki/Components.md#dashboard-overview) · [Test overview](../../Wiki/Components.md#test-overview) — the hint boxes in the web client
- [Areas and overrides](../../templates/Dashboard%20Datasets.md#areas-and-overrides) — where shipped and own dashboards live
- [Solutions API](Solutions%20API.md) — the other administrative endpoints and the admin token
