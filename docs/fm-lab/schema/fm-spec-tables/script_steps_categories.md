# script_steps_categories

Part of the [FM-Lab schema](../Schema.md) · Canonical core · `reference/fm_spec.duckdb` (fm-spec language reference)

The 14 script-step categories (Control, Navigation, Records, Windows, Files, …, PDF files) with their English names and documentation URL slugs. `category_id` is a stable key — the PDF files category added with FileMaker 26 carries id 14 regardless of its position in the Claris table of contents, so consumers sort by id and never renumber.

## Columns

| Column | Type |
|---|---|
| `category_id` | `INTEGER` |
| `category_name_en` | `VARCHAR` |
| `url_slug` | `VARCHAR` |

**See also:** [script_steps](script_steps.md) · [script_steps_categories_lang](script_steps_categories_lang.md)
