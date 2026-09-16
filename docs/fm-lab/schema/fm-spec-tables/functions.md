# functions

Part of the [FM-Lab schema](../Schema.md) · Canonical core · `reference/fm_spec.duckdb` (fm-spec language reference)

The canonical identity of all 375 calculation functions (368 documented by Claris, 7 engine-only): stable `function_id`, internal `opcode`, English `canonical_name`, return type, category and origin version, plus the flag marking `Get(…)` functions.

## Columns

| Column | Type |
|---|---|
| `function_id` | `INTEGER` |
| `opcode` | `VARCHAR` |
| `category_id` | `INTEGER` |
| `english_id` | `VARCHAR` |
| `canonical_name` | `VARCHAR` |
| `return_type` | `VARCHAR` |
| `origin_version` | `VARCHAR` |
| `origin_version_num` | `INTEGER` |
| `is_get_function` | `INTEGER` |
| `url_slug` | `VARCHAR` |
| `source_version` | `VARCHAR` |
| `fetched_at` | `DATE` |
| `removed_in_version` | `VARCHAR` |

## Notes

- `origin_version_num` (since fm-spec 2.9.0) is the numeric comparison key of `origin_version`, derived at build time in the same three-part canon as [step_compat](step_compat.md) (`major*1000000 + minor*1000 + patch`). Five functions carry no documented version and keep `NULL` in both columns.
- `removed_in_version` (since fm-spec 2.2.0) is the first FileMaker version that no longer resolves the function — the counterpart of `origin_version` for version gates in both directions. NULL means the function still exists in the documented version. Two engine-only functions carry it: `SetPersistentData` and `FindPersistentData` (accepted by FileMaker 22, written as *function missing* by FileMaker 26, replaced by the *Configure Persistent Data* step and `ListPersistentDataIDs`).

**See also:** [functions_lang](functions_lang.md) · [function_parameters](function_parameters.md) · [function_categories](function_categories.md) · [function_platform_affinity](function_platform_affinity.md)
