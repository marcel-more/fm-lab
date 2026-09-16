# reference_meta

Part of the [FM-Lab schema](../Schema.md) · Metadata · `reference/fm_spec.duckdb` (fm-spec language reference)

The build stamp of the shipped reference as key/value pairs: schema version, the two coverages, build timestamp, source commit, build variant and the pointer to the attribution file (`SOURCES.md`).

Since schema 1.19.0 the stamp separates two kinds of coverage. `filemaker_coverage` (currently 22) is the **base shape coverage** — the FileMaker version whose paired export/clipboard evidence the standard XML grammar is verified against; since schema 2.0.0 `shape_coverages` lists every shape coverage the build carries (`22,26`), and the [coverages](coverages.md) table describes each one (paired FileMaker version, SaXML version, base flag) — see [Coverage resolution](../Coverage%20resolution.md). `doc_coverage` (currently 26) is the **documentation coverage** — the Claris help version behind names, categories, compatibility, one-liners, option prose and signatures; `doc_help_build` records the help build date and `doc_source` the mirror kind. The documentation layer is unversioned and describes FileMaker as documented today, so a step can be documented for 26 while its XML shape is verified for 22.

## Columns

| Column | Type |
|---|---|
| `key` | `VARCHAR` |
| `value` | `VARCHAR` |

**See also:** [script_steps](script_steps.md) · [functions](functions.md) · [coverages](coverages.md) · [Coverage resolution](../Coverage%20resolution.md)
