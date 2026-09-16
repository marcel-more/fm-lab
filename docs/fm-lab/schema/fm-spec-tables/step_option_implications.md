# step_option_implications

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Parse-side option implications of the canonical text notation (since schema 1.17.0): a few very common steps leave an option implicit in their text form — a keyword, a reference form, a mode switch or the mere presence of another option implies its value. Since schema 2.1.0 the table also carries lint-side couplings: a flag or mode that is worthless without its counterpart option, because FileMaker drops it silently on paste. These rows make the implication machine-readable; the parsing and lint machinery in a consumer stays generic.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `trigger_kind` | `VARCHAR` |
| `trigger` | `VARCHAR` |
| `implied_option` | `VARCHAR` |
| `implied_value` | `VARCHAR` |
| `is_default` | `BOOLEAN` |
| `direction` | `VARCHAR` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |

## Notes

- `trigger_kind` vocabulary: `option_present` — the trigger option being set implies the value (Pause/Resume Script 62: a duration calc implies `pause_time='ForDuration'`). `value_form` — a parsed option holding a reference of the trigger's notation form implies the value (Go to Layout 6: a `"Name" (TO)` layout ref implies `destination='SelectedLayout'`). `keyword` — a bare parameter equal to the trigger (label-normalized) is consumed and implies the value (6: `Original Layout`). `mode_switch` — the trigger is the `Label: value` form of a notation-only switch; the matching row's `implied_option` names the option that unlabeled positional parameters bind to (Perform Script 1: `Specified: By name` binds the bare parameter to `script_name_calc` instead of `script`). `requires_option` (since 2.1.0) — the trigger is an `option_key` (a set flag or option) or `option_key: xml_value` (an enum holding exactly that value); `implied_option` names the option that must be set as well, `implied_value` stays empty (Print PDF 242: the `Save print options to` / `Use print options from` / `Password` flags require their target, source or password calculation; Append PDF 244 and Open PDF 246: `from: Target` requires `source_container`; Close PDF 245: `save_to: Target` requires `target_container`).
- `is_default` marks the `mode_switch` row whose mode applies when the switch label is absent — the FileMaker dialog default (`Specified: From list`); exactly one default per step (build guard).
- `direction` is `parse` for every parse-side kind: implications restore state a canonical rendering leaves implicit. The render direction stays encoded in the enum display texts of [step_option_values](step_option_values.md) (placeholder-suppressed states), so both directions round-trip. `requires_option` rows carry `direction = 'lint'`: a consumer reports the missing counterpart (fm-generate-script lint rule L009, an error that stops the pipeline) and never restores or emits anything from them.
- The post-parse kinds (`option_present`, `value_form`) never override an explicitly written option value.
- 8 parse-side rows across 6 steps (1, 6, 39, 62, 214, 220), evidence `roundtrip` at 22.0.6; 6 lint-side rows across 4 steps (242, 244, 245, 246), evidence `paired` at 26.0.2 — every set flag in the FileMaker 26 clipboard corpus carries its counterpart, no counterexample.
- The consumer build ships **without** the curation `notes` column — prose rationale stays in the fm-spec working copy.

**See also:** [step_options](step_options.md) · [step_option_values](step_option_values.md) · [step_option_element_bindings](step_option_element_bindings.md) · [step_xml_map](step_xml_map.md)
