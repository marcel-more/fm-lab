---
name: convert-xml
version: 0.9.0
description: Convert FileMaker XML export to DuckDB database. Automatically handles UTF-8 encoding conversion and creates analyzed database tables. Triggers (English): "convert XML", "import the FileMaker XML", "/convert-xml", "batch import all XML files". Triggers (German): "konvertiere die XML", "importiere die FileMaker-XML", "alle XML-Dateien importieren". Triggers (Spanish): "convertir el XML", "importar el XML de FileMaker". Triggers (French): "convertir le XML", "importer le XML FileMaker". Triggers (Italian): "converti l'XML", "importa l'XML FileMaker". Triggers (Dutch): "converteer de XML", "importeer de FileMaker-XML". Triggers (Portuguese): "converter o XML", "importar o XML do FileMaker". Triggers (Swedish): "konvertera XML", "importera FileMaker-XML". Triggers (Japanese): "XMLを変換", "FileMaker XMLをインポート". Triggers (Korean): "XML 변환", "FileMaker XML 가져오기". Triggers (Chinese): "转换 XML", "导入 FileMaker XML".
---

# FileMaker XML to DuckDB Conversion Skill

## When to Use This Skill

Use this skill when you need to convert a FileMaker XML export (created via SaveCopyAsXML) into a DuckDB database for analysis. The skill automates:

- UTF-16 to UTF-8 encoding conversion (if needed)
- SQL template preparation
- DuckDB database creation
- Cleanup of temporary files

## Parameters

The skill accepts **one required parameter**:

- **XML filename** - The name of the XML file in the active solution's inbox `solutions/<id>/xml/` (e.g., "MyDatabase.xml")
- **--batch** or **--all** - Process all XML files in the active solution's inbox

**Adaptive default (no mode flag):** A bare `convert-xml`/`--batch` auto-selects the
robust engine — **Turbo** (chunked Phase 1) + **--auto** (OOM backoff via resplit),
plus **SAX streaming** when the patched webbed is present (its identity with DOM is
proven on the full corpus, see `tools/tests/identity/streamify_identity.sh`). It never
hard-aborts on tight RAM (~2.5 GB floor). Any explicit mode flag below overrides the
default; `FM_FORCE_DOM=1` keeps turbo+auto but on DOM (no SAX).

Optional flags (any combination is allowed):

- **--fail-fast** - Stop immediately on first error (batch/test mode only)
- **--force-rebuild** - Delete the DB before importing and rebuild from scratch
- **--no-auto-heal** - On detected schema drift, abort instead of auto-rebuilding
- **--turbo** - Chunkmap engine (chunked Phase 1). Implied by the adaptive default. Add **--auto** for OOM backoff, **--changed-only** for a manifest skip of unchanged files.
- **--streamify** - SAX streaming hybrid (lower parse RAM). Implied by the adaptive default when the patched webbed is present.
- **--split** - Chunk Phase 1 per file at top-level branch boundaries (lowers peak DOM memory for very large files; bit-identical to the unsplit run). Explicit (non-turbo) DOM path.
- **--jobs <N>** - Run Phase 1 for N files **in parallel** (`auto` = all cores), each into its own part-DB, then merge into the master DB. **Default 8** (empirical sweet spot); `1` = sequential. Big batch speedup on multi-core machines; bit-identical to the sequential run. Not combinable with `--split`. RAM note: each worker peaks at ~10× the UTF-8 file size — lower N (e.g. `--jobs 4`) if memory is tight or other processes run concurrently; avoid N≥12 on a 14-GiB box (RAM cliff).
- **--quiet** - NDJSON output mode for the REST-API SSE bridge. Not intended for interactive use.
- **--solution <id>** - Import a specific solution bundle (`solutions/<id>/`). Default: the active solution from `.fmlab/active_solution.json` (fallback `default`).

**Concurrency:** The skill and the Web-Frontend (`POST /api/xml/convert`) share
the same Bash script and a **per-solution** lock file
(`solutions/<id>/state/xml_convert.lock`). The same solution can only be
converted once at a time — if you start the skill while a web-triggered run is
active, the script exits with code 7 (HTTP side returns 409). Different
solutions convert independently.

**Single-File Mode:**

