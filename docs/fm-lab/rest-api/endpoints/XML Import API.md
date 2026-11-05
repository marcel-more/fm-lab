# XML Import API

Endpoints under `/api/xml/*` drive the XML-to-catalog conversion pipeline for a solution: inspect the inbox, start/cancel conversions, and follow progress live via Server-Sent Events.

**Solution scoping (special in this group):** the target solution is resolved with this precedence: explicit `?solution=<id>` query parameter or `"solution"` body field → `X-Solution` header → server-default solution. Unknown ids yield `404 SOLUTION_NOT_FOUND`. Imports of *different* solutions may run in parallel; a second import of the *same* solution is rejected.

**Locking:** the per-solution lock file is shared with the CLI pipeline (`convert-xml`). Whichever side starts first wins; the other receives `409 ALREADY_RUNNING` — on the CLI side the same collision is exit code `7`. Stale locks (dead process) are ignored automatically.

**When a run publishes:** a finished run syncs the catalog to the API's read copy and triggers the `reload` event only when it built a valid catalog. A resolve-phase (P2) failure aborts before the detail phases with `done { ok: false }` and **no** sync — the previously served catalog stays untouched. A run in which no file could be imported at all (every file a FileMaker 18 export, or skipped and failed) stops with `aborted { reason: "no_importable_files" }` — before anything runs when no file is a FileMaker 19+ export (`stage: "Preflight (format check)"`), otherwise after the extract phase (`stage: "Phase 1 Extract"`) — and writes and publishes nothing. A healing re-run publishes like any successful run; only a batch in which every file failed stays unpublished. One more effect worth knowing: content hashes are parser-policy-stamped, so after a webbed/DuckDB update a `changedOnly` run may legitimately re-read unchanged files once (a `log` event names the policy change) instead of skipping them.

---

## GET /api/xml/status

Inbox listing and run state for the context solution.

**Response `data`:** one entry per XML file in the solution's `xml/` folder (`files[]`) with a `status` of `unsupported` (FileMaker 18 export — the converter skips it), `new` (never imported), `outdated` (changed since last import) or `current`; plus `running` (boolean) and, while a run is active, a flat `active_run` (`phase`, `pct`, `processed`, `total`) for lightweight polling.

Per file the head of the XML (first 4 KiB) is probed:

| Field | Values | Meaning |
|---|---|---|
| `format` | `saxml` · `legacy` · `unknown` | `FMSaveAsXML` (FileMaker 19+, importable) · `FMDynamicTemplate` (FileMaker 18, not importable) · no root element recognized |
| `saxml_version` / `source_version` | e.g. `2.2.3.0` / `22.0.6` | Root attributes `version` and `Source` (exporting FileMaker version), `null` when absent |
| `format_flag` | `fm18` · `null` | Set only for `legacy` files (badge column of the import page) |
| `ddr_info` / `ddr_flag` | `true`/`false`/`null` · `missing`/`null` | DDR info of the export; always `null` for `legacy` files |

At top level, `unsupported_count` and `importable_count` count the inbox files; the import page disables its convert button when `importable_count` is `0`. `last_run` carries the compact run record (see [GET /api/xml/last-run/log](#get-apixmllast-runlog)).

## Run record

The last run of a solution is persisted as `state/last_xml_run.json` (record schema `2`) and returned by `GET /api/xml/status` (`last_run`, without events) and `GET /api/xml/last-run/log` (with events):

| Field | Meaning |
|---|---|
| `ok`, `exit_code`, `processed`, `total` | Outcome and counters |
| `error_count` | Failed files — format skips do not count here |
| `skipped_count`, `skipped_files[]` | Files skipped by the root check, each `{ filename, reason, source_version }` (`reason`: `legacy_format` · `unknown_root`); `null` for records of schema `1` |
| `aborted_reason` | `oom` · `incomplete` · `no_importable_files` · `null` |
| `aborted_detail` | For `no_importable_files`: `{ stage, total, skipped, failed, legacy, source_versions[] }`, otherwise `null` |

## GET /api/xml/runs

All currently running imports **across all solutions** (union of API-started runs and live CLI locks). API runs carry phase/progress; CLI runs report `{ solution, started_at, source: "cli", pid }`.

## POST /api/xml/convert

Start a conversion job. Returns immediately with `202` — the run continues server-side, decoupled from the request; consume progress via the stream endpoint.

**Request body**

| Field | Type | Default | Description |
|---|---|---|---|
| `changedOnly` | boolean | `true` | Only convert new/changed files (manifest skip); `false` forces a full rebuild. Legacy alias: `incremental` |
| `solution` | string | context | Target solution id |

**Response (202):** `{ "run_id": "…", "running": true, "changedOnly": true, "solution": "…" }`

Errors: `409 ALREADY_RUNNING` (this solution already converting — via API or CLI), `429 MAX_CONVERTS` (global concurrency cap reached; response lists the running imports), `404 SOLUTION_NOT_FOUND`.

## GET /api/xml/convert/stream

Server-Sent-Events subscription (`Content-Type: text/event-stream`) to the active run of the context solution (`?solution=<id>` optional). On subscribe, the buffered event history is replayed so late subscribers catch up; multiple concurrent subscribers are allowed. A `: heartbeat` comment is emitted every 15 s.

Each event is a `data: <JSON>` line with an `event` field:

| Event | Payload | Meaning |
|---|---|---|
| `start` | `ts`, `changedOnly`, `solution` | Run began |
| `progress` | phase, percentage | Coarse pipeline progress |
| `batch_start` | `total` | Number of XML files in the batch, emitted right after file discovery |
| `file_start` / `file` | `total`; `index`, `ok`, `status` | Per-file batch progress; a format skip carries `status: "skipped"`, `reason` (`legacy_format` · `unknown_root`) and `source_version` |
| `import_start` / `import_progress` / `import_done` | `processed`, `total` | Fine-grained import phase (chunk level) |
| `log` | `level`, `msg` | Log line (`error` level flagged) |
| `reload` | `ok`, … | Post-convert API reload result |
| `aborted` | `reason` | Converter stopped (`cancelled`, `oom`, `incomplete`, `no_importable_files` — the latter with `stage`, `total`, `skipped`, `failed`, `legacy`, `source_versions`) |
| `error` | `message` | Failure |
| `done` | `ok`, `exit_code` | Terminal event |
| `idle` | — | No active run and no history; the stream closes |

Closing the stream (navigating away) only stops delivery to that client — the run itself keeps going.

## POST /api/xml/convert/cancel

Abort the active run of the context solution — the only operation that actually terminates the converter process.

**Request body (optional):** `{ "solution": "<id>" }`

**Response `data`:** `{ "cancelled": true, "solution": "…" }`. Errors: `409 NOT_RUNNING`, `404 SOLUTION_NOT_FOUND`.

## GET /api/xml/last-run/log

Full recorded event stream of the last conversion of the context solution: the run record (see [Run record](#run-record)) plus `events: [ … ]` (or `run_id: null` when no run has happened yet).

## POST /api/xml/reveal

Open the context solution's `xml/` inbox in the host file manager (macOS `open` / Linux `xdg-open`). Errors: `409 REVEAL_UNSUPPORTED` when no host file manager is reachable (e.g. inside a container) — clients should then display the path for manual navigation.

---

See also: [Solutions API](Solutions%20API.md) (bundle lifecycle), [REST API Conventions](../REST%20API%20Conventions.md) (solution scoping, error envelope).
