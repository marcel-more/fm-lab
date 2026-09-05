# Skill: install-ooe-fm

Clones the "One of Everything" FileMaker reference repository into `docs/ooe-fm/` — the converter's test corpus with SaXML exports across FileMaker versions — and keeps it up to date.

| | |
|---|---|
| **Category** | Ingestion (optional test tooling) |
| **Slash command** | `/install-ooe-fm [--force]` |
| **Say it naturally** | "install ooe-fm", "clone the ooe-fm test data" — English and German |
| **Input** | none |
| **Reads** | the remote repository on GitHub |
| **Writes** | `docs/ooe-fm/` (full git clone) and the version marker `docs/ooe-fm/.version` |
| **Prerequisites** | `git`, network access to GitHub |
| **Under the hood** | `.claude/skills/install-ooe-fm/scripts/install_ooe_fm.sh` |
| **Skill directory** | `.claude/skills/install-ooe-fm/` |
| **Related** | [Skill test-convert-xml](Skill%20test-convert-xml.md) · [Skill install-fm-xml-export-exploder](Skill%20install-fm-xml-export-exploder.md) |

## What it does

A fresh install clones the repository; on an existing clone the script compares the local commit with the remote head and asks before pulling. Updates are fast-forward only, so a locally modified clone is never silently overwritten — use `--force` to discard it and clone again. The commit hash and date are recorded in `.version`.

The corpus is entirely optional: it feeds [test-convert-xml](Skill%20test-convert-xml.md) and format exploration, nothing else in FM-Lab depends on it.

## How to use it

```
/install-ooe-fm            # install, or check for updates and ask
/install-ooe-fm --force    # remove the clone and clone again
```

Or run the script directly:

```bash
bash .claude/skills/install-ooe-fm/scripts/install_ooe_fm.sh [--force]
```

## See also

- [Doc Set ooe-fm](../docsets/Doc%20Set%20ooe-fm.md) — contents of the corpus, licensing and what the fixtures cover
- [Doc Sets Installation](../docsets/Doc%20Sets.md#installation-and-updates) — the uniform install and update mechanics