```bash
convert-xml "MyDatabase.xml"
```

**Batch Mode:**

```bash
convert-xml --batch
```

**Batch Mode with Fail-Fast (for debugging):**

```bash
convert-xml --batch --fail-fast
```

**Force Rebuild (recovery after schema update or DB inconsistency):**

```bash
convert-xml --batch --force-rebuild
```

**Parallel batch (fastest full rebuild on multi-core):**

```bash
convert-xml --batch --force-rebuild --jobs auto
```

File paths are per solution — the script resolves the shared context cascade
(`--solution` flag → session pin `FMLAB_SOLUTION`/`FMLAB_CONTEXT` → active-solution
pointer → `default`):

- Input: `solutions/<id>/xml/`
- Output: `solutions/<id>/db/fm_catalog.duckdb` (readable via the compat symlink `db/fm_catalog.duckdb`)
- Run state + logs: `solutions/<id>/state/`

## Schema versioning & auto-heal

Before each import, the script compares the `@SCHEMA_VERSION` from
[ingestion/sql/convert_xml_01_extract.sql](../../../ingestion/sql/convert_xml_01_extract.sql) with the version
persisted in the DB table `SchemaInfo`. Possible outcomes:

| Detection action | Default behavior                                                        | With `--force-rebuild` | With `--no-auto-heal`     |
| ---------------- | ----------------------------------------------------------------------- | ---------------------- | ------------------------- |
| `fresh_build`    | DB does not exist → normal import                                       | Delete DB + import     | Same as default           |
| `incremental`    | Schema OK → normal import                                               | Delete DB + rebuild    | Same as default           |
| `rebuild`        | Batch: auto-heal (delete DB, re-import all XMLs). Single: abort, exit 6 | Delete DB + rebuild    | Abort, exit 6             |
| `warn`           | Hash drift without version bump: log warning, normal import             | Delete DB + rebuild    | Same as default + warning |

## Workflow

### Single-File Mode

When invoked with a filename, the skill performs these steps:

1. **Validate** - Check if the XML file exists in the solution's `xml/` inbox
2. **Detect Encoding** - Use `file -I` to detect file encoding
3. **Convert if Needed** - If UTF-16, convert to UTF-8 in temporary directory
4. **Prepare SQL** - Create temporary SQL script with correct paths and filename
5. **Execute DuckDB** - Run the conversion to create/update the database
6. **Cleanup** - Remove all temporary files automatically
7. **Report** - Provide simple success or error message

**Hard Phase-2 gate (converter 2.12.0+):** if reference resolution (Phase 2)
fails — SQL error, out-of-memory, or 0 references resolved while objects were
loaded — the single-file run aborts BEFORE the dependent phases, exactly like
batch mode: exit 1 with an `IMPORT ABORTED — build incomplete` banner (exit 8
for the memory case), `done ok:false`. No REST sync runs (the served read
copies keep the last consistent state) and no manifest row is written, so the
next `--batch --changed-only` re-parses the file. Note that Phase 1 has
already updated the master DB at that point; if the failure repeats
deterministically, run `convert-xml --batch --force-rebuild`.

### Batch Mode

When invoked with `--batch`, the skill performs these steps:

1. **Discover Files** - Find all `.xml` files in the solution's `xml/` inbox
2. **Validate All** - Check that all files are readable
3. **Process Sequentially** - For each file:
   - Display progress: "[15/62] Processing: MyDatabase.xml"
   - Measure processing time (start → end)
   - Detect encoding
   - Convert if needed
   - Import to DuckDB
   - Log file duration and status
   - Collect errors but continue to next file
4. **Build Universal Catalogs** - Create cross-file reference tables automatically
5. **Report Summary** - Show success/failure counts, list of failed files, and total duration
6. **Create Log File** - Detailed log file in `logs/` directory with per-file timings

## Available Tools

This skill uses a shell script (maintained under `tools/`) that handles all operations:

- **Script**: `ingestion/convert_fm_xml.sh`
- **Usage**: Execute the script with the XML filename as argument

## Working Process

### Step 1: Accept User Request

When the user asks to convert a FileMaker XML file, extract the filename.

### Step 2: Execute Conversion Script

Run the automation script:

