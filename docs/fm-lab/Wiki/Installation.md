[Setup](#setup)
[The AI agent (Claude Code)](#the-ai-agent-claude-code)
[Configuration options](#configuration-options)
[Prerequisites](#prerequisites)

---
## Setup

There are **three ways** to run FM-Lab. They share the same catalog and settings in the cloned repo, so you can switch between them freely (e.g. add the agent later — nothing is lost).
- [Docker](#a-docker-recommended-all-platforms)
- [VS Code Dev Container](#b-vs-code-dev-container-easy-start)
- [Native](#c-native-no-docker-macos-linux)

### The one command — `tools/fmlab.sh up`

For running **from a shell** (with or without Docker), the wrapper is the single entry point. It asks two questions and then does the right thing — nothing hidden: every `docker compose …` command it runs is printed first.

```
#  Use Docker? [Y/n]
     → Yes = Docker start            (way a)
     → No  = native setup on host    (way c)

#  Start with the Claude Code agent? [y/N]
     → Yes = Claude overlay
     → No  = analysis only
```

Skip the prompts with flags: `--docker` / `--native`, `--claude` / `--no-claude`, `-d` (background only). `bash tools/fmlab.sh down` stops FM-Lab — the Docker stack and the native servers of this folder, `… logs` follows the logs, `… agent` re-attaches Claude to a running stack.


---

### a) Docker (recommended, all platforms)

Answer **Yes** to “Use Docker?”, or run the raw command:

```bash
docker compose up
```

The image ships every prerequisite pinned to a tested version (DuckDB CLI + webbed extension + Node/npm + Leiden clustering engine); the host needs **only Docker**. Both servers come up:

- **Web client** → http://localhost:5173
- **REST API** → http://localhost:3003

The catalog (`db/`), conversions and settings live in the cloned repo **on the host**, so they survive restarts; an update replaces only the repo contents (the repo is mounted, not baked into the image — see [Updating fm-lab](#updating-fm-lab)).

### b) VS Code Dev Container (easy start)

Open the repository in VS Code with the **[Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)** extension installed, select **“Reopen in Container”** → pick **`fm-lab`** or **`fm-lab + Claude Code`**. Everything starts automatically — bootstrap and both servers; VS Code then shows a clickable notification for the web client on port 5173. In the Claude variant the egress firewall and a credentials preflight run on start, and you reach the agent through the **Claude Code for VS Code** extension — no terminal steps required.
Recommended if you already work in VS Code — Microsoft's [Developing inside a Container](https://code.visualstudio.com/docs/devcontainers/containers) guide explains the extension and the container workflow itself.
After [updating fm-lab](#updating-fm-lab), run **Dev Containers: Rebuild Container** instead of a plain reopen, so the container is built from the updated definition. If the container does not come up, see the two Dev Container entries under [Troubleshooting](Troubleshooting.md#dev-container-fails-to-reopen-dockerfile-with-features-not-found).

### c) Native (no Docker, macOS / Linux)

For a host install without Docker, answer **No** to “Use Docker?”, or go straight there:

```bash
bash tools/fmlab.sh up --native   # hands off to tools/init.sh
```

`init.sh` checks the [prerequisites](#prerequisites), installs dependencies, seeds the environment, starts the [servers](Components.md#local-servers), and converts any XML already in `solutions/default/xml/`.

#### Windows

Native Windows is not supported — use way a) or b) via [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) + [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install).

Use **Docker Desktop with the WSL2 backend** and keep the cloned repo **inside** the WSL2 distribution (e.g. `~/projects/…`), **not** on the Windows drive (`/mnt/c/…`) — a repo on `/mnt/c` suffers slow bind mounts and file-watcher (inotify) problems.

### Updating fm-lab

One command in the fm-lab folder brings the newest release (available from version 0.9.17 on; older versions update with `git pull` once):

```bash
bash tools/fmlab.sh update            # --dry-run: only show what would be saved
```

It downloads the release and first checks whether files you changed or created yourself are in the way. Those files are saved to `.fmlab/update-backup/<timestamp>/` — `update.json` there lists every file and why — and edited shipped files are put back to their shipped version; then the update is applied. It never stops halfway, and nothing is deleted. At the end it names the next step: restart fm-lab the way you run it — `bash tools/fmlab.sh up` (Docker), **Dev Containers: Rebuild Container**, or `bash tools/init.sh` (native). At that start fm-lab tidies up on its own: copies of an earlier version leave the template folders, and a shipped dashboard or test you edited stays under **Custom** as `<id>-local` (see [Dashboard overview](Components.md#dashboard-overview)).

A plain `git pull` keeps working. If it stops and lists files (*local changes would be overwritten*), one command repairs it — see [Troubleshooting](Troubleshooting.md#update-stops-local-changes-would-be-overwritten).


---

### The AI agent (Claude Code)

The Claude variant adds the **[Claude Code](https://docs.claude.com/en/docs/claude-code)** CLI on top of the same tool, with the [duckdb-skills](https://github.com/duckdb/duckdb-skills) plugin bundled and a persistent login. Start it via `bash tools/fmlab.sh up --claude`, the Dev Container **“+ Claude Code”** variant, or the raw overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.claude.yml up
docker compose exec -it api claude  # sign in once; login then persists
```

On first launch choose **“Claude account with subscription”** and complete the browser sign-in once — persisted in a named volume, so it survives restarts. Started via `bash tools/fmlab.sh up --claude` (or `agent`), the sign-in page opens in your browser on its own: confirm there, copy the code the page shows and paste it at the `Paste code here` prompt. If a session later reports _Login expired_, run `/login` in it.

> **Started any other way (raw `docker compose exec`), the sign-in URL wraps across terminal lines — don’t select it by hand.** A truncated URL fails with _“Invalid response_type”_. Claude Code puts it on the clipboard where the terminal allows it (OSC 52, e.g. iTerm2 — not macOS Terminal); otherwise paste it into an editor and remove every line break first. After visiting the Claude authentication page: paste the returned code at the `Paste code here` prompt. See also [Troubleshooting](Troubleshooting.md#claude-code-sign-in-in-the-terminal).

**Language of the agent.** The agent answers in the language of your prompts. To pin one, run `bash tools/fmlab.sh language de` — `auto` returns to the prompt language, no argument shows the setting. It is stored in `.fmlab/user.local.json`, outside the shipped files, so updates keep it; never change the language in `CLAUDE.md`.

**No browser at hand?** Put credentials in a `.env` next to the compose files instead — `ANTHROPIC_API_KEY=…` (API-key billing) or `CLAUDE_CODE_OAUTH_TOKEN=…` (from `claude setup-token`). No secret is ever stored in the image.

The agent stack also grants an **opt-in egress firewall** (allowlist: npm, GitHub, the Anthropic API, the DuckDB extension host, the VS Code marketplace, Claris docs, MBS docs) — applied automatically in the Dev Container.

---

### Configuration options

**Tuning (optional):** copy `.env.example` to `.env` next to `docker-compose.yml` and uncomment what you need:

```bash
FMLAB_MEM_LIMIT=8g      # RAM cap (raise for large solutions)
FMLAB_DUCKDB_THREADS=4  # thread cap (raise on hosts with more cores)
```


---

## Prerequisites

- **Docker (ways a / b):** only **[Docker](https://docs.docker.com/get-docker/)** on the host — everything else is in the image.
- **VS Code Dev Container (way b), on top of Docker:** [VS Code](https://code.visualstudio.com/) and the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) (`ms-vscode-remote.remote-containers`) — installation and the container workflow are documented in Microsoft's [Developing inside a Container](https://code.visualstudio.com/docs/devcontainers/containers) guide.
- **Native (way c):** [DuckDB CLI](https://duckdb.org/docs/installation/) 2.0.x, installed with the standard installer `curl https://install.duckdb.org | sh` (it sets `~/.duckdb/cli/latest`, which `init.sh` finds without a `PATH` entry) — DuckDB 1.5.6 is still supported, `init.sh` then shows an update hint — + the **webbed** community extension (the XML reader; `init.sh` installs it when missing). On Intel Macs DuckDB 2.0 builds community extensions only on a best-effort basis and stops with 2.1 — use the Docker setup there; [Node.js](https://nodejs.org/en) ≥ 22 with [npm](https://docs.npmjs.com/downloading-and-installing-node-js-and-npm) ≥ 10 — npm comes bundled with Node.js, so it needs no separate install; `init.sh` checks the two versions independently and, if an older Node still carries npm 9, asks for `npm install -g npm`. If the check keeps reporting an old version after an update, an earlier `PATH` entry is shadowing the new one — see [Troubleshooting](Troubleshooting.md#old-nodejs-or-npm-keeps-winning-after-an-update).
- **AI agent (optional):** [Claude Code](https://docs.claude.com/en/docs/claude-code) (bundled in the Docker agent variant) + the [duckdb-skills](https://github.com/duckdb/duckdb-skills) plugin (recommended).
- **XML export:** FileMaker Pro for the SaXML export — SaXML v2.1.0.0+ (FileMaker 19–22) and v2.3.0.0 (FileMaker 26), each read under its own import profile (see [the SaXML version notes](../xml/XML.md#version-notes-saxml-v22-and-v23)). Later SaXML versions may require parser adjustments.