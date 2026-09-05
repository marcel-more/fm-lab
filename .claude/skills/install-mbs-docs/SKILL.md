---
name: install-mbs-docs
version: 0.9.0
description: Download and install MBS Plugin documentation from MonkeyBread Software. Automatically checks for newer versions and prompts before replacing existing docs. Triggers (English): "install MBS docs", "update MBS plugin documentation". Triggers (German): "installiere die MBS-Doku", "MBS-Plugin-Dokumentation aktualisieren". Triggers (Spanish): "instalar la documentación MBS", "actualizar la documentación MBS". Triggers (French): "installer la documentation MBS", "mettre à jour la documentation MBS". Triggers (Italian): "installa la documentazione MBS", "aggiorna la documentazione MBS". Triggers (Dutch): "installeer de MBS-documentatie", "MBS-documentatie bijwerken". Triggers (Portuguese): "instalar a documentação MBS", "atualizar a documentação MBS". Triggers (Swedish): "installera MBS-dokumentationen", "uppdatera MBS-dokumentationen". Triggers (Japanese): "MBSドキュメントをインストール", "MBSドキュメントを更新". Triggers (Korean): "MBS 문서 설치", "MBS 문서 업데이트". Triggers (Chinese): "安装 MBS 文档", "更新 MBS 文档".
---

# MBS Documentation Installation Skill

## When to Use This Skill

Use this skill when you need to:
- Perform initial setup of MBS Plugin documentation
- Update to the latest MBS Plugin documentation
- Reinstall documentation after corruption or accidental deletion

The skill automates:
- Downloading the MBS docset from MonkeyBread Software
- Version checking to avoid unnecessary downloads
- Extraction and installation to the correct location
- User confirmation when replacing existing documentation
- Parsing of MBS components to create exceptions table
- Cleanup of temporary files

## Parameters

The skill accepts **optional parameters**:
- `--force` - Skip version check and user prompts, force reinstallation

Without parameters, the skill will:
- Check for existing documentation
- Compare versions and prompt if update is available
- Install directly if no existing documentation found

## Workflow

When invoked, the skill performs these steps:

1. **Check Existing Docs** - Verify if documentation already exists
2. **Version Check** - Compare local version with remote (via HTTP Last-Modified timestamp)
3. **User Prompt** - Ask for confirmation if newer version is available
4. **Download** - Fetch MBS.zip from MonkeyBread Software to temporary directory
5. **Extract** - Unzip and validate the docset structure
6. **Install** - Copy documentation files to `docs/mbs/` directory
7. **Parse Components** - Analyze MBS functions and create exceptions table
8. **Plugin Platform Map** - `reference/plugin_spec.duckdb` ships bundled with
   every fm-lab release and is kept as is; it feeds the plug-in platform test
   members and the PluginFunction platform badge (members report `skipped`
   when the file is missing). Only a maintainer checkout with the deriver
   tooling present re-derives it from the fresh mirror — non-fatal either way
9. **Version Marker** - Store version information for future comparisons
10. **Cleanup** - Remove all temporary files automatically
11. **Report** - Provide clear success or error message

## Available Tools

This skill uses bundled scripts that handle all operations:
- **Installation Script**: `scripts/install_mbs_docs.sh`
  - Downloads and installs MBS documentation
  - Executes component parsing automatically
  - Usage: Execute with optional `--force` flag
- **Component Parser**: `scripts/parse_mbs_components.py`
  - Analyzes MBS function HTML documentation
  - Records functions whose prefix ≠ component and those listed under more
    than one component (columns `Funktionsname,Component,Components` —
    primary component plus the full list)
  - Creates `reference/mbs_component_exceptions.csv`
  - Called automatically by installation script
- **Plugin-Spec Deriver** (maintainer tooling, not part of the release)
  - Parses the per-function platform tables, old names and deprecation
    markers into `reference/plugin_spec.duckdb` (ATTACH alias `plugref`)
  - The installation script runs it only where it is present; a public
    install keeps the bundled database from the release

## Working Process

### Step 1: Accept User Request
When the user asks to install or update MBS documentation, determine if force installation is needed.

### Step 2: Execute Installation Script
Run the automation script:
```bash
bash .claude/skills/install-mbs-docs/scripts/install_mbs_docs.sh
```

Or with force flag:
```bash
bash .claude/skills/install-mbs-docs/scripts/install_mbs_docs.sh --force
```