```bash
bash ingestion/convert_fm_xml.sh "filename.xml"
```

### Step 3: Report Results

The script will output one of:

- `SUCCESS: Database created successfully from filename.xml`
- `WARNING: Skipped — legacy SaXML v2.0.0.0 format (FMDynamicTemplate)`
- `ERROR: File not found: filename.xml`
- `ERROR: UTF-8 conversion failed`
- `ERROR: DuckDB conversion failed (exit code: X)`

Report the result to the user with appropriate context.

## Error Handling

### File Not Found

If the XML file doesn't exist in the solution's `xml/` inbox, inform the user and suggest:

- Checking the filename spelling
- Verifying the file is in the solution's inbox (`solutions/<id>/xml/`)
- Listing available XML files with `ls solutions/<id>/xml/*.xml`

### Encoding Conversion Failed

If iconv fails (rare), this indicates:

- File permissions issue
- Corrupted XML file
- Unsupported encoding variant

Suggest checking file integrity.

### Unsupported XML Format (Skipped)

Files using the legacy `FMDynamicTemplate` root element (SaXML v2.0.0.0, FileMaker 18.x) are automatically skipped with a warning. Only `FMSaveAsXML` (SaXML v2.1.0.0+, FileMaker 19+) is supported.

### Schema drift (exit 6)

Triggered when the DB was built with an older `@SCHEMA_VERSION` than the current SQL template and the user did not choose an auto-heal path:

- **Single-file mode with drift** → automatic abort (auto-heal would lose other files from the DB). Recommendation: `convert-xml --batch --force-rebuild`.
- **`--no-auto-heal` flag active** → manual intervention expected.

### DuckDB Conversion Failed

If DuckDB fails, possible causes:

- Invalid XML structure
- Memory issues (file too large)
- Database permissions

Suggest examining the XML file or checking available disk space.

### Batch Processing Errors

If some files fail during batch processing:

- **Normal Mode**: The script continues with remaining files and reports all errors at the end
- **Fail-Fast Mode** (`--fail-fast`): The script stops immediately on first error for faster debugging
- Failed files are listed at the end in the final report (normal mode only)
- Exit code 1 if any file failed, 0 if all succeeded
- Universal catalogs are built even if some files failed (normal mode only)
- Individual error messages are shown for each failed file during processing
- Detailed error logs are written to `logs/batch_import_TIMESTAMP_errors.log`

## Output Format

Provide concise feedback:

### Single-File Mode

**Success:**

```
Successfully converted filename.xml to DuckDB database.
Database location: db/fm_catalog.duckdb
```

**Failure:**

```
Conversion failed: [specific error message]
[suggestion for resolution]
```

### Batch Mode

**Success (all files):**

```
Batch import complete!
Total files: 62
Successful: 62
Failed: 0
Total duration: 11m 27.234s (687.234 seconds)
Universal catalogs created successfully.

Log file: logs/batch_import_20260119_142345.log
Database location: db/fm_catalog.duckdb
```

**Partial Success (some files failed):**

```
Batch import complete with errors.
Total files: 62
Successful: 59
Failed: 3
Total duration: 10m 52.187s (652.187 seconds)

Failed files:
  - CorruptedFile.xml
  - InvalidStructure.xml
  - MissingData.xml

Log file: logs/batch_import_20260119_142345.log
Note: Universal catalogs were created for successfully imported files.
```

## Notes

### General

- All temporary files are automatically cleaned up
- Original XML files are never modified
- The SQL pipeline templates (`ingestion/sql/convert_xml_0N_*.sql`) remain unchanged
- No UTF-8 conversion files are left in the xml/ directory

### Single-File Mode

- Each conversion appends/updates data in the database (UPSERT semantics)
- Universal catalogs are NOT automatically created (user may import more files)

### Batch Mode

- All XML files in `xml/` directory are processed
- Universal catalogs are automatically created at the end
- Processing continues even if some files fail
- Database uses UPSERT semantics (re-importing same file updates data)
- Progress is shown for each file: "[15/62] Processing: MyDatabase.xml"
- Performance log is created in `logs/batch_import_YYYYMMDD_HHMMSS.log`
- Log contains per-file processing times, total duration, and summary
- Log file location is displayed at the end of the batch import
