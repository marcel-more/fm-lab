# step_option_element_bindings

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Option-value/element couplings per script step (since schema 1.17.0): elements of the snippet template whose existence depends on the value of another option. The lead case is Insert from Device (161), where the children of `DeviceOptions` are bound to the source mode — a Signature capture carries `Title`/`Message`/`Prompt`/`Presentation`, a Barcode scan carries `ScanFrom`/`Barcodes`/`Camera`/`Resolution`, and the two library modes carry no device options at all.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `option_key` | `VARCHAR` |
| `option_value` | `VARCHAR` |
| `element_path` | `VARCHAR` |
| `binding` | `VARCHAR` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |
| `coverage` | `VARCHAR` |

## Notes

- `binding` vocabulary: `requires` — the element exists only at the listed option value; several rows for the same (option, element) form the allowed-value set, and an unset option never satisfies a requires binding. `excludes` — the element is dropped at the listed value (Fine-Tune Model 213 drops `Table` with `data_source='TrainingFile'`). `requires_option` / `excludes_option` — the condition is the option being set at all, `option_value` stays `NULL` (Barcode with a scan-from field drops `Camera`/`Resolution`). `suppress_empty` — deterministic emission never writes the (empty) template element; decompilation tolerates a present one via the template (the `Text` residue of Configure Region Monitor Script 185). 
- Emitters apply bindings *before* placeholder substitution, so mode-scoped template defaults survive for the mode that keeps them and nothing leaks across modes. The decompile direction needs no rule — the template match tolerates absence of any pruned element.
- `element_path` is relative to the `Step` root (`DeviceOptions/Camera`). Since 2.5.0 it may also name the n-th same-named child (`Field[2]` — Configure Machine Learning Model drops the trailing field in the Uninstall form) or an attribute (`SerialNumbers/@increment` — Replace Field Contents drops `increment` and `InitialValue` once the field's entry options are used); a generator treats those exactly like an element: pruned before substitution, and the prune explains the absence for the option-preservation gate.
- 58 standard rows plus 13 FileMaker 26 override rows across 23 steps, all `paired` (22.0.6, the 26 rows at 26.0.2); the 161 mode matrix is one `requires` row per mode × child plus one per mode for `DeviceOptions` itself.
- What survives *inside* a present hull (161's empty Signature hulls, `MaxDuration` without a calc) is governed by [step_skeleton_elements](step_skeleton_elements.md) `keep_mode='hull_strip_children'`.
- The consumer build ships **without** the curation `notes` column — prose rationale stays in the fm-spec working copy.

- `coverage` (since fm-spec 2.0.0) marks a row as the standard shape (`*`) or as an override/addition of one FileMaker coverage (`26`); a consumer resolving a target coverage prefers the row of that coverage with the same key and falls back to `*` — rule and keys on [Coverage resolution](../Coverage%20resolution.md).

**See also:** [Coverage resolution](../Coverage%20resolution.md) · [step_xml_map](step_xml_map.md) · [step_options](step_options.md) · [step_option_values](step_option_values.md) · [step_skeleton_elements](step_skeleton_elements.md) · [step_mirror_elements](step_mirror_elements.md)
