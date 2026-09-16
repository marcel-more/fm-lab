# coverages

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

The vocabulary of shape coverages the build carries (since fm-spec 2.0.0): one row per FileMaker version whose paired export and clipboard evidence the XML grammar is verified against, with the exact FileMaker build the pairing was done on and the SaXML version that build exports. Exactly one row is the **base** — the coverage the standard rows (`coverage = '*'`) of the six shape tables describe; every other coverage exists as sparse override/addition rows. The shipped build carries `22` (base, paired 22.0.6, SaXML 2.2.3.0) and `26` (paired 26.0.2, SaXML 2.3.0.0).

## Columns

| Column | Type |
|---|---|
| `coverage` | `VARCHAR` |
| `paired_version` | `VARCHAR` |
| `saxml_version` | `VARCHAR` |
| `is_base` | `BOOLEAN` |

## Notes

- `coverage` is the FileMaker major version as a string (`22`, `26`) and the value the `coverage` column of the shape tables refers to; `*` never appears here.
- `paired_version` is the FileMaker build whose export and clipboard output every step instance of the coverage solution was paired against; `saxml_version` the `SaveCopyAsXML` format that build writes (`2.2.3.0` for FileMaker 22, `2.3.0.0` for FileMaker 26).
- Consumers read the base row to resolve a request without an explicit coverage (the REST grammar endpoint, the code generator's `--coverage` default from the target file's `FileMaker_Version`); see [Coverage resolution](../Coverage%20resolution.md).

**See also:** [Coverage resolution](../Coverage%20resolution.md) · [coverage_step_rules](coverage_step_rules.md) · [reference_meta](reference_meta.md) · [step_xml_map](step_xml_map.md)
