# Skill: test-convert-xml

Runs the XML-to-DuckDB conversion against the bundled reference fixtures into a separate test database — a safe way to verify the pipeline after an update without touching the production catalog.

| | |
|---|---|
| **Category** | Ingestion |
| **Slash command** | `/test-convert-xml [--fail-fast]` |
| **Say it naturally** | "test the XML conversion", "run the convert-xml test" — understood in 11 languages |
| **Input** | none — the fixtures under `tools/tests/fixtures/xml/` |
| **Reads** | `tools/tests/fixtures/xml/*.xml` (provisioned from `docs/ooe-fm/saxml_utf8/` on first use) |
| **Writes** | `db/fm_test.duckdb` (recreated on every run) and `logs/test_*.log` |
| **Prerequisites** | the ooe-fm reference repository under `docs/ooe-fm/` — see [Skill install-ooe-fm](Skill%20install-ooe-fm.md) |
| **Under the hood** | `ingestion/convert_fm_xml.sh --test` |
| **Skill directory** | `.claude/skills/test-convert-xml/` |
| **Related** | [Skill convert-xml](Skill%20convert-xml.md) · [Skill install-ooe-fm](Skill%20install-ooe-fm.md) |

## What it does

The test run uses the same converter as [convert-xml](Skill%20convert-xml.md), but with swapped locations: input from the fixtures directory instead of the solution inbox, output to `db/fm_test.duckdb` instead of the production catalog, logs with a `test_` prefix. The production catalog and the served read copies are not touched.

On the first run the skill copies four reference files from the [ooe-fm](../docsets/Doc%20Set%20ooe-fm.md) clone into `tools/tests/fixtures/xml/`; the fixtures directory persists afterwards. Each file covers one aspect of the pipeline:

| Fixture | Covers |
|---|---|
| `Ooe__…__ddr_info.xml` | maximum coverage — every object type, with DDR-Info |
| `BrojDva__…__ddr_info.xml` | a second file — multi-file import and cross-file dependencies |
| `Ooe__…` (without `ddr_info`) | the fallback path when an export carries no DDR-Info |
| `Ooe__saxml_v2_0_0_0__fm_v18_0_3.xml` | the legacy SaXML 2.0 format — expected to be skipped |

## How to use it

```
/test-convert-xml
/test-convert-xml --fail-fast
```

Expected outcome with the default fixtures: three files imported, one skipped (the legacy format), none failed. The report names the counts, the location of the test database and the test log.

## Good to know

- Missing ooe-fm clone → the skill stops with a pointer to [install-ooe-fm](Skill%20install-ooe-fm.md).
- The previous test database is deleted before each run, so every run starts clean.
- Safe to repeat as often as you like; nothing under `solutions/` changes.

## See also

- [Doc Set ooe-fm](../docsets/Doc%20Set%20ooe-fm.md) — the reference corpus and what it contains
- [Ingestion Pipeline (XML Import)](../templates/Ingestion%20Pipeline%20%28XML%20Import%29.md) — the phases the test exercises
