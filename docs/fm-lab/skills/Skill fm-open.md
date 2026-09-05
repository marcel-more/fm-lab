# Skill: fm-open

Jumps from the conversation straight into FileMaker Pro: resolves the object under discussion, asks the FM-Lab REST API for its fmIDE `fmp://` URL — verifying that the fmIDE plugin is enabled and the fmIDE script exists in the target file — and opens it.

| | |
|---|---|
| **Category** | Navigation |
| **Slash command** | `/fm-open [<object>] [--file <F>] [--list] [--dry-run]` |
| **Say it naturally** | "open this in FileMaker", "jump to the script in FileMaker", "open in fmIDE" — understood in 11 languages |
| **Input** | an object name, a UUID, or the object under discussion |
| **Reads** | `db/fm_catalog.duckdb` (read-only) for resolution; `GET /api/fmide/status` and `GET /api/fmide/uri` on the REST API |
| **Writes** | nothing — one `fmp://` open |
| **Prerequisites** | a converted catalog; the REST API running; the fmIDE plugin enabled in FM-Lab (Settings → Plugins); FileMaker Pro with the fmIDE script installed in the target file |
| **Under the hood** | the shared resolution contract; the API decides — it is the only instance that knows the plugin state and the per-file script presence; `open_url.sh` opens the URL |
| **Skill directory** | `.claude/skills/fm-open/` |
| **Related** | [Skill fm-show](Skill%20fm-show.md) · [Skill fm-trace](Skill%20fm-trace.md) · [Skill install-fmide-docs](Skill%20install-fmide-docs.md) |

## What it does

fmIDE's *Name that Thing* API addresses FileMaker objects by name through `fmp://` URLs; FM-Lab's fmIDE plugin turns a catalog object into such a URL. The skill is deliberately API-first: instead of firing a URL blindly it fetches the JSON form and evaluates the gating fields before opening anything:

| API answer | Meaning | What the skill does |
|---|---|---|
| plugin disabled | fmIDE plugin off in FM-Lab | tells you where to enable it; opens nothing |
| object not found | stale context after a re-import | offers a name search |
| ambiguous UUID | clone files, no file given | shows the matching files, re-requests with the file |
| type not supported | fmIDE has no name parameter for this type | says so and points to [fm-show](Skill%20fm-show.md) |
| fmIDE script missing in the file | fmIDE not installed there | asks you to install it first; opens nothing |
| script present but without the fmIDE signature | probably a name collision or an outdated copy | warns; opens only if you confirm |
| everything green | ready | opens the `fmp://` URL |

Success is a single line — *"fmIDE → Script "X" opened in File"*. There is no feedback channel from FileMaker Pro, so the skill claims nothing beyond "opened".

## How to use it

```
/fm-open                                   # the object we just discussed
/fm-open "Create Invoice"
/fm-open 8075DF6B-… --file Customers       # clone-safe
/fm-open --list                            # context objects with an fmIDE-support column
/fm-open --dry-run                         # show the URL, do not open
```

## Good to know

- **Healed duplicate twins cannot be opened by their FM-Lab identity.** A catalog UUID without dashes marks a synthetic identity that FM-Lab assigned to an intra-file duplicate during [UUID healing](../schema/UUID%20Healing%20and%20Duplicate%20Census.md); it does not exist in the FileMaker source. The skill looks up the original UUID, explains that it is shared by several objects in the file — so a jump lands on *one* of them — and lets you decide, or points you to the twin's detail view in FM-Lab.
- **API down?** The skill says so and offers two ways: start the REST API (your call) and retry, or a degraded mode that builds the URL locally with an explicit *plugin and script status unverified* prefix.
- **Headless setups.** Without an open mechanism (plain Docker without the host open-bridge) the URL is printed as a clickable link; `bash tools/fmlab.sh open-bridge` on the host enables automatic opening.
- Never starts servers, never opens the first row of an ambiguous match, changes no files.

## See also

- [Doc Set fmIDE](../docsets/Doc%20Set%20fmIDE.md) — the *Name that Thing* API and `fmp://` URL forms
- [System API](../rest-api/endpoints/System%20API.md) — the plugin registry and fmIDE status in the version manifest
- [Skill fm-show](Skill%20fm-show.md) — the web-client counterpart without type restrictions
