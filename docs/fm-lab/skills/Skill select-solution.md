# Skill: select-solution

Switches the workspace's active solution — the pointer file, the `db/` symlinks and the running API — by exact id, by confirming a near-miss, or from a numbered list when no argument is given.

| | |
|---|---|
| **Category** | Setup & workspace |
| **Slash command** | `/select-solution [<id>]` |
| **Say it naturally** | "switch the solution", "activate solution X", "which solution should be active" — understood in 11 languages |
| **Input** | a solution id (optional) |
| **Reads** | the solution bundles under `solutions/` via `tools/solution.sh list` |
| **Writes** | the pointer `.fmlab/active_solution.json` and the workspace `db/` symlinks; triggers a best-effort reload of a running REST API |
| **Prerequisites** | none beyond the workspace itself — `tools/solution.sh` resolves everything; a running API is optional |
| **Under the hood** | `tools/solution.sh list` and `tools/solution.sh use <id>` |
| **Skill directory** | `.claude/skills/select-solution/` |
| **Related** | [Skill convert-xml](Skill%20convert-xml.md) · [Skill fm-show](Skill%20fm-show.md) |

## What it does

A workspace manages one or more solutions as bundles `solutions/<id>/{xml,db,state}`; the **active** one is what the compatibility symlink `db/fm_catalog.duckdb`, the CLI tools and the default API context refer to. The skill lists the bundles first — the authoritative set of valid ids, the active one marked — and then:

- **exact id** → activates it, or reports that it is already active;
- **near miss** (typo, case, substring) → asks *"did you mean `<id>`?"* and activates only after your confirmation; several close candidates are offered as a short list;
- **no argument** → shows a numbered list (id, name, last import) and accepts the id or the row number.

The script's confirmation is relayed verbatim: the new active solution, whether a running API picked up the switch, and the hint for a session-only alternative.

## How to use it

```
/select-solution                # list and pick
/select-solution acme           # activate by id
/select-solution ACME           # near miss → confirm → activate
```

## Good to know

- **Workspace default vs. session pin.** The switch moves the shared default for everyone using the workspace. For a temporary, session-local switch set `FMLAB_SOLUTION=<id>` in the shell instead; a pinned session is not affected by this skill, and the script says so.
- **Creating solutions** is not this skill's job — `tools/solution.sh create <id>` does that; the skill only switches between existing bundles.
- The web client keeps a per-tab solution context of its own; deep links from the navigation skills carry the solution id explicitly.

## See also

- [Solutions API](../rest-api/endpoints/Solutions%20API.md) — listing and switching solutions over HTTP
- [Multi-solution workspaces](../rest-api/REST%20API%20Overview.md#multi-solution-workspaces) — how solution scoping works across the stack
- [Tools](../Wiki/Components.md#tools) — `tools/solution.sh` and the migration helper
- [Folder structure](../Wiki/Folder%20structure.md) — the bundle layout under `solutions/`
