# Tooling — Commands, Servers, Documentation Install

> Referenced from CLAUDE.md §9. Environment helpers: DuckDB binary resolution,
> server lifecycle, documentation mirrors and auxiliary installs.

## DuckDB binary — locating the executable

In the standard setup (the Docker container, or a native install with DuckDB on `PATH`),
just call DuckDB as a plain `duckdb …` command. `which duckdb` succeeds there, so no
path probing is needed.

**Keep every DuckDB call a single, plain command — always the bare `duckdb …` form.** Do
**not** prefix an absolute path, wrap it in a subshell `( … )`, chain it with `&&`/`||` to
probe for the binary, or assign the path to a variable and call `$DB …`. The permission
allow-list matches the **first command token**: only `duckdb`, `/usr/local/bin/duckdb` and
`/opt/homebrew/bin/duckdb` are pre-approved. Any other prefix — a different absolute path, a
`$(…)` substitution or a `$DB` variable — is a different (or unresolvable) token, defeats the
match and makes Claude Code prompt for approval on every single query. Quoting inside
`-c "…"` is fine: a `;` or `(` inside the SQL string is **not** a shell separator and does
**not** cause a prompt — so the bare form covers arbitrary SQL.

If `which duckdb` fails (some native setups do not inherit the user's shell PATH), the fix is
**PATH, not an absolute-path prefix**: `tools/init.sh` resolves the binary once and writes its
directory into `.claude/settings.json → env.PATH`, so Claude Code always finds `duckdb` and the
bare form keeps working. Re-run `init.sh` if the entry is missing. Only as a genuine last
resort call an absolute path directly (still no subshell, no `$DB`), and then stick to the two
pre-approved locations `/usr/local/bin/duckdb` or `/opt/homebrew/bin/duckdb` — a home-installer
path like `~/.duckdb/cli/latest/duckdb …` is **not** allow-listed and will prompt.

**Important:** never try to install DuckDB yourself. If it cannot be found in any of the
locations above, point the user to the installation instructions.

## Servers (REST API & web frontend)

| Skill | Effect |
|---|---|
| `rest-api-start` | Starts the REST API server in the background on port 3003 |
| `rest-api-stop` | Stops the API server (and the frontend dev server if running) |
| `rest-frontend-start` | Starts the Vite frontend dev server on port 5173 |
| `rest-frontend-stop` | Stops the frontend dev server |

The API server reads its own per-solution DB copy
(`rest-api/db/solutions/<id>/fm_catalog.duckdb`, READ_ONLY, resolved from the active
solution) — it never blocks the master DB.

## Documentation mirrors (install/update skills)

| Skill | Installs |
|---|---|
| `install-claris-docs` | Claris FileMaker online help mirror → `docs/claris-help/` (11 languages, EN always included). The reference index `reference/fm_spec.duckdb` is a separate artifact shipped with the repo |
| `install-mbs-docs` | MBS plugin documentation |
| `install-duckdb-docs` | DuckDB documentation (used by `duckdb-skills:duckdb-docs`) |
| `install-fmide-docs` | fmIDE documentation (GitHub wiki) |

All installers check versions and prompt before replacing existing sets.

## Misc

- `fm-open` — open the currently discussed object in FileMaker via fmIDE fmp:// URL
- `fm-show` — open the currently discussed object in the FM-Lab web frontend (detail / references / graph)
- ⚠️ Dev-container filesystem is **case-insensitive**: `CLAUDE.md` and `claude.md` are the same file — modify only via Edit/Write tools, never via `cp`/`rm` between case variants.
