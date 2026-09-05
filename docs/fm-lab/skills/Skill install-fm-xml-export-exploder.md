# Skill: install-fm-xml-export-exploder

Clones the fm-xml-export-exploder repository into `docs/fm-xml-export-exploder/` — a command-line tool that splits FileMaker XML exports into one text file per object — for reference and local experiments.

| | |
|---|---|
| **Category** | Ingestion (optional reference tooling) |
| **Slash command** | `/install-fm-xml-export-exploder [--force]` |
| **Say it naturally** | "install fm-xml-export-exploder", "clone the XML exploder" — English and German |
| **Input** | none |
| **Reads** | the remote repository on GitHub |
| **Writes** | `docs/fm-xml-export-exploder/` (full git clone) and the version marker `.version` |
| **Prerequisites** | `git`, network access to GitHub |
| **Under the hood** | `.claude/skills/install-fm-xml-export-exploder/scripts/install_fm_xml_export_exploder.sh` |
| **Skill directory** | `.claude/skills/install-fm-xml-export-exploder/` |
| **Related** | [Skill install-ooe-fm](Skill%20install-ooe-fm.md) |

## What it does

Same mechanics as the other repository installers: clone on first use, commit comparison and a confirmation prompt on updates, fast-forward pulls, `--force` for a clean re-clone, a `.version` marker with commit and date.

The tool itself is not wired into FM-Lab's pipeline — the catalog is built by the [Katana engine](../Wiki/katana-engine.md), not by exploding the export into files. The clone is a reference for developers who want to compare approaches or inspect a single object's XML in isolation.

## How to use it

```
/install-fm-xml-export-exploder
/install-fm-xml-export-exploder --force
```

## See also

- [Doc Set fm-xml-export-exploder](../docsets/Doc%20Set%20fm-xml-export-exploder.md) — what the repository contains and how it relates to FM-Lab
- [Other projects](../Wiki/Other%20projects.md) — the wider landscape of FileMaker XML tooling
