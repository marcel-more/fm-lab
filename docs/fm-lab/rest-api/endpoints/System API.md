# System API

Health, solution statistics, server configuration and the module version manifest.

## GET /api/version

Health probe and feature discovery. The endpoint answering with `200` is the liveness signal; the payload also tells clients which optional plugins are enabled.

**Response `data`**

```json
{
  "version": "0.9.4",
  "api_name": "FM-Lab REST API",
  "node_version": "v22.x",
  "uptime_seconds": 1234,
  "health": "healthy",
  "database": { "connected": true, "path": "…", "size_mb": 412.5, "table_count": 68 },
  "features": {
    "fmide": { "enabled": false, "version": "…", "routes_prefix": "/fmide", "…": "…" }
  }
}
```

Honors `X-Solution` — `database` describes the requested solution's catalog copy.

## GET /api/info

Content statistics of the context solution: imported files, object counts by type, link counts.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `file` | string | — | Scope object/link statistics to one `File_Name` |

**Response `data`**

- `active_solution` — `{ id, display_name, uuid }`: the **server default** solution
- `context` — `{ id, display_name, uuid, is_server_default }`: the solution *this request* resolved to (differs when `X-Solution` is set). Clients should always render "their" solution from `context`.
- `solution` — `file_count`, `files[]` (`File_Name`, `File_FullName`, `FileMaker_Version`, `Has_DDR_INFO`, `Import_Timestamp`), `object_statistics` (`total_objects`, `by_type`), `link_statistics` (`total_links`, `cross_file_links`, `operational_links`, `structural_links`)

May surface `409 SCHEMA_DRIFT` when the solution was imported with an outdated catalog schema (see [Error responses](../REST%20API%20Conventions.md#error-responses)).

## GET /api/system/config

Installation-wide client bootstrap configuration.

**Response `data`:** `languages` (`{ default, supported[] }`) and `settings` (server-side settings store). The REST API base URL is deliberately *not* part of this payload — it is a per-browser client setting.

## PUT /api/system/config

Merge-patch the installation-wide settings.

**Request body:** `{ "settings": { "<key>": <value | null> } }` — `null` removes a key.

Errors: `400 INVALID_SETTINGS` (body has no `settings` object), `400 CLIENT_ONLY_SETTING` (attempt to store client-only keys such as `apiUrl`; the message lists the rejected keys).

> Note: this endpoint is currently unauthenticated. Treat the API as a local development server.

## GET /api/version-manifest

Serves the module-granular `version.json` manifest of the installation (global version plus per-module versions). Read fresh from disk on every request, so a regenerated manifest is visible without a server restart.

`components.xml_import` carries two numbers: `version` is the display version of the XML converter, `engine_version` the internal engine version (`CONVERTER_VERSION` in the converter script) that the changelog's *Components* line and the import log cite. The web client's version line shows both.

Errors: `404 VERSION_MANIFEST_NOT_FOUND` when the manifest file is missing.

Deliberately separate from `/api/version`: `/version` is health + features, `/version-manifest` is the fine-grained module inventory.

---

See also: [Solutions API](Solutions%20API.md), [REST API Conventions](../REST%20API%20Conventions.md).
