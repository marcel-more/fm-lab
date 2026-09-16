# step_constraints

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Structural rules a valid snippet must satisfy beyond per-option typing — e.g. steps that must appear as balanced pairs or only inside a certain block. Each constraint carries its kind, a detail description and evidence.

Since schema 1.14.4 the table doubles as a **bug registry**: documented FileMaker serialization defects (clipboard drops, version skew, save-time corruption) are recorded as constraint rows with their own kinds. Registry entries are a *warning class, never a validity rule* — the affected steps are valid; the risk lies in FileMaker's own serialization, so consumers surface them as notes/warnings, never as errors.

## Constraint kinds

Structural (validity rules):

- `requires_pair` — step is only valid as part of a balanced pair
- `requires_parent` — step is only valid inside a certain block
- `save_invalid_bare` / `save_invalid_nesting` — FileMaker rejects the construct on save
- `silent_failure_pattern` — construct saves but fails silently at runtime

Bug registry (warning class, since 1.14.4):

- `clipboard_loss` — FileMaker drops a slot on copy; an empty slot in pasted XML does not prove it was never set
- `version_skew` — serialization differs between FileMaker versions
- `save_corruption` — FileMaker corrupts the construct on save
- `serialization_unstable` — values shown are display-only, the block is opaque
- `localized_build_defect` — defect only in specific localized builds

Registry evidence is `external-report`, or `paired` where the defect has been reproduced and measured (step 221).

Export gap (since fm-spec 2.7.0, informational class):

- `saxml_omission` — a slot the SaXML export never carries, so a catalog built from the export cannot show it; only a clipboard copy does. Not a defect of the snippet — the clipboard form is complete. Rows are scoped by `coverage`: the XSLT stylesheet of an XML export (`Export Records`, FileMaker 22 export only), the *automatically open* / *create e-mail* flags of `Export Records`, `Save Records as PDF` and `Close PDF`, the zoom formula of `Set Zoom Level`, the `Option` flag of `Insert Embedding` (FileMaker 26). Evidence is always `paired` (clipboard against the SaXML export of the same step).

Since schema 1.17.0 the kind vocabulary itself is registered in [constraint_kinds](constraint_kinds.md), which also carries the consumer-facing lead text of the bug-registry kinds.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `constraint_kind` | `VARCHAR` |
| `detail` | `VARCHAR` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |
| `coverage` | `VARCHAR` |

`coverage` (since fm-spec 2.7.0) is `*` for a constraint that holds in every coverage and a coverage id where the row speaks about that coverage's serialization only — the `saxml_omission` rows; the primary key is step, kind and coverage. Layout-object export gaps (the portal sort order FileMaker 22 omitted, the field-entry formula `CanEntryCalc`) are outside the step reference and recorded in fm-lab's SaXML shape baseline instead.

`detail` is a payload column and carries the finding, the consumer doctrine and neutral version facts only; curation provenance lives in a source-side `notes` column that — like every curation column — is stripped from the consumer build (since schema 1.16.1, enforced by a build-time payload-hygiene guard).

**See also:** [constraint_kinds](constraint_kinds.md) · [coverage_renames](coverage_renames.md) · [step_xml_map](step_xml_map.md) · [step_options](step_options.md)
