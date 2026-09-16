# step_mirror_elements

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Value-copy rules per script step (since schema 2.6.0): places where FileMaker writes the value of one option a *second* time and keeps both copies in sync when a snippet is pasted. The lead case is Save Records as PDF (144): the document title lives at `PDFOptions/Document/Title/Calculation`, and FileMaker mirrors it as a bare `Calculation` element directly under the step. A paste probe in FileMaker 22.0.6 and 26.0.2 fixed the mechanics — a title without its mirror gets the mirror healed in, a mirror without a title gets the title healed in, and when the two diverge the title wins and the mirror is overwritten; subject, author and keywords trigger no mirror, and Save Records as Excel (143) has none at all.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `source_option` | `VARCHAR` |
| `target_path` | `VARCHAR` |
| `trigger` | `VARCHAR` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |
| `coverage` | `VARCHAR` |

## Notes

- A mirror is a value *copy*, not a value setting — which is why it is neither a row of [step_option_implications](step_option_implications.md) (those imply a fixed value) nor of [step_option_element_bindings](step_option_element_bindings.md) (those govern presence only). `source_option` names the option whose value is copied, `target_path` the element path (relative to the `Step` root) that receives the copy; the target leaf must exist in the step's snippet template (build guard).
- `trigger` has one value so far: `source_present` — the mirror exists exactly when the source option is set, and the source is the truth.
- Consumers: a generator copies the source value to the target path after substitution and never overwrites an explicitly set target; a decompiler treats the mirror as redundancy — dropped when equal to the source, read as the source when the source is absent, reported as a note when the two diverge (the source wins, as on paste). The canonical text form carries the source alone.
- The [step_options](step_options.md) row whose `xml_path` equals the target path is the *read option* of the mirror (`title_mirror` for step 144): it keeps older drafts readable but never occupies an inline slot (build guard).
- 1 standard row (144 `doc_title` → `Calculation`), `paired` at 22.0.6 and confirmed at 26.0.2.
- The consumer build ships **without** the curation `notes` column — prose rationale stays in the fm-spec working copy.
- `coverage` (since fm-spec 2.0.0) marks a row as the standard shape (`*`) or as an override/addition of one FileMaker coverage; a consumer resolving a target coverage prefers the row of that coverage with the same key (`source_option` + `target_path`) and falls back to `*` — rule and keys on [Coverage resolution](../Coverage%20resolution.md).

**See also:** [Coverage resolution](../Coverage%20resolution.md) · [step_xml_map](step_xml_map.md) · [step_options](step_options.md) · [step_option_element_bindings](step_option_element_bindings.md) · [step_skeleton_elements](step_skeleton_elements.md)
