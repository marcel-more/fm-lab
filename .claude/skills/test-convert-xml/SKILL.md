---
name: test-convert-xml
version: 0.9.0
description: Run XML-to-DuckDB conversion test using ooe-fm reference data. Reads from tools/tests/fixtures/xml/ and writes to db/fm_test.duckdb without affecting the production database. Automatically provisions test data from ooe-fm if needed. Triggers (English): "test the XML conversion", "run the convert-xml test". Triggers (German): "teste die XML-Konvertierung", "konvertiere die Test-XML". Triggers (Spanish): "probar la conversión XML", "ejecutar la prueba de convert-xml". Triggers (French): "tester la conversion XML", "exécuter le test convert-xml". Triggers (Italian): "testare la conversione XML", "eseguire il test convert-xml". Triggers (Dutch): "test de XML-conversie", "voer de convert-xml-test uit". Triggers (Portuguese): "testar a conversão XML", "executar o teste convert-xml". Triggers (Swedish): "testa XML-konverteringen", "kör convert-xml-testet". Triggers (Japanese): "XML変換をテスト", "convert-xmlテストを実行". Triggers (Korean): "XML 변환 테스트", "convert-xml 테스트 실행". Triggers (Chinese): "测试 XML 转换", "运行 convert-xml 测试".
---

# XML Parser Test Skill

## When to Use This Skill

Use this skill to test the XML-to-DuckDB conversion pipeline without affecting the production database. It:
- Uses test data from the ooe-fm "One Of Everything" reference repository
- Reads from `tools/tests/fixtures/xml/` instead of the active solution's XML inbox
- Writes to `db/fm_test.duckdb` instead of `db/fm_catalog.duckdb`
- Logs with `test_` prefix in `logs/`

## Prerequisites

The ooe-fm repository must be installed under `docs/ooe-fm/`. If missing, the skill aborts with a hint to run `install-ooe-fm`.

## Parameters

No parameters required. Optional:
- `--fail-fast` - Stop on first error (for debugging)

## Working Process

### Step 1: Check ooe-fm Repository
Verify that `docs/ooe-fm/saxml_utf8/` exists and contains XML files.

If not installed:
```
ERROR: ooe-fm repository not found at docs/ooe-fm/
Please run: /install-ooe-fm
```
Abort and inform the user.

### Step 2: Provision Test Data
Check if `tools/tests/fixtures/xml/` exists and contains XML files. If empty or missing, copy the 4 reference files from `docs/ooe-fm/saxml_utf8/`:

```bash
mkdir -p tools/tests/fixtures/xml
cp docs/ooe-fm/saxml_utf8/Ooe__saxml_v2_2_3_0__fm_v22_0_4__ddr_info.xml tools/tests/fixtures/xml/
cp docs/ooe-fm/saxml_utf8/BrojDva__saxml_v2_2_3_0__fm_v22_0_4__ddr_info.xml tools/tests/fixtures/xml/
cp docs/ooe-fm/saxml_utf8/Ooe__saxml_v2_2_3_0__fm_v22_0_4.xml tools/tests/fixtures/xml/
cp docs/ooe-fm/saxml_utf8/Ooe__saxml_v2_0_0_0__fm_v18_0_3.xml tools/tests/fixtures/xml/
```

If `tools/tests/fixtures/xml/` already has XML files, skip this step and report:
```
Test data already present (N files in tools/tests/fixtures/xml/)
```

### Step 3: Remove Previous Test Database
Delete `db/fm_test.duckdb` if it exists, to ensure a clean test run.

### Step 4: Execute Test Import
Run the convert script with `--test` flag:
```bash
bash ingestion/convert_fm_xml.sh --test
```

Or with fail-fast:
```bash
bash ingestion/convert_fm_xml.sh --test --fail-fast
```

### Step 5: Report Results
The script outputs results with test-specific formatting:
- Header: "FileMaker XML TEST Import"
- Source/target paths shown
- Skipped files listed separately from failed files
- Log files prefixed with `test_`

Report the results to the user including:
- Number of successful/skipped/failed files
- Location of test database (`db/fm_test.duckdb`)
- Location of test log file

## Test Files Reference

All test files reside in `docs/ooe-fm/saxml_utf8/` (UTF-8 encoded):

| File | DDR | FM | Test Focus |
|------|-----|-----|------------|
| `Ooe__saxml_v2_2_3_0__fm_v22_0_4__ddr_info.xml` | Yes | 22.0.4 | Maximum coverage — all object types + DDR-Info |
| `BrojDva__saxml_v2_2_3_0__fm_v22_0_4__ddr_info.xml` | Yes | 22.0.4 | Multi-file + cross-file dependencies |
| `Ooe__saxml_v2_2_3_0__fm_v22_0_4.xml` | No | 22.0.4 | DDR fallback (same version without DDR-Info) |
| `Ooe__saxml_v2_0_0_0__fm_v18_0_3.xml` | No | 18.0.3 | Oldest SaXML version — backward compatibility |

**Not usable:** `saxml_utf16le/` (UTF-16 LE, requires conversion), `saxml_paths_depth_4/` (path lists only), `fm/` (fmp12 binaries).

## Expected Test Results

With the default 4 ooe-fm test files:
- **3 successful**: Ooe (DDR), BrojDva (DDR), Ooe (no DDR)
- **1 skipped**: Ooe v18 (legacy FMDynamicTemplate format)
- **0 failed**

## Error Handling

### ooe-fm Not Installed
```
ERROR: ooe-fm repository not found.
Run /install-ooe-fm to download the test reference data.
```

### All Files Skipped/Failed
If no files import successfully, report the issue and suggest checking the error log.

## Notes

- Test database `db/fm_test.duckdb` is independent from production `db/fm_catalog.duckdb`
- Test logs use `test_` prefix for easy identification
- The `tools/tests/fixtures/xml/` directory is persistent — test data is only copied once
- Safe to run repeatedly without affecting production data
