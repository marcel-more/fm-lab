# error_codes_lang

Part of the [FM-Lab schema](../Schema.md) · Language layer · `reference/fm_spec.duckdb` (fm-spec language reference)

The localized messages of the [error_codes](error_codes.md) — ten locales (`de`, `es`, `fr`, `it`, `nl`, `pt`, `sv`, `ja`, `ko`, `zh-Hans`; **no `en`**, the English text is `error_codes.message_en`), keyed by the span start `code_from`. Every locale covers every code (2940 rows = 10 × 294); the build refuses a locale that covers less than 90 % of the codes.

## Columns

| Column | Type |
|---|---|
| `code_from` | `INTEGER` |
| `language` | `VARCHAR` |
| `message` | `VARCHAR` |

**See also:** [error_codes](error_codes.md) · [script_steps_lang](script_steps_lang.md)
