# error_codes

Part of the [FM-Lab schema](../Schema.md) · Runtime & diagnostics · `reference/fm_spec.duckdb` (fm-spec language reference)

The FileMaker error codes as returned by `Get(LastError)`, the Script Debugger and the platform APIs — the Claris reference page as data, 294 rows. Claris lists single codes (`-1`, `0`, `101` …) **and ranges** (`1552-1559` for plug-in errors, `5000-5499` for the custom errors of *Revert Transaction*), so a code is a span: `code_from` … `code_to` (a single code has both equal) and `code_text` keeps the Claris spelling. The English message lives here in `message_en`; the ten other locales are in [error_codes_lang](error_codes_lang.md).

**Looking up a code** is a span test, never an equality: `WHERE 5123 BETWEEN code_from AND code_to` returns the `5000-5499` row. The REST route `GET /api/reference/error-codes/:code` and the schema viewer's *Error Codes* tab apply the same rule.

`scope` separates the codes Claris marks with `(*)` — returned by the web publishing engine or a FileMaker REST API (Data API, OData, Admin API) — as `web` (25 rows) from the `core` codes every client and host can return. A script that compares `Get(LastError)` with a web-only code either runs in a web context or carries a branch that cannot fire; the [script error checks](../../Wiki/Analysis%20Tests.md) read the compared literals against this table.

## Columns

| Column | Type |
|---|---|
| `code_from` | `INTEGER` |
| `code_to` | `INTEGER` |
| `code_text` | `VARCHAR` |
| `scope` | `VARCHAR` |
| `message_en` | `VARCHAR` |

**See also:** [error_codes_lang](error_codes_lang.md) · [feature_versions](feature_versions.md) · [functions](functions.md) · [Analysis Tests](../../Wiki/Analysis%20Tests.md)
