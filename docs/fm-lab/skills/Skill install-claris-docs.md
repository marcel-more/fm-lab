# Skill: install-claris-docs

Downloads the Claris FileMaker Pro online help as a local, offline-capable mirror under `docs/claris-help/` — English always, plus any of ten further languages — and registers it as a doc set for the web client and the agent.

| | |
|---|---|
| **Category** | Setup & workspace |
| **Slash command** | `/install-claris-docs` (asks for the languages) |
| **Say it naturally** | "install the Claris docs", "install the Claris help in German", "update the Claris help mirror" — understood in 11 languages |
| **Input** | the languages to install (interactive question, or named in the request) |
| **Reads** | `help.claris.com` (crawled recursively, HTML plus CSS/JS/images) |
| **Writes** | `docs/claris-help/<lang>/`, `docs/claris-help/manifest.json`, per-language `.version` markers, the doc-set registry `.fmlab/docs.json` |
| **Prerequisites** | Python 3, `curl`, network access to `help.claris.com`, roughly 50 MB per language |
| **Under the hood** | `.claude/skills/install-claris-docs/scripts/install_claris_docs.sh` with the crawler `claris_crawler.py`; registration via `tools/register_docs.py` |
| **Skill directory** | `.claude/skills/install-claris-docs/` |
| **Related** | [Skill filemaker-function-reference](Skill%20filemaker-function-reference.md) · [Skill install-mbs-docs](Skill%20install-mbs-docs.md) |

## What it does

The mirror is the prose half of FileMaker's documentation in FM-Lab: structured facts (names, signatures, parameters, categories, compatibility, deep-link slugs) come from the shipped [fm-spec](../Wiki/fm-spec.md) reference database, the mirrored page is opened for descriptions, examples and related topics. The skill installs only the mirror — `reference/fm_spec.duckdb` ships with FM-Lab and is never downloaded or rebuilt here.

**English is always installed**, whatever else you choose: it is the reference language for slugs and canonical names and the fallback when a page is missing in another language. Three selection modes cover the usual cases — English only, English plus one language, or all eleven. Each language keeps its own `.version` marker (the server's `Last-Modified` date), so languages update independently; per-file `HEAD` checks refresh only changed pages on a re-run.

After a successful run the set is registered in `.fmlab/docs.json`, which makes it appear on the web client's Docs card and in the docs browser at `/docs/claris-help`.

## How to use it

```
/install-claris-docs                       # asks: English only / + one language / all
/install-claris-docs in German             # skips the question
```

Direct script use:

```bash
bash .claude/skills/install-claris-docs/scripts/install_claris_docs.sh                 # English only
bash .claude/skills/install-claris-docs/scripts/install_claris_docs.sh --lang=de       # English + German
bash .claude/skills/install-claris-docs/scripts/install_claris_docs.sh --langs=de,fr   # English + several
bash .claude/skills/install-claris-docs/scripts/install_claris_docs.sh --all           # all languages
bash .claude/skills/install-claris-docs/scripts/install_claris_docs.sh --check         # installed vs. remote, as JSON
```

## Options

| Option | Effect |
|---|---|
| `--lang=<code>` | One language in addition to English (`de`, `es`, `fr`, `it`, `nl`, `pt`, `sv`, `ja`, `ko`, `zh`) |
| `--langs=<a,b,c>` | Several languages in addition to English |
| `--all` / `--lang=all` | All ten languages plus English |
| `--force` | Skip the version check and the prompt; replace existing language sets |
| `--check` | Report the installed and remote versions without downloading |
| `--list-languages` | List the available languages, with an availability check against the server |
| `--max-workers=<n>` | Parallel downloads per language (default 8) |
| `--dry-run` | Discover pages only; write nothing |

## Good to know

- **Size and duration.** English alone is about 1,100 files and 50 MB in a few minutes; all languages come to roughly 550 MB and 20–30 minutes. Downloads are retried with backoff; a language with persistent gaps is marked `incomplete` in the manifest instead of aborting the run.
- **Locale codes.** The reference database uses `zh-Hans` where the mirror directory and the help URL use `zh`; everything else is identical.
- **Licensing.** The pages are Claris's proprietary documentation, mirrored as a local cache. Local use is fine; re-publishing the mirror is not.
- **Web alternative.** The same install runs from the web client's Docs pages (`POST /api/docs/install/claris-help`) with live progress and language selection.

## See also

- [Doc Set claris-help](../docsets/Doc%20Set%20claris-help.md) — scope, structure and integration of the mirror
- [fm-spec](../Wiki/fm-spec.md) — the reference index the mirror is joined to
- [Doc Sets Installation](../docsets/Doc%20Sets.md#installation-and-updates) — the uniform install and update mechanics
