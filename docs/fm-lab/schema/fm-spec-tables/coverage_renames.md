# coverage_renames

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

Spelling and wrapping deltas of a shape coverage relative to the base shape (since fm-spec 2.7.0): element tags a FileMaker version spells differently, element values renamed with them, and the one case where a version wraps the base's mixed-content text in a child element. Read direction only — a consumer translates a snippet of that coverage to the base spelling before matching the base templates; the emitter writes the shape of its target coverage, whose templates already carry the coverage spelling.

## Columns

| Column | Type |
|---|---|
| `coverage` | `VARCHAR` |
| `step_id` | `INTEGER` |
| `rename_kind` | `VARCHAR` |
| `path` | `VARCHAR` |
| `coverage_name` | `VARCHAR` |
| `base_name` | `VARCHAR` |
| `sort_order` | `INTEGER` |
| `evidence` | `VARCHAR` |
| `verified_version` | `VARCHAR` |

## Notes

- `rename_kind` is `element` (a tag: `path` names the parent element in base spelling, `.` = the step itself), `text` (an element value: `path` names the element) or `text_hoist` (the coverage writes the base's element text as a child element named `coverage_name`; `base_name` is empty by definition).
- `sort_order` orders the rows of one step so a parent rename precedes the renames underneath it; `path` is always the base spelling.
- Rows exist only for non-base coverages and are bound to the paired build of that coverage. Build guards check every spelling against the templates of both coverages (`element`, `text_hoist`) or the declared enum values of both coverages (`text`).
- Current rows (FileMaker 26): `Configure AI Account` (212) `SetLLMAccount`/`AccountName` for the base's misspelled `SetLLMAccout`/`AccoutName`, `Configure Prompt Template` (226) `RAGPrompt` for `RAGPPrompt` and the value `RAGPromptRequest` for `RAGPrompt`, and `Configure Machine Learning Model` (202) whose operation moved into an `Operation` child. The code generator's read tolerance reads these rows and keeps its former constants only as a fallback for older references.

**See also:** [Coverage resolution](../Coverage%20resolution.md) · [coverages](coverages.md) · [coverage_step_rules](coverage_step_rules.md) · [step_xml_map](step_xml_map.md) · [step_constraints](step_constraints.md)
