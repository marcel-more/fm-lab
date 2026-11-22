# function_renames

Part of the [FM-Lab schema](../Schema.md) · Language layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Names a function or a Get selector carried before Claris renamed it (since fm-spec 2.10.0), one row per name and language, with the FileMaker version that introduced the new name. The version of a *function* stays in [functions](functions.md) (`origin_version`); this table holds the validity of a *name*: `Get ( LastErrorDetail )` exists since FileMaker 19.6.1, while the function itself is older — before 19.6.1 it was called `Get ( LastExternalErrorDetail )`.

## Columns

| Column | Type |
|---|---|
| `function_id` | `INTEGER` |
| `name_kind` | `VARCHAR` |
| `language` | `VARCHAR` |
| `legacy_name` | `VARCHAR` |
| `current_name` | `VARCHAR` |
| `renamed_in_version` | `VARCHAR` |
| `renamed_in_version_num` | `INTEGER` |
| `evidence` | `VARCHAR` |
| `legacy_accepted` | `BOOLEAN` |
| `legacy_accepted_version` | `VARCHAR` |

## Notes

- `name_kind` is `getparameter` (the selector inside `Get ( … )`) or `function` (a function name). `current_name` is today's name in the same language and role; it always resolves to the same function in [function_name_lookup](function_name_lookup.md).
- `renamed_in_version_num` is the numeric comparison key of `renamed_in_version`, in the same three-part canon as `origin_version_num` in [functions](functions.md) (`19.6.1` → `19006001`). Compare versions on this key, never on the text.
- One row yields both directions of a version check: the legacy name in a file of `renamed_in_version` or later is a stale name, the current name in an older file does not exist there yet.
- `evidence` names the source of the rename: `release_notes`, `help_archive` or `docset`.
- `legacy_accepted` records whether FileMaker still parses the legacy name in a version at or past the rename: `NULL` = untested, `true` = parsed (FileMaker shows the new name), `false` = written as *function missing*. It is set only by a paste test, in the version named in `legacy_accepted_version`.
- The legacy name also resolves through [function_name_lookup](function_name_lookup.md), with `match_source = 'legacy'`, both as the bare selector and in its call form (`Get(LastExternalErrorDetail)`).
- Current rows: `LastErrorDetail` (140), English `LastExternalErrorDetail` and German `LetzteExterneFehlerNrDetail`, renamed in FileMaker 19.6.1. A paste test in FileMaker 26.0.3 shows that FileMaker rejects both old names: the import log reports error 1215, the formula arrives commented out, and the other steps of the snippet paste without a word — the same as for an invented selector. Both rows therefore carry `legacy_accepted = false`. Renames before FileMaker 19 are not recorded.

**See also:** [functions](functions.md) · [function_name_lookup](function_name_lookup.md) · [Skill fm-generate-script](../../skills/Skill%20fm-generate-script.md) · [Skill filemaker-function-reference](../../skills/Skill%20filemaker-function-reference.md)
