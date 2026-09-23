# SCA Metadata Integrity

**Rubric:** [Static Code Analysis (neighboring rubric)](../Wiki/Static%20Code%20Analysis.md) · 5 rules · `rest-api/templates/dashboards-custom/metadata-integrity/`

Metadata-integrity rules check the invisible layer of the FileMaker file format: the native UUIDs every object carries, and what the XML export did or did not carry over. Duplicate UUIDs never affect runtime behavior — FileMaker itself doesn't care — but they quietly break every tool that assumes UUID uniqueness: DDR analyzers, fmIDE, diff/merge tooling, and FM-Lab's own reference resolution. Export artifacts are the second family: a file saved without DDR info or with a plug-in not loaded on the exporting client imports without error and looks complete, yet its formula references (fields, functions, custom functions, plug-in calls) never reach the catalog. FM-Lab detects and lists these defects; it deliberately does **not** repair them (Claris' repair mode assigns entirely new UUIDs and breaks external references; the export defects are only fixed by exporting again).

## When to use it

- Solutions with a cloning history — files copied from a template file, or objects pasted between clones, are where cross-file UUID collisions come from.
- When developer tooling behaves oddly on one file (wrong objects linked, references jumping) while FileMaker itself is fine.
- Before relying on UUID-based workflows (sync frameworks, external documentation tools, FM-Lab cross-file analysis).
- After importing a solution you did not export yourself, when plug-in references, where-used results or the docs counters look suspiciously empty — the three export rules tell you whether the export, not the analysis, is the gap.

## Reading the results

The two UUID rules are `warning` — real defects for tooling, invisible in production. **Clone collisions** are the cross-file case: the same UUID existing in more than one file of the solution. **Intra-file duplicates** are the export-defect case: a UUID assigned twice within one file, typically from copy/paste with old FileMaker versions. For the intra-file case FM-Lab's importer performs *UUID healing*: every occurrence is kept, the twin with the smallest internal id retains the source UUID, and the others receive a deterministic replacement (recorded in `Healed_UUID`) — the dashboard lists the healed occurrences with their context so the catalog stays internally consistent without touching your file.

The three export rules read the same catalog from the other side. **Export without DDR info** is one finding per file whose root attribute says `Has_DDR_INFO="False"` — the *Include details for analysis tools* option was off, so the file has no DDR chunks and therefore no formula references at all; the finding counts the formulas whose references are lost. **Plug-in function missing at export** lists every formula in which FileMaker wrote `<Function Missing>` instead of a plug-in function (the plug-in was not loaded on the exporting client); it reads the formula text, so it works with and without DDR info, and keeps an excerpt of the arguments as the only remaining hint which plug-in was meant. **Plug-in call without reference** compares text against graph per formula, in files exported with DDR info only: a plug-in call in the text without a `calls_pluginfunction` link on the calculation instance, classified by cause — `dynamic-name` (`MBS($name; …)`, informational: a code style the converter cannot resolve, and the case this rule exists for) and `unresolved` (DDR info present, no usage, not dynamic — a converter blind spot worth reporting). Files without DDR info are deliberately left to the first rule — listing their calls per formula would repeat one file-level finding hundreds of times; the summary counts the excluded files. Calls inside comments are excluded. All three are also members of the [Plug-in reference integrity](../Wiki/Analysis%20Tests.md) test, together with a per-file census.

## Rules

| Rule | Severity | What it flags | Source |
|---|---|---|---|
| UUID Clone Collisions | warning | Native UUIDs existing in more than one file of the solution | fm-lab |
| UUID Intra-File Duplicates | warning | UUIDs assigned twice within a single file, with the healed replacement mapping | fm-lab |
| Export without DDR info | warning | Files exported without *Include details for analysis tools* — no formula references exist for them in the catalog | fm-lab |
| Plug-in function missing at export | warning | Formulas in which FileMaker replaced a plug-in function by `<Function Missing>` at export time (plug-in not loaded on the exporting client) | fm-lab |
| Plug-in call without reference | info / warning | Formulas in files with DDR info whose text calls a plug-in while the catalog holds no plug-in reference for that formula — dynamic function name (info) or unresolved pairing (warning) | fm-lab |

## See also

- [Static Code Analysis](../Wiki/Static%20Code%20Analysis.md) — the rubric overview
- [UUID Healing and Duplicate Census](../schema/UUID%20Healing%20and%20Duplicate%20Census.md) — how the importer handles duplicates in detail
- [ObjectCatalog](../schema/object-catalog/ObjectCatalog.md) — where object identity lives in the catalog
- [XML DDR_INFO](../xml/catalogs/XML%20DDR_INFO.md) — the chunk stream the export rules depend on
- [Analysis Tests](../Wiki/Analysis%20Tests.md) — the *Plug-in reference integrity* set that bundles the three export rules with a per-file census
