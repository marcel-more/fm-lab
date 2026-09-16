# Coverage resolution

Part of the [FM-Lab schema](Schema.md) · `reference/fm_spec.duckdb` ([fm-spec](../Wiki/fm-spec.md) language reference) · since fm-spec 2.0.0

FileMaker 22 and FileMaker 26 write different clipboard forms for some script steps — renamed elements, new options, a calculated zoom, the print and PDF steps. fm-spec stores the XML grammar **once** and describes such differences as **sparse overrides** instead of a second copy of the reference. This page states the rule every consumer applies; the vocabulary lives in [coverages](fm-spec-tables/coverages.md), the version-specific reading rules for editor chrome in [coverage_step_rules](fm-spec-tables/coverage_step_rules.md).

## The model

The seven shape tables — [step_xml_map](fm-spec-tables/step_xml_map.md) (template, element order, SaXML types), [step_options](fm-spec-tables/step_options.md), [step_option_values](fm-spec-tables/step_option_values.md), [step_repeat_groups](fm-spec-tables/step_repeat_groups.md), [step_skeleton_elements](fm-spec-tables/step_skeleton_elements.md), [step_option_element_bindings](fm-spec-tables/step_option_element_bindings.md) and, since 2.6.0, [step_mirror_elements](fm-spec-tables/step_mirror_elements.md) — carry a `coverage` column:

- `*` — the **standard row**, valid for every coverage unless overridden. The standard rows describe the base coverage ([coverages](fm-spec-tables/coverages.md) `is_base`, FileMaker 22 in the shipped build).
- `26` — an **override or addition** for that one coverage: a row that exists only there (a new option, a new enum value, a new binding) or a row that replaces the standard row of the same key (a template with a renamed element, an option whose XML path moved).

A row's identity is its key within the step: the step itself for [step_xml_map](fm-spec-tables/step_xml_map.md); `option_key` for [step_options](fm-spec-tables/step_options.md); `option_key` + `xml_value` for [step_option_values](fm-spec-tables/step_option_values.md); `group_key` for [step_repeat_groups](fm-spec-tables/step_repeat_groups.md); `parent_tag` + `child_tag` + condition for [step_skeleton_elements](fm-spec-tables/step_skeleton_elements.md); `option_key` + `option_value` + `element_path` + `binding` for [step_option_element_bindings](fm-spec-tables/step_option_element_bindings.md); `source_option` + `target_path` for [step_mirror_elements](fm-spec-tables/step_mirror_elements.md). Rows of the tables without a `coverage` column (constraints, implications, platform data, lookups) are version-neutral.

## The rule

A consumer resolves against exactly **one target coverage**:

1. read the standard rows (`coverage = '*'`) **and** the rows of the target coverage;
2. per table and key, a target row **replaces** the standard row of the same key;
3. a key that has only a standard row keeps it — no target row never means "not modelled", it means "unchanged";
4. additions (rows that exist only in the target) are unioned in; among enum values the target rows come **first**, so a display text shared by two XML values resolves to the coverage-specific value on the write side while both values stay readable;
5. rows of other coverages are ignored.

A reference build without the `coverage` column (before 2.0.0) consists of standard rows only and resolves to them for any target.

## How the target is chosen

- **Code generation** (`fm-generate-script`): an explicit `--coverage 22|26` wins; otherwise the `FileMaker_Version` of the target file in the solution catalog decides (22.x → 22, 26.x → 26). A target file the catalog does not know has no version, and the pipeline stops instead of guessing. The IR and the gate protocol record the coverage and how it was chosen.
- **REST** (`GET /api/reference/steps/:id/grammar?coverage=26`): the parameter selects the coverage, omitted means the base; the response names the resolved coverage, its source (`query` or `base`), the reference's coverages and the coverages that carry override rows for that step, and every row states whether it is a standard or an override row.
- **Schema viewer**: the grammar block of a step can be switched between the coverages; override rows are tagged with their coverage.
- **Quality test** T7-02 (SaXML signature drift) compares a catalog against the signature of *its* coverage, derived from the FileMaker version of the imported files.

## Reading a snippet of the other coverage

The rule above is a write-side rule. Reading goes the other way: a snippet copied from FileMaker 26 into a FileMaker 22 pipeline is first stripped of the editor chrome and state [coverage_step_rules](fm-spec-tables/coverage_step_rules.md) name, then matched against the target coverage's shape; what does not match is tried against the other coverage's shape, and a value that exists only there is reported as lost for the target (FileMaker 22 drops it on paste). Nothing is dropped silently.

## Evidence

Every shape row carries `evidence` and `verified_version`. In the shipped build the standard rows of 205 steps are instance-paired at FileMaker 22.0.6 (SaXML 2.2.3.0), the ten steps FileMaker 26 introduced and the sixteen override shapes at 26.0.2 (SaXML 2.3.0.0) — the same coverage solution, exported and copied to the clipboard from both versions, roughly 1,900 step instances paired one to one per version.

**See also:** [fm-spec](../Wiki/fm-spec.md) · [coverages](fm-spec-tables/coverages.md) · [coverage_step_rules](fm-spec-tables/coverage_step_rules.md) · [reference_meta](fm-spec-tables/reference_meta.md) · [Skill fm-generate-script](../skills/Skill%20fm-generate-script.md)
