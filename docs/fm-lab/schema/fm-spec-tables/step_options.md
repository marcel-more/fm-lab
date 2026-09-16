# step_options

Part of the [FM-Lab schema](../Schema.md) · Canonical core · `reference/fm_spec.duckdb` (fm-spec language reference)

The option grammar of every script step: one row per step × option with the option key, its value type, whether it is required, where and how it is displayed (label, boolean true/false texts, inverted-label and omit-when-false rules) and the XML path it serializes to. This is what makes deterministic linting of generated steps possible — "is this option allowed here, and is its value legal?" is a table lookup.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `option_key` | `VARCHAR` |
| `option_type` | `VARCHAR` |
| `required` | `BOOLEAN` |
| `display_location` | `VARCHAR` |
| `display_label_en` | `VARCHAR` |
| `true_text` | `VARCHAR` |
| `false_text` | `VARCHAR` |
| `omit_when_false` | `BOOLEAN` |
| `inverted_label` | `BOOLEAN` |
| `xml_path` | `VARCHAR` |
| `sort_order` | `INTEGER` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |
| `slot_kind` | `VARCHAR` |
| `xml_true` | `VARCHAR` |
| `xml_false` | `VARCHAR` |
| `paste_dropped` | `BOOLEAN` |
| `coverage` | `VARCHAR` |

## Notes

- Enumerated options list their allowed values in [step_option_values](step_option_values.md).
- `evidence` and `verified_version` mark each row as verified fact vs. documented assumption.
- `slot_kind` (since fm-spec 2.2.0, target-typed options only) names the value form of that one target slot: `field_only`, `field_or_var` or `variable_only`; NULL means the option is not classified on its own and consumers fall back to the step-level `target_slot_kind` of [step_xml_map](step_xml_map.md). `variable_only` is the case the step aggregate cannot express — a slot written as element text for which FileMaker offers no field picker and takes a pasted field name over as a variable name without a diagnostic (Save Message History To). Code generators refuse a field reference there before emission.
- `xml_true` / `xml_false` (since fm-spec 2.2.0, boolean options only) name the spellings FileMaker writes for the two states when they are not `True`/`False` — NULL means the default pair. The window-style attributes of *Go to Related Record* and *New Window* carry `Yes`/`No`; localized builds write their own language there, which [step_constraints](step_constraints.md) registers as a localized-build defect so readers normalize before comparing.
- `paste_dropped` (since fm-spec 2.6.0) marks an option FileMaker discards on paste whatever its value — it has no persistence in the paired coverages. The one case so far is the `appearance` attribute of *Save Records as PDF*: no SaXML parameter carries it, the coverage corpus never shows it, and a paste probe stripped `AsFormatted` and `WithBoxes` alike. Consumers warn when a draft sets such an option, never emit it, and treat its absence as explained; the template placeholder stays so snippets from other sources remain readable.
- `coverage` (since fm-spec 2.0.0) marks a row as the standard shape (`*`) or as an override for one FileMaker coverage (for example `26`); a consumer resolving a target coverage prefers the override row of the same key and falls back to `*`.

**See also:** [script_steps](script_steps.md) · [step_option_values](step_option_values.md) · [step_xml_map](step_xml_map.md) · [step_mirror_elements](step_mirror_elements.md)
