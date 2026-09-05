# Skill: convert-xml

Converts FileMaker XML exports (SaXML) into the DuckDB object catalog of the active solution — one file or the whole inbox — by running the complete ingestion pipeline with encoding detection, schema checks and automatic recovery.

| | |
|---|---|
| **Category** | Ingestion |
| **Slash command** | `/convert-xml "<file>.xml"` · `/convert-xml --batch [options]` |
| **Say it naturally** | "convert the XML", "import the FileMaker XML", "batch import all XML files" — understood in 11 languages |
| **Input** | the name of one XML file in the solution inbox, or `--batch` for every file in it |
| **Reads** | `solutions/<id>/xml/*.xml`, the SQL templates under `ingestion/sql/` |
| **Writes** | the master catalog `solutions/<id>/db/fm_catalog.duckdb`, run state and lock under `solutions/<id>/state/`, logs under `logs/`, and — after success — the REST API's read copy |
| **Prerequisites** | DuckDB CLI on the PATH; a SaXML export from FileMaker 19 or later; a solution bundle (the default one exists after installation) |
| **Under the hood** | `ingestion/convert_fm_xml.sh` — the same script the web client's XML-conversion button runs |
| **Skill directory** | `.claude/skills/convert-xml/` |
| **Related** | [Skill test-convert-xml](Skill%20test-convert-xml.md) · [Skill select-solution](Skill%20select-solution.md) · [Skill fm-graph-cluster](Skill%20fm-graph-cluster.md) |

## What it does

The skill is the agent-side entry to the [ingestion pipeline](../templates/Ingestion%20Pipeline%20%28XML%20Import%29.md). For every file it detects the encoding (UTF-16 exports are converted to UTF-8 in a temporary location; the original is never modified), prepares the SQL templates with the right paths, runs the phases of the [Katana engine](../Wiki/katana-engine.md) — extraction, reference resolution, detail tables, the universal object catalog, analysis views, validation and automatic graph clustering — and cleans up after itself. The XML is read exactly once; afterwards every analysis works on the catalog alone.

Batch mode processes the whole inbox, continues past individual failures, builds the cross-file catalogs at the end and writes a summary with per-file timings. Single-file mode adds or refreshes one file in an existing catalog (upsert semantics) and is the quick path after re-exporting a single file.

## How to use it

```
/convert-xml "Invoices.xml"                    # one file from solutions/<id>/xml/
/convert-xml --batch                           # every file in the inbox
/convert-xml --batch --fail-fast               # stop at the first error (debugging)
/convert-xml --batch --force-rebuild           # drop the catalog and rebuild from scratch
/convert-xml --batch --force-rebuild --jobs auto   # fastest full rebuild on a multi-core machine
/convert-xml --batch --solution acme           # import another solution bundle
```

Or simply ask: *"import all XML files"*, *"konvertiere die XML"*. The agent picks the mode from the request and reports the script's outcome.

## Options

| Option | Effect |
|---|---|
| `--batch` / `--all` | Process every `.xml` file in the inbox |
| `--fail-fast` | Stop at the first failing file (batch and test mode) |
| `--force-rebuild` | Delete the catalog first and rebuild from scratch |
| `--no-auto-heal` | On detected schema drift, abort instead of rebuilding automatically |
| `--turbo` | Chunked Phase 1 (the default engine); combine with `--auto` for out-of-memory backoff and `--changed-only` to skip files unchanged since the last run |
| `--streamify` | SAX streaming hybrid with lower parse memory (default when the patched webbed extension is present) |
| `--split` | Chunk Phase 1 per file at top-level branch boundaries — lowers peak memory for very large files; not combinable with `--jobs` |
| `--jobs <N>` / `--jobs auto` | Run Phase 1 for N files in parallel, each into its own part database, then merge; results are identical to the sequential run |
| `--solution <id>` | Target a specific solution bundle instead of the active one |
| `--quiet` | NDJSON output for the REST API's progress stream — not meant for interactive use |

Without an explicit mode flag the script chooses the robust default: turbo with automatic out-of-memory backoff, plus SAX streaming when available. Any explicit engine flag overrides that choice.

## Schema versioning and auto-heal

Before each import the script compares the schema version of the SQL templates with the version recorded in the catalog:

| Situation | Default | With `--force-rebuild` | With `--no-auto-heal` |
|---|---|---|---|
| No catalog yet | normal import | delete and import | as default |
| Schema matches | normal import | delete and rebuild | as default |
| Catalog older than the templates | batch: rebuild automatically; single file: abort (exit 6) | delete and rebuild | abort (exit 6) |
| Template hash drift without version bump | warning, normal import | delete and rebuild | as default, with warning |

A single-file import never auto-heals, because rebuilding would drop the other files from the catalog; the recommended recovery is `convert-xml --batch --force-rebuild`.

## Good to know

- **One conversion per solution at a time.** The skill and the web client's import share a per-solution lock file. A second caller exits with code 7 (HTTP 409 on the API side) — see [Another conversion is already running](../Wiki/Troubleshooting.md#another-conversion-is-already-running). Different solutions convert independently.
- **Reference resolution is a hard gate.** If Phase 2 fails or resolves nothing although objects were loaded, the run aborts before the dependent phases with an `IMPORT ABORTED — build incomplete` banner; the served read copies keep their last consistent state. A deterministic repeat calls for `--batch --force-rebuild` ([Troubleshooting](../Wiki/Troubleshooting.md)).
- **Legacy exports are skipped.** Files with the root element `FMDynamicTemplate` (SaXML 2.0, FileMaker 18) are reported as skipped; only `FMSaveAsXML` (FileMaker 19 and later) is supported — see [XML](../xml/XML.md).
- **Solution context.** The script resolves the target bundle through the shared cascade: `--solution` flag, then a session pin (`FMLAB_SOLUTION`), then the active-solution pointer, then `default`. The compatibility symlink `db/fm_catalog.duckdb` always points at the active solution's catalog.
- **Clustering.** A fresh or forced build ends with automatic graph clustering; an incremental import into an already clustered catalog leaves the existing partition and its names in place. Re-run [Skill fm-graph-cluster](Skill%20fm-graph-cluster.md) when you want the modules re-derived.
- **Logs.** Batch runs write `logs/batch_import_<timestamp>.log` with per-file durations and a summary; the run state and the live log of the current import live under `solutions/<id>/state/`.

## See also

- [Ingestion Pipeline (XML Import)](../templates/Ingestion%20Pipeline%20%28XML%20Import%29.md) — the SQL templates behind each phase
- [katana-engine](../Wiki/katana-engine.md) — chunking, streaming, memory limiting and the import manifest
- [XML](../xml/XML.md) — structure and versions of the FileMaker exports
- [XML Import API](../rest-api/endpoints/XML%20Import%20API.md) — the same conversion through the REST API, with progress streaming
- [Components](../Wiki/Components.md#ingestion-pipeline) — where input, engine and catalog live
