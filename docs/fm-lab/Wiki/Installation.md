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

Skip the prompts with flags: `--docker` / `--native`, `--claude` / `--no-claude`, `-d` (background only). `bash tools/fmlab.sh down` stops the stack, `… logs` follows the logs, `… agent` re-attaches Claude to a running stack.


---

### a) Docker (recommended, all platforms)

Answer **Yes** to “Use Docker?”, or run the raw command:

```bash
docker compose up
```

The image ships every prerequisite pinned to a tested version (DuckDB CLI + webbed extension + Node/npm + Leiden clustering engine); the host needs **only Docker**. Both servers come up:

- **Web client** → http://localhost:5173
- **REST API** → http://localhost:3003

The catalog (`db/`), conversions and settings live in the cloned repo **on the host**, so they survive restarts; updating is a plain `git pull` (the repo is mounted, not baked into the image). This is also the **Windows** path — the whole POSIX layer runs inside Linux, so the host OS no longer matters.

### b) VS Code Dev Container (easy start)

Open the repository in VS Code with the **Dev Containers** extension installed, select **“Reopen in Container”** → pick **`fm-lab`** or **`fm-lab + Claude Code`**. Everything starts automatically — bootstrap and both servers; VS Code then shows a clickable notification for the web client on port 5173. In the Claude variant the egress firewall and a credentials preflight run on start, and you reach the agent through the **Claude Code for VS Code** extension — no terminal steps required.
Recommended if you already work in VS Code.

### c) Native (no Docker, macOS / Linux)

For a host install without Docker, answer **No** to “Use Docker?”, or go straight there:

```bash
bash tools/fmlab.sh up --native   # hands off to tools/init.sh
```

`init.sh` checks the [prerequisites](#prerequisites), installs dependencies, seeds the environment, starts the [servers](Components.md#local-servers), and converts any XML already in `solutions/default/xml/`.

#### Windows

Native Windows is not supported — use way a) or b) via [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) + [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install).

Use **Docker Desktop with the WSL2 backend** and keep the cloned repo **inside** the WSL2 distribution (e.g. `~/projects/…`), **not** on the Windows drive (`/mnt/c/…`) — a repo on `/mnt/c` suffers slow bind mounts and file-watcher (inotify) problems.


---

### The AI agent (Claude Code)

The Claude variant adds the **[Claude Code](https://docs.claude.com/en/docs/claude-code)** CLI on top of the same tool, with the [duckdb-skills](https://github.com/duckdb/duckdb-skills) plugin bundled and a persistent login. Start it via `bash tools/fmlab.sh up --claude`, the Dev Container **“+ Claude Code”** variant, or the raw overlay:

```bash
docker compose -f docker-compose.yml -f docker-compose.claude.yml up
docker compose exec -it api claude  # sign in once; login then persists
```

On first launch choose **“Claude account with subscription”** and complete the browser sign-in once — persisted in a named volume, so it survives restarts.

> **The sign-in URL wraps across terminal lines — don’t select it by hand.** A truncated URL fails with _“Invalid response_type”_ . Copy it with **`c`** or paste it into an editor and remove every line break first. After visiting the Claude authentication page: paste the returned code at the `Paste code here` prompt.

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
- **Native (way c):** [DuckDB CLI](https://duckdb.org/docs/installation/) ≥ 1.5.4 + the **webbed** community extension (the XML reader; `init.sh` installs it when missing); Node.js ≥ 20, npm ≥ 10.
- **AI agent (optional):** [Claude Code](https://docs.claude.com/en/docs/claude-code) (bundled in the Docker agent variant) + the [duckdb-skills](https://github.com/duckdb/duckdb-skills) plugin (recommended).
- **XML export:** FileMaker Pro for the SaXML export — SaXML v2.1.0.0+ (FileMaker 19–22) and v2.3.0.0 (FileMaker 26), each read under its own import profile (see [the SaXML version notes](../xml/XML.md#version-notes-saxml-v22-and-v23)). Later SaXML versions may require parser adjustments.