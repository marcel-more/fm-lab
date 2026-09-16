# constraint_kinds

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Registry of the [step_constraints](step_constraints.md) kind vocabulary (since schema 1.17.0). One row per `constraint_kind` in use — a build guard keeps the registry complete — with an optional `consumer_note`: the epistemic lead text a consumer appends when surfacing a constraint of that kind on the decompile side.

## Columns

| Column | Type |
|---|---|
| `constraint_kind` | `VARCHAR` |
| `consumer_note` | `VARCHAR` |

## Notes

- Only the epistemic kinds carry a `consumer_note`: the bug-registry kinds `clipboard_loss` ("an empty slot here does not prove it was never set"), `serialization_unstable` ("values shown are display-only, the block is opaque"), `paste_validator_warning`, and since fm-spec 2.7.0 the export-gap kind `saxml_omission` ("the SaXML export never carries this slot — a catalog built from the export cannot show it, only a clipboard copy does"). Structural kinds have `NULL` — they are validity rules, not epistemic warnings.
- 12 rows, mirroring the kind vocabulary documented in [step_constraints](step_constraints.md).
- The consumer build ships **without** the curation `notes` column — prose rationale stays in the fm-spec working copy.

**See also:** [step_constraints](step_constraints.md)
