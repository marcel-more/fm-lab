# Tests API

Endpoints under `/api/tests/*` expose **[Analysis Tests](../../Wiki/Analysis%20Tests.md)** — declared collections of rule dashboards and custom queries with a compact result model. Listing and detail are metadata reads; the run routes execute the members against the active solution.

All routes are `GET`. Errors follow [Error responses](../REST%20API%20Conventions.md#error-responses). Unknown or invalid test ids return `404 TEMPLATE_NOT_FOUND`; scope, profile and parameter problems return `400 VALIDATION_ERROR`. Solution scoping via `X-Solution` applies as everywhere ([Solution scoping](../REST%20API%20Conventions.md#solution-scoping-x-solution)).

## GET /api/tests

Lists all test definitions (built-in and custom; a custom test with the same id overrides the built-in one — `tier` and `overridesSystem` report this).

| Parameter | Type | Description |
|---|---|---|
| `objectType` | string | Only tests declaring this object type (e.g. `Script`) |
| `testType` | enum | `exploration` · `code-quality` · `error-check` · `security` · `inventory` · `performance` · `platform` |
| `scope` | enum | Only tests supporting this scope: `solution` · `file` · `object` · `object-list` · `cluster` |
| `q`, `keyword` | string | Text match over id, title, description, keywords |
| `folder` | string | Category folder path |
| `lang` | string | Localizes folder labels |

Response: `data[]` with the declaration surface (`id`, `title`, `description`, `testType`, `keywords`, `objectTypes`, `scopes`, `outputs`, `memberCount`, `profiles[]` incl. member refs, folder path/label/order, `tier`, `version`) plus a `validation` block (`status`, `errors[]`, `warnings[]`). Tests with validation errors are listed but cannot run.

## GET /api/tests/context

The cache-key context of the effective solution: `{ solution, catalogFingerprint, catalogMtimeMs }`. The fingerprint changes with every import — clients use it to key cached run results so a re-import invalidates them without bookkeeping.

## GET /api/tests/:id

One test with resolved member summaries: everything from the list row plus `members[]` (`kind`, `ref`, `title`, `icon`, `severity`, `resolved`, analysis declaration).

## GET /api/tests/:id/run

Runs all members (or a profile subset) in the requested scope and returns the enveloped results.

| Parameter | Type | Description |
|---|---|---|
| `uuid` | string | Object scope: one object UUID (with `object_type`, optionally `file`) |
| `object_type` | string | Object scope: the object's catalog type (`Script`, `Layout`, …); resolved from the catalog when omitted. Members that declare other object types are skipped |
| `uuids` | csv | Object-list scope |
| `file` | string | File scope (or the file disambiguator for `uuid`) |
| `cluster` | string | Cluster scope: community name or id (server expands to the member UUIDs) |
| `profile` | string | Run only this shipped profile's members; unknown ids are a `400`, never a silent full run |
| `include` | enum | `findings` adds each member's finding rows |
| `findingsLimit` | number | Cap per member (default 20, max 500) |
| `lang` | string | Reported back in `meta.lang` |

No scope parameter at all = solution scope. The requested scope must be declared by the test, otherwise `400 VALIDATION_ERROR`.

Response `data`: the `test` header, the normalized `context` (scope, resolved parameters, profile), `results[]` — one entry per member with `runStatus` (`ran` / `failed` / `skipped`), `resultState` (`error` / `warning` / `neutral` / `ok`), the member's `defaultResult` (`name`, `type`, `value`, `meaning`), optional `findings` (`rows[]`, `truncated`) and an `openTarget` deep link — plus the per-test `summary` (state counts across members) and `meta` (`durationMs`, `solution`, `catalogFingerprint`, `catalogMtimeMs`). Members outside a selected profile appear as `runStatus: "skipped"` with `skipReason: "profile"`. In object scope, members whose declared object types do not include the target object's type report `skipReason: "object-type"` — a test may span several object types (the *Unfinished Work* family covers scripts, layouts and calculations) and only the applicable members run; such a skip is never a pass. Two further skip reasons mark **install/version states, never errors**: `missing-plugin-spec` (a plug-in platform member without the derived [plugin-spec](../../schema/plugin-spec.md) database — install the MBS docs mirror) and `missing-fm-spec-os` (an OS-affinity member against a reference database older than fm-spec schema 1.13.0 — re-run the reference pull); each carries an explanatory `skipMessage`. A member that fails (missing metadata, SQL error) reports `runStatus: "failed"` with its error and never invalidates the other members. Solution-scope runs also warm the [results cache](Results%20API.md).

## GET /api/tests/:id/run/:memberIndex

Runs exactly one member by its zero-based position in the declaration — an explicit single pick; `profile` is ignored. Same parameters and response shape as the full run (with a single-entry `results[]`).
