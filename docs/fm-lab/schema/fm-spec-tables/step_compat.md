# step_compat

Part of the [FM-Lab schema](../Schema.md) · Emission layer · `reference/fm_spec.duckdb` (fm-spec language reference)

The platform compatibility matrix of every script step: whether it runs in Pro, on Server, in Go, WebDirect, Cloud, via the Data API and via Custom Web Publishing, plus origin and deprecation versions.

Cells that changed with FileMaker 26 (Show Custom Dialog on Go, Export Field Contents on Server and the Data API) carry a machine-readable marker at the start of `notes` — `since FM 26: <product> <supported|partial|not supported> — <Claris sentence>` — so a consumer that knows the target file's FileMaker version can gate the change while the table itself stays unversioned.

**The source is tri-state, the columns are not.** Claris documents each cell as *Yes*, *No* or *Partial*, and the BOOLEAN columns lose the third value: `true` = Yes, `false` = No, and **`NULL` = Partial — conditionally supported, see the step's notes on its Claris help page**. `NULL` never means "undocumented" and never means "compatible"; only a step missing from the table entirely would mean Claris states nothing. Consumers must preserve this distinction — reporting a Partial step as unsupported (or as fully supported) is exactly the misreading this note exists to prevent.

This table covers **script steps only**. Claris publishes no compatibility table for calculation functions; their platform relationship is curated as *affinity* in [function_platform_affinity](function_platform_affinity.md).

**Versions are compared numerically, never as text.** Claris writes the introduction version as prose — `6.0 or earlier`, `8.5`, `19.4.1`, `26.0` — and a string compare gets `8.5 > 19.0` wrong. Since fm-spec 2.9.0 the table therefore carries `originated_in_version_num`, **derived** from the text at build time in the three-part canon `major*1000000 + minor*1000 + patch` (the same key [feature_versions](feature_versions.md) uses; [script_triggers](script_triggers.md) carries the older two-part `since_version_num`, which `* 1000` lifts into this canon). `6.0 or earlier` becomes `6000000` — a floor, not an exact statement — and a step without a documented version keeps `NULL` in both columns: no published statement is not "old". Two build guards keep the pair honest: the version spelling must match a closed vocabulary (a new Claris wording fails the build instead of silently producing a wrong floor), and the key must equal the recomputation from its text. This table is the canonical version home of a step — `script_steps.origin_version` is a backfilled copy and carries no key.

**Runtime axis, not OS axis.** The seven columns name FileMaker *runtimes* — they say nothing about operating systems. That the "Pro" environment splits into macOS and Windows (where *Perform AppleScript* and *Send DDE Execute* behave in opposite ways) is the subject of the separate OS layer: [step_os_affinity](step_os_affinity.md) carries the curated per-OS statements, and [runtime_os_matrix](runtime_os_matrix.md) is the only sanctioned bridge between the two axes.

## Columns

| Column | Type |
|---|---|
| `step_id` | `INTEGER` |
| `originated_in_version` | `VARCHAR` |
| `originated_in_version_num` | `INTEGER` |
| `deprecated_in` | `VARCHAR` |
| `pro` | `BOOLEAN` |
| `server` | `BOOLEAN` |
| `go` | `BOOLEAN` |
| `webdirect` | `BOOLEAN` |
| `cloud` | `BOOLEAN` |
| `dataapi` | `BOOLEAN` |
| `cwp` | `BOOLEAN` |

**See also:** [script_steps](script_steps.md) · [function_platform_affinity](function_platform_affinity.md) · [step_os_affinity](step_os_affinity.md) · [runtime_os_matrix](runtime_os_matrix.md)