### Step 3: Handle User Prompts
If the script finds a newer version, it will prompt:
```
Newer version available.
Current: Sun, 12 Jan 2026 16:47:42 GMT
Remote:  Mon, 20 Jan 2026 10:15:30 GMT
Replace existing docs? (y/n):
```

Inform the user and let them decide.

### Step 4: Report Results
The script will output one of:
- `SUCCESS: MBS documentation installed successfully`
- `Docs are up to date (version: [timestamp])`
- `Installation cancelled by user`
- `ERROR: Download failed`
- `ERROR: Extraction failed`
- `ERROR: Copy operation failed`

Report the result to the user with appropriate context.

## Error Handling

### Network Failures
If curl fails to download the ZIP file:
- Check internet connection
- Verify the MonkeyBread Software website is accessible
- Try again later if server is temporarily unavailable

### Extraction Errors
If unzip fails or archive structure is unexpected:
- Archive may be corrupted during download
- Retry the download
- Check available disk space

### Copy Operation Failed
If copying files to `docs/mbs/` fails:
- Check file permissions on `docs/` directory
- Verify available disk space (~50MB needed)
- Ensure no other process is using the documentation files

### Disk Space
The installation requires approximately 50MB of free space:
- 12MB for download
- 25MB for extraction
- 13MB for final documentation

### Component Parsing Failures
If component parsing fails (missing Python 3 or parsing errors):
- A warning is displayed but installation continues
- The script completes successfully without the exceptions table
- The `mbs-function-reference` skill will work but with slightly reduced accuracy
- Component parsing can be run manually later if needed

## Output Format

Provide concise feedback:

**Success (Fresh Installation):**
```
No existing docs found. Installing MBS documentation...
Downloading from https://www.monkeybreadsoftware.com/filemaker/Dash/MBS.zip...
Download complete (12.3 MB)
Extracting documentation...
Installing to docs/mbs/...

Parsing MBS components and creating exceptions table...
MBS Component Exceptions Parser
==================================================
Extrahiert nur Ausnahmen (Prefix ≠ Component)
PROJECT_ROOT: <project-root>
Analysiere 8246 HTML-Dateien...
Gesamt analysiert: 8245 Funktionen
Zuordnungen erfasst: 1113 (davon 121 mit mehreren Komponenten)

Komponenten-CSV erstellt: <project-root>/reference/mbs_component_exceptions.csv
Anzahl Zuordnungen: 1113

Top 10 Components mit Zuordnungen:
  GraphicsMagick       364 Zuordnungen
  Menu                  76 Zuordnungen
  Contacts              69 Zuordnungen
  ...
Component parsing completed successfully

SUCCESS: MBS documentation installed successfully
Version: Mon, 13 Jan 2026 10:15:30 GMT
Location: docs/mbs/
Files: (4567 HTML documentation files)
```

**Success (Already Up to Date):**
```
Checking for updates...
Docs are up to date (version: Mon, 13 Jan 2026 10:15:30 GMT)
No action needed.
```

**Success (Update):**
```
Checking for updates...
Newer version available.
Current: Sun, 12 Jan 2026 16:47:42 GMT
Remote:  Mon, 13 Jan 2026 10:15:30 GMT
Replace existing docs? (y/n): y
Downloading from https://www.monkeybreadsoftware.com/filemaker/Dash/MBS.zip...
...
SUCCESS: MBS documentation updated successfully
```

**Failure:**
```
ERROR: [specific error message]
[suggestion for resolution]
```

## Notes

- All temporary files are automatically cleaned up via trap mechanism
- Original documentation is only replaced after successful download and extraction
- The version marker file (`.version`) stores HTTP Last-Modified timestamp
- Multiple installations will overwrite the existing documentation
- The script is safe to run multiple times
- Documentation is required by the `mbs-function-reference` skill
- Component parsing creates `reference/mbs_component_exceptions.csv` automatically
- The component table is used by the `mbs-function-reference` skill for improved function lookup, by the XML import (PluginComponent catalog entries) and by the doc-set browser (component pages under `/docs/mbs/<Component>`)
- Python 3 is required for component parsing (gracefully skipped if not available)
- After a successful install/update the script registers this source in `.fmlab/docs.json` via `tools/register_docs.py`, so the web home dashboard's Docs card can list it.
