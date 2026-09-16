# step_option_values

Part of the [FM-Lab schema](../Schema.md) · Canonical core · `reference/fm_spec.duckdb` (fm-spec language reference)

The allowed values of enumerated step options: one row per step × option × value with the exact XML value and its English display text.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `option_key` | `VARCHAR` |
| `xml_value` | `VARCHAR` |
| `display_text_en` | `VARCHAR` |
| `evidence` | `VARCHAR` |
| `coverage` | `VARCHAR` |

- `coverage` (since fm-spec 2.0.0) marks a row as the standard shape (`*`) or as an override/addition of one FileMaker coverage (`26`); a consumer resolving a target coverage prefers the row of that coverage with the same key and falls back to `*` — rule and keys on [Coverage resolution](../Coverage%20resolution.md).
- Enum values of the target coverage come first in a resolved view, so a display text shared by two XML values (Configure Prompt Template `RAGPrompt` / `RAGPromptRequest`) resolves to the coverage-specific value on the write side while both stay readable.

**See also:** [Coverage resolution](../Coverage%20resolution.md) · [step_options](step_options.md)
