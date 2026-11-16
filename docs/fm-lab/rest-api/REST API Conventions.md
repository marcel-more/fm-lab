# REST API Conventions

Shared behavior of all FM-Lab REST API endpoints. Endpoint-specific parameters are documented in the group documents listed in [REST API Overview](REST%20API%20Overview.md).

## Base URL and content types

All endpoints live under `http://localhost:3003/api` (port configurable via `PORT`). Requests use query parameters (GET) or JSON bodies (POST/PUT/PATCH, `Content-Type: application/json`). Responses default to `application/json`; other content types depend on the requested output format (see [REST API Output Formats](REST%20API%20Output%20Formats.md)).

## Response envelope

JSON responses share one envelope:

```json
{
  "success": true,
  "data": { "…": "…" },
  "meta": {
    "execution_time_ms": 12,
    "result_count": 42,
    "query": "SELECT … (only with debug=true)"
  }
}
```

- `meta` is only included when `meta=true` (or `debug=true`) is passed.
- Non-JSON formats (`text`, `html`, `markdown`, …) return the rendered payload directly, without the envelope.

## Common query parameters

Most read endpoints accept these parameters (validated centrally; unknown parameters are stripped):

| Parameter | Type | Default | Description |
|---|---|---|---|
| `format` | string | `json` (`html` for `/report`) | Output format, case-insensitive — see [REST API Output Formats](REST%20API%20Output%20Formats.md) |
| `limit` | integer | `100` | Maximum number of results; `0` = all, hard cap `10000` |
| `offset` | integer | `0` | Pagination offset (where supported, e.g. `/search`) |
| `file` | string | — | Filter/scope by FileMaker file name (`File_Name`) |
| `meta` | boolean | `false` | Include the `meta` block in the envelope |
| `debug` | boolean | `false` | Include the executed SQL in `meta.query` |

Boolean parameters accept `true`/`false`. Enum-valued parameters are case-insensitive.

Parameter **names** are case-insensitive as well (`objectType` and `objecttype` are the same parameter). Each name may appear only once per query string: a repeated name — `?file=a&file=b`, also in different spellings — answers `400 VALIDATION_ERROR` with `details.parameter`. Lists travel as one comma-separated value (e.g. `types=Script,Layout`).

## Solution scoping (X-Solution)

A workspace manages one or more imported solutions. Every request is served from a per-solution read copy of the catalog database:

- Without a header, requests target the **active solution** of the workspace.
- With `X-Solution: <solution-id>`, the request targets that solution regardless of which one is active. The server keeps an LRU pool of open solution databases, so switching per request is cheap.
- An unknown or invalid `X-Solution` id is rejected with a hard `404 SOLUTION_NOT_FOUND` **before any route runs** — there is no silent fallback to the active solution.
- Activating a different solution workspace-wide is a separate, explicit operation (`POST /api/admin/solution/activate`, see [Solutions API](endpoints/Solutions%20API.md)) — the header never changes the workspace default.

## Clone disambiguation (`file` + `AMBIGUOUS_UUID`)

Cloned or modular FileMaker files share internal object UUIDs, so a bare `Object_UUID` can match more than one file. Object-addressing endpoints (`/get`, `/get-details`, `/references`, `/graph/subgraph`, …) therefore accept an optional `file` (or `focus_file` / `dest_file` / `origin_file`) parameter holding the exact `File_Name`:

- UUID unique in the catalog → the parameter may be omitted (graceful downgrade).
- UUID ambiguous and no file given → `409 AMBIGUOUS_UUID`; retry with `file=<File_Name>`.

## Error responses

Errors use the same envelope with `success: false`:

```json
{
  "success": false,
  "error": {
    "code": "OBJECT_NOT_FOUND",
    "message": "Object with UUID 'ABC-123' not found",
    "details": { "uuid": "ABC-123" }
  }
}
```

| Code | HTTP | Meaning |
|---|---|---|
| `VALIDATION_ERROR` | 400 | Invalid or missing request parameters (`details.errors` lists field-level messages; a single rejected parameter is named in `details.parameter`) |
| `SOLUTION_NOT_FOUND` | 404 | Unknown solution id in `X-Solution`, `?solution=` or a solutions endpoint |
| `OBJECT_NOT_FOUND` | 404 | No catalog object matches the given UUID/identifier |
| `AMBIGUOUS_UUID` | 409 | UUID exists in multiple files — retry with `file=<File_Name>` |
| `SCHEMA_DRIFT` | 409 | The solution was imported with an older catalog schema than the server expects — re-convert the XML export to resolve |
| `TEMPLATE_NOT_FOUND` | 404 | Unknown query/report template |
| `TEMPLATE_ERROR` | 500 | Template failed during execution |
| `DATABASE_ERROR` | 500 | DuckDB-level failure |
| `FILE_NOT_FOUND` | 404 | Referenced FileMaker file not in the catalog |
| `IMPORT_ERROR` | 500 | XML import pipeline failure |
| `REF_NOT_ATTACHED` | 503 | Reference database (`fm_spec`) not installed/attached |
| `REF_STEP_NOT_FOUND` / `REF_FUNCTION_NOT_FOUND` | 404 | Unknown script step / function in the reference database |
| `REF_LANG_INVALID` | 400 | Unsupported reference-database language |
| `REF_HELP_NOT_FOUND` | 404 | Claris Help mirror page not available |
| `CODEGEN_NOT_AVAILABLE` | 503 | Codegen pipeline or reference database not installed |
| `CODEGEN_TIMEOUT` | 504 | Codegen subprocess exceeded its time limit |
| `CODEGEN_ERROR` | 500 | Codegen execution failure |
| `INTERNAL_ERROR` | 500 | Unexpected server error |

This table lists the **core codes** shared across endpoint groups — it is not exhaustive. Individual endpoint groups define additional codes (for example `ALREADY_RUNNING` for the XML import lock or the solution-management codes); those are documented on the respective endpoint pages.

## Object types

Type parameters (`type=`) accept these values (case-insensitive):

`BaseTable`, `TableOccurrence`, `Relationship`, `Field`, `ValueList`, `CustomFunction`, `Script`, `ScriptStep`, `Layout`, `LayoutObject`, `LayoutPart`, `Account`, `PrivilegeSet`, `ExtendedPrivilege`, `Theme`, `CustomMenu`, `ScriptTrigger`, `ExternalDataSource`, `BaseDirectory`, `Variable`, `ScriptFolder`, `LayoutFolder`, `RelationshipGraph`, `BuiltinFunction`, `PluginFunction`, `ScriptStepType`, `PluginComponent`, `File`, `Calculation`.

`ScriptStepType`, `BuiltinFunction` and `PluginFunction` are **pseudo token types**: aggregate objects representing step/function *kinds* rather than user-created objects. Some list parameters (`with_usage`, `category`, …) only apply to them — see [Search API](endpoints/Search%20API.md). `ScriptFolder`/`LayoutFolder` are pseudo types over the single catalog type `Folder`, so consumers can tell script and layout folders apart. Note that a few catalog `Object_Type` values (`CustomMenuItem`, `Folder`, `PasteIndexObject`) are **not** accepted as `type=` filters. `Calculation` (schema 1.22.0) is a valid filter but high-cardinality and excluded from the generic name search — see [Search API](endpoints/Search%20API.md).
