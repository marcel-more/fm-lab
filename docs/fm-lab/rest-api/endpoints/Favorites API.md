# Favorites API

Endpoints under `/api/favorites/:kind/*` manage the **favorites** of the web client — the star on the title row of a dashboard or test, on the tiles and list rows of the dashboard and test overviews, and their *Favorites* views (see [Dashboard overview](../../Wiki/Components.md#dashboard-overview) and [Test overview](../../Wiki/Components.md#test-overview)). Two kinds exist: `dashboard` (bundles and single-file dashboards) and `test`; any other kind answers `400 VALIDATION_ERROR`. Each kind keeps its own list. Favorites are a workspace preference, not solution data: they live in `.fmlab/favorites.json`, are shared by every browser that talks to this API and stay the same when you switch solutions. The `X-Solution` header plays no role for these endpoints (an invalid one is still rejected up front, see [Solution scoping](../REST%20API%20Conventions.md#solution-scoping-x-solution)).

Changes are single-id operations (`PUT`/`DELETE` per id), so two tabs or browsers never overwrite each other's changes. There is no push: the web client re-reads the list when the overview opens and when a tab becomes visible again. Errors follow [Error responses](../REST%20API%20Conventions.md#error-responses).

## Response shape

All three operations answer with the current favorites:

```json
{
  "success": true,
  "data": {
    "items": [
      { "id": "unused_layout", "added_at": "2026-11-01T10:12:00Z" }
    ],
    "missing": ["my_old_dashboard"]
  }
}
```

| Field | Description |
|---|---|
| `items` | Available favorites in the order they were added; `added_at` is ISO-8601 UTC |
| `missing` | Stored ids that no longer resolve — the dashboard or test was deleted or renamed, or a dashboard no longer lives in a content area. Never removed automatically; remove them with `DELETE` |

## GET /api/favorites/:kind

Lists the favorites of one kind (`dashboard` or `test`). Read-only — the call never cleans up `missing` ids.

```bash
curl "http://localhost:3003/api/favorites/dashboard"
curl "http://localhost:3003/api/favorites/test"
```

## PUT /api/favorites/:kind/:id

Adds a dashboard or a test to the favorites. Idempotent: adding an existing favorite keeps its original `added_at`.

- **Dashboards:** only dashboards of the content areas — shipped content dashboards, your own bundles and single-file dashboards under `dashboards-custom/` and community dashboards. System and module pages (home, file details, the overview pages, docsets) cannot.
- **Tests:** every test, shipped, custom or community.

```bash
curl -X PUT "http://localhost:3003/api/favorites/dashboard/unused_layout"
curl -X PUT "http://localhost:3003/api/favorites/test/layout-hygiene"
```

| Status | Code | When |
|---|---|---|
| 200 | — | Added, or already a favorite |
| 400 | `VALIDATION_ERROR` | Unknown kind, or the id is not valid (letters, digits, `_`, `-`) |
| 404 | `TEMPLATE_NOT_FOUND` | No dashboard or test with this id |
| 422 | `NOT_FAVORITABLE` | The dashboard exists but is a system or module page |

## DELETE /api/favorites/:kind/:id

Removes a favorite. Idempotent: answers `200` also when the id was not a favorite. Only the kind and the id format are checked, so a favorite whose dashboard or test is gone stays removable.

```bash
curl -X DELETE "http://localhost:3003/api/favorites/dashboard/my_old_dashboard"
```

| Status | Code | When |
|---|---|---|
| 200 | — | Removed, or not a favorite |
| 400 | `VALIDATION_ERROR` | Unknown kind, or the id is not valid |

## Storage

`.fmlab/favorites.json` is written atomically (temporary file + rename) and is excluded from git. The format is grouped by scope and kind; the workspace scope holds the dashboard and the test favorites:

```json
{
  "version": 1,
  "scopes": {
    "workspace": {
      "dashboard": [
        { "id": "unused_layout", "added_at": "2026-11-01T10:12:00Z" }
      ],
      "test": [
        { "id": "layout-hygiene", "added_at": "2026-11-03T09:40:00Z" }
      ]
    }
  }
}
```

A file that cannot be read (for example after a manual edit with a syntax error) counts as empty and is never overwritten silently: the next change first moves it aside to `favorites.json.corrupt-<timestamp>`.

## See also

- [Dashboard overview](../../Wiki/Components.md#dashboard-overview) — the views, the star and the favorites list in the web client
- [Results API](Results%20API.md) — the result envelopes behind the status columns of the favorites list
- [Dashboard Datasets](../../templates/Dashboard%20Datasets.md) — bundle areas and where dashboards live
- [Tests API](Tests%20API.md) — the tests behind the `test` favorites
