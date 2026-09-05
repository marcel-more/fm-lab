# Katana XML Engine (`ingestion/`)

The self-contained FileMaker-XML import engine of fm-lab: converts
`SaveCopyAsXML` exports (SaXML v2.1.0.0+) into the DuckDB object catalog.
This directory is the **atomic delivery unit** of the engine — replacing it
wholesale replaces the engine (see *Patch contract* below).

## Layout

| Path | Content |
|---|---|
| `convert_fm_xml.sh` | Orchestrator (entry point). Carries `CONVERTER_VERSION`. |
| `gen_streamify_sql.sh` | Streamify generator + `--check` freshness gate (rc contract 0/2/3/4; called by the orchestrator before any SAX run) |
| `gen_design_functions.sh` | Generator + `--check` freshness gate (rc 0/2/3/4) of the design-function seed `sql/generated/design_functions_seed.sql`, derived from `reference/fm_spec.duckdb` (names of FileMaker's design functions in every reference language, for the P1c chunk retype). Called by `tools/fm-reference/pull-reference.sh` after every reference deploy and by the publish pre-check |
| `engine/` | awk engine: `katana_common.awk`, `split_fm_xml.awk`, `streamify_fm_xml.awk`, `turbo_phaseS_fuse.awk` |
| `lib/` | shell modules sourced by the orchestrator: `convert_preprocess.sh`, `convert_turbo.sh`, `convert_report.sh`, `webbed_caps.sh` |
| `sql/` | phase templates P1–P6 (`convert_xml_01_extract.sql` carries `@SCHEMA_VERSION` + `@SCHEMA_HASH_FILES`, engine-relative), `01b` heal cascade, `01c` design-function retype (seeded by `sql/generated/design_functions_seed.sql` — a committed generate, never edit by hand, regenerate via `gen_design_functions.sh`), `03b` plugin subname recovery, `create_analysis_views.sql` (P-Analysis), `streamify/` overrides (generated variant: `convert_xml_01_extract.streamify.sql` — never edit by hand, regenerate via `gen_streamify_sql.sh`) |
| `fixtures/` | webbed probe fixtures (SAX/CR/WS parity probes) |
| `version_check.json` | webbed capability registry + tested baseline (also read by `tools/build-container-env.mjs` for the container DuckDB pin) |

## Self-containment

All engine-internal paths resolve against `ENGINE_ROOT` (the directory of
`convert_fm_xml.sh`) — the directory is relocatable as a whole. `PROJECT_ROOT`
is used only for the documented **outside interface**:

- `solutions/<id>/` bundles, `db/` symlink, `logs/`, `.fmlab/` — instance
  runtime state
- `tools/lib/resolve_solution.sh` — shared solution cascade
- `tools/install_modes.sh` — shared NDJSON emit helpers (REST-API SSE bridge)
- `tools/graph-export/cluster.sh` — P7 auto-clustering (best-effort; a
  cluster failure never fails the import)
- `tools/tests/fixtures/xml/` — `--test` mode input (isolated ooe run)
- webbed DuckDB extension — provisioned by the container/setup;
  `version_check.json` only probes it

Compat wrappers at `tools/convert_fm_xml.sh` and `tools/gen_streamify_sql.sh`
preserve the historical call paths (`exec` pass-through, exit codes intact).

## Versioning

Two version axes live here:

- **Converter** — `CONVERTER_VERSION` in `convert_fm_xml.sh` (behaviour of
  the pipeline run)
- **Schema** — `@SCHEMA_VERSION` in `sql/convert_xml_01_extract.sql`
  (structure of the produced catalog; a bump triggers force-rebuild via the
  drift guard). `@SCHEMA_HASH_FILES` (engine-relative paths) is the secondary
  content-hash drift indicator (warn-level). The generated seed
  `sql/generated/design_functions_seed.sql` is deliberately not part of the
  hash list — its provenance header changes with every reference pull while
  the name set does not.

Both are surfaced in `version.json` (`modules` → `version_source`).

## Patch contract

An engine patch replaces this directory atomically (plus a matching
`version.json`). No runtime data lives here; deliveries, catalogs and state
live under `solutions/` and `db/`. A re-import is required only when
`@SCHEMA_VERSION` changed (the drift guard enforces it); a content-hash
drift alone logs a warning and recommends `--force-rebuild`.

## Interface to the graph layer

P5 (`sql/convert_xml_05_homes.sql`) creates the graph views `LogicalLinks`
(canonical definition — see the header there) and `ClusterEdges`/
`ClusterEdgesBase` inside the catalog. Consumers: the REST-API graph
endpoints (read the views via the read-only copy) and
`tools/graph-export/` (clustering). Changes to these view definitions are
interface changes — see `rest-api/templates/sql/graph_logical_links.sql`
(consumer stub) and `tools/graph-export/README.md`.
