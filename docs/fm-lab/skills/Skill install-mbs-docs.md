# Skill: install-mbs-docs

Downloads the MBS FileMaker Plugin documentation (the vendor's Dash docset) into `docs/mbs/`, derives the component-exception table the catalog and the docs browser rely on, and registers the set for the web client and the agent.

| | |
|---|---|
| **Category** | Setup & workspace |
| **Slash command** | `/install-mbs-docs [--force]` |
| **Say it naturally** | "install the MBS docs", "update the MBS plugin documentation" — understood in 11 languages |
| **Input** | none |
| **Reads** | `www.monkeybreadsoftware.com` (the `MBS.zip` docset) |
| **Writes** | `docs/mbs/` (HTML pages plus the SQLite index `docSet.dsidx`), `reference/mbs_component_exceptions.csv`, a `.version` marker, the doc-set registry `.fmlab/docs.json` |
| **Prerequisites** | `curl`, `unzip`, network access; Python 3 for the component parser; about 50 MB of free space during installation |
| **Under the hood** | `.claude/skills/install-mbs-docs/scripts/install_mbs_docs.sh` with `parse_mbs_components.py`; registration via `tools/register_docs.py` |
| **Skill directory** | `.claude/skills/install-mbs-docs/` |
| **Related** | [Skill mbs-function-reference](Skill%20mbs-function-reference.md) · [Skill install-claris-docs](Skill%20install-claris-docs.md) |

## What it does

The docset arrives as a ZIP with thousands of HTML pages and a SQLite search index; the skill downloads it to a temporary location, validates the structure, installs it under `docs/mbs/` and removes the temporaries. Version tracking uses the server's `Last-Modified` header: an existing installation is replaced only after your confirmation, or unconditionally with `--force`.

Two derived artifacts matter beyond the pages themselves:

- **Component exceptions** — the parser walks every function page and records functions whose name prefix differs from their component, or that belong to more than one component. The resulting CSV is used by the lookup skill, by the XML import (plugin-component catalog entries) and by the docs browser's component pages under `/docs/mbs/<Component>`. Without Python the parse is skipped with a warning; the install still succeeds.
- **Plug-in platform map** — `reference/plugin_spec.duckdb`, the structured per-function platform, deprecation and version data behind the plug-in platform tests and the platform badge in the object browser, **ships with FM-Lab** and is kept as is by this skill. It is derived by the maintainers from the docs mirror; a public installation never regenerates it.

## How to use it

```
/install-mbs-docs            # install, or check for updates and ask
/install-mbs-docs --force    # replace without asking
```

Direct script use, including the non-invasive check:

```bash
bash .claude/skills/install-mbs-docs/scripts/install_mbs_docs.sh [--force|--check]
```

## Good to know

- The documentation is English only; the lookup skill answers in your language but keeps function names, parameters and syntax verbatim.
- Installation is required for [mbs-function-reference](Skill%20mbs-function-reference.md) and for the MBS entries in the docs browser; the plug-in platform tests work from the bundled `plugin_spec.duckdb` regardless.
- The same install runs from the web client's Docs pages (`POST /api/docs/install/mbs`).

## See also

- [Doc Set mbs](../docsets/Doc%20Set%20mbs.md) — scope, index and integration of the docset
- [plugin-spec](../schema/plugin-spec.md) — the bundled plug-in platform map
- [Doc Sets Installation](../docsets/Doc%20Sets.md#installation-and-updates) — the uniform install and update mechanics
