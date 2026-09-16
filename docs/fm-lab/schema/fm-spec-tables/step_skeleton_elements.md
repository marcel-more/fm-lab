# step_skeleton_elements

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Skeleton hulls per script step (since schema 1.17.0): child elements FileMaker keeps alive even when the strict pruning rule — "an element without actual values dies" — would drop them. The classic cases are the `Security` group of Save Records as PDF and the `DialogOptions`/`FilterList` hulls of Insert File, both present in every real export including the fully unconfigured form. The XML shape itself still comes exclusively from the [step_xml_map](step_xml_map.md) template; these rows only say *which* hulls persist and under what condition.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `parent_tag` | `VARCHAR` |
| `child_tag` | `VARCHAR` |
| `condition_option` | `VARCHAR` |
| `condition_value` | `VARCHAR` |
| `keep_mode` | `VARCHAR` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |
| `coverage` | `VARCHAR` |

## Notes

- `keep_mode` has two values. `hull`: the whole subtree persists with pure default content — emitters re-instantiate it from the snippet template *after* the strict prune (defaults filled, dead children dropped). `hull_strip_children`: the hull element persists with its attributes while its unfilled placeholder children are stripped *before* substitution — Insert from Device (161) keeps empty `Title`/`Message`/`Prompt` hulls in Signature mode, `MaxDuration` keeps its state attribute without a duration calc, and `ScanFrom` carries its `Field` child only in the scan-from-field variant.
- `condition_option`/`condition_value` scope a row to one option value: the `TableAliases` hull of Perform SQL Query by Natural Language (214) persists only with `data_tables='By List'`; the Signature hulls of 161 only with `insert_from='Signature'`. Both columns are set together or not at all (build guard).
- `parent_tag` is the direct parent element (`Step` for root-level hulls); insertion order on restore follows `element_order` in [step_xml_map](step_xml_map.md).
- 29 rows across 18 steps, all `paired` at 22.0.6: 24 `hull` rows (144, 131, 210, 212–222, 225–227 — the AI family persists its option container even unconfigured) and 5 `hull_strip_children` rows (all step 161). Since 2.6.0 Save Records as PDF carries the full zero-state tree as hulls (`PDFOptions` under the step, `Document` inside it, `Pages` inside that): a snippet without PDF options is healed by FileMaker into exactly this tree, with `AllPages="False"` and the security and view defaults the template now carries — a runtime probe in 22.0.6 and 26.0.2 showed that form produces all pages with printing and copying allowed.
- The mode-scoped *presence* of the 161 hulls (which children exist in which device mode) is not encoded here but in [step_option_element_bindings](step_option_element_bindings.md) — this table only governs what survives inside a present hull.
- The decompile direction needs no rule: the template match extracts the default content and default omission removes it again.
- The consumer build ships **without** the curation `notes` column — prose rationale stays in the fm-spec working copy.

- `coverage` (since fm-spec 2.0.0) marks a row as the standard shape (`*`) or as an override/addition of one FileMaker coverage (`26`); a consumer resolving a target coverage prefers the row of that coverage with the same key and falls back to `*` — rule and keys on [Coverage resolution](../Coverage%20resolution.md).

**See also:** [Coverage resolution](../Coverage%20resolution.md) · [step_xml_map](step_xml_map.md) · [step_option_element_bindings](step_option_element_bindings.md) · [step_repeat_groups](step_repeat_groups.md)
