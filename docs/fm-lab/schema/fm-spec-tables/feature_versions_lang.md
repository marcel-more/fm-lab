# feature_versions_lang

Part of the [FM-Lab schema](../Schema.md) · Language layer · `reference/fm_spec.duckdb` (fm-spec language reference)

The localized feature labels of [feature_versions](feature_versions.md) — ten locales (no `en`, the English text is `feature_versions.feature_en`), 540 rows = 10 × 54. The Claris pages of all locales list the features in the same order with the same version column, which is how the rows pair with their `feature_id`.

## Columns

| Column | Type |
|---|---|
| `feature_id` | `INTEGER` |
| `language` | `VARCHAR` |
| `feature_label` | `VARCHAR` |

**See also:** [feature_versions](feature_versions.md) · [error_codes_lang](error_codes_lang.md)
