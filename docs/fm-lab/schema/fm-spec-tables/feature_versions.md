# feature_versions

Part of the [FM-Lab schema](../Schema.md) · Runtime & diagnostics · `reference/fm_spec.duckdb` (fm-spec language reference)

"FileMaker features not compatible with previous versions" as data: the version each listed feature was introduced in, 54 rows from the Claris reference page — popovers and slide controls (13), button bars (14), card windows (16), layout calculations (20.2.1), table comments (22.0.1), field display names and annotations (26.0.1). The feature names are Claris prose (emphasis markup removed), which makes the table a reading reference, not a detection rule set; `feature_key` is the sparse, curated machine key a consumer detection rule would bind to (all NULL in the first build — the keys are consumer curation, not Claris data).

`feature_id` is **stable**: assigned in the order of the English table at the first build and never renumbered — a later documentation update appends new rows with the next id. `version_num` is a **three-part** numeric key, `major × 1 000 000 + minor × 1 000 + patch` (`22.0.4` → 22 000 004, `26.0.1` → 26 000 001), because Claris names patch levels here; it is not the two-part key of [script_triggers](script_triggers.md) (`since_version_num`). Version comparisons never run on the string.

## Columns

| Column | Type |
|---|---|
| `feature_id` | `INTEGER` |
| `feature_en` | `VARCHAR` |
| `version_introduced` | `VARCHAR` |
| `version_num` | `INTEGER` |
| `feature_key` | `VARCHAR` |

**See also:** [feature_versions_lang](feature_versions_lang.md) · [script_steps](script_steps.md) · [script_triggers](script_triggers.md) · [error_codes](error_codes.md)
