# coverage_step_rules

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Reading rules per shape coverage (since fm-spec 2.0.0) for the step-level elements a FileMaker version writes on **every** step without them being an option: editor **chrome** that carries no information and is dropped before a template match, and editor **state** that is dropped for the match but reported, because no emitter writes it back. FileMaker 26 writes `<DisableStepCollapsed state="False"/>` on every step and `<Restore state="False"/>` on comment steps (chrome); a collapsed disabled block (`DisableStepCollapsed state="True"`) and `<HiddenStepsCount>` are state.

## Columns

| Column | Type |
|---|---|
| `coverage` | `VARCHAR` |
| `rule_kind` | `VARCHAR` |
| `step_ids` | `VARCHAR` |
| `element` | `VARCHAR` |
| `attrs` | `VARCHAR` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |

## Notes

- `rule_kind` is `chrome` (drop silently, note it) or `state` (drop for the match, report it — the information is not carried).
- `step_ids` restricts a rule to a comma-separated list of step ids; NULL means every step. `attrs` is a JSON object of the attribute values the element must carry for the rule to apply (a `DisableStepCollapsed` with `state="True"` is state, not chrome).
- The code generator's decompiler applies these rules before matching a snippet against the templates of the target coverage; a snippet copied from FileMaker 22 matches nothing here and passes through unchanged.

**See also:** [Coverage resolution](../Coverage%20resolution.md) · [coverages](coverages.md) · [coverage_renames](coverage_renames.md) · [step_xml_map](step_xml_map.md)
