# function_name_lookup

Part of the [FM-Lab schema](../Schema.md) · Language layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Reverse lookup from any function name in any locale to the canonical `function_id`, including the chunk role the name plays in parsed calculations.

## Columns

| Column | Type |
|---|---|
| `lookup_name` | `VARCHAR` |
| `function_id` | `INTEGER` |
| `match_source` | `VARCHAR` |
| `chunk_role` | `VARCHAR` |
| `is_primary` | `INTEGER` |

## Notes

- `chunk_role` is `function` (a function name), `getfunction` (a whole Get call such as `Get(AccountName)` or `Hole ( Kontoname )`) or `getparameter` (the selector inside `Get ( … )` alone).
- `match_source` names where a token comes from: `canonical_en`, `display_<lang>`, `getparam_<lang>`, an engine name, or `legacy` (since fm-spec 2.10.0) — a name the function carried before Claris renamed it. The version of the rename is in [function_renames](function_renames.md).

**See also:** [functions](functions.md) · [functions_lang](functions_lang.md) · [function_renames](function_renames.md)
