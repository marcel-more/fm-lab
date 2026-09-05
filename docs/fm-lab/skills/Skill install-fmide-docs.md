# Skill: install-fmide-docs

Installs the fmIDE documentation — the project's GitHub wiki — as Markdown pages under `docs/fmIDE/`, the grounding material for FM-Lab's fmIDE touchpoints (deep links into FileMaker Pro, ActionScripts).

| | |
|---|---|
| **Category** | Setup & workspace |
| **Slash command** | `/install-fmide-docs [--force]` |
| **Say it naturally** | "install the fmIDE docs", "update the fmIDE documentation" — English and German |
| **Input** | none |
| **Reads** | the fmIDE wiki repository on GitHub |
| **Writes** | `docs/fmIDE/*.md`, a `.version` marker (commit hash and date), the doc-set registry `.fmlab/docs.json` |
| **Prerequisites** | `git`, network access to GitHub |
| **Under the hood** | `.claude/skills/install-fmide-docs/scripts/install_fmide_docs.sh`; registration via `tools/register_docs.py` |
| **Skill directory** | `.claude/skills/install-fmide-docs/` |
| **Related** | [Skill fm-open](Skill%20fm-open.md) · [Skill fm-generate-script](Skill%20fm-generate-script.md) |

## What it does

The wiki is cloned to a temporary directory, its Markdown pages are copied to `docs/fmIDE/`, and the temporaries are removed. Updates compare the local commit hash with the remote head and ask before replacing; `--force` skips the question. The footprint is small — Markdown only, typically under 10 MB.

Within FM-Lab the pages document the *Name that Thing* API and its `fmp://` URL forms that [fm-open](Skill%20fm-open.md) uses to jump into FileMaker Pro, and the ActionScript format that [fm-generate-script](Skill%20fm-generate-script.md) can target as an experimental delivery channel.

## How to use it

```
/install-fmide-docs
/install-fmide-docs --force
```

```bash
bash .claude/skills/install-fmide-docs/scripts/install_fmide_docs.sh [--force|--check]
```

## See also

- [Doc Set fmIDE](../docsets/Doc%20Set%20fmIDE.md) — what the wiki covers and how FM-Lab integrates with fmIDE
- [Doc Sets Installation](../docsets/Doc%20Sets.md#installation-and-updates) — the uniform install and update mechanics
