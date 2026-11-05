#!/usr/bin/env bash
# tools/fmlab.sh — the single entry point after a clone (no VS Code).
#
# It is the one command for BOTH onboarding paths that run from a shell:
#   a) Docker  — assembles the right compose files (base, or base + Claude overlay) and
#      lands you directly in the product (browser, or a Claude Code session).
#   c) Native  — if you answer "No" to Docker, it hands off to tools/init.sh (host
#      install: prereq checks, bootstrap, servers) so you never call init.sh directly.
# (Path b — VS Code Dev Container — is separate and fully automatic; it does not use
#  this wrapper.)
#
# Two questions up front (skippable via flags): Docker? then, on the Docker path, Claude?
#
#   bash tools/fmlab.sh up            # asks: Docker? → Claude? then → browser or agent
#   bash tools/fmlab.sh up --native   # skip Docker: run the native tools/init.sh path
#   bash tools/fmlab.sh up --claude   # Docker + straight into a Claude Code session
#   bash tools/fmlab.sh up -d         # Docker: bring the stack up in the background, return
#   bash tools/fmlab.sh agent         # (re)attach the agent to an already-running stack
#
# It does NOT replace the documented `docker compose` idioms — everything it runs is
# printed first, so the raw commands from the README keep working unchanged.
#
# Model: the stack always runs in the BACKGROUND (started with `up -d`, health-gated).
# The terminal foreground is the thing you actually use — the agent, or the web client
# in your browser — NOT a scrolling server-log stream (that is opt-in via `fmlab logs`).
#
# Everything it runs is printed first, so it stays transparent — the raw `docker
# compose …` commands from the README keep working unchanged.
#
# bash-3.2 discipline (macOS system bash): no `case` in $(…), no bash-4+ constructs,
# and empty arrays are expanded via the ${arr[@]+…} guard (a bare "${arr[@]}" trips
# `set -u` on bash 3.2; fixed only in 4.4).

set -euo pipefail

# --- Locate the repo root (the dir holding docker-compose.yml) ---------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BASE_COMPOSE="docker-compose.yml"
CLAUDE_COMPOSE="docker-compose.claude.yml"
WEB_URL="http://localhost:5173"
API_URL="http://localhost:3003"
PREFLIGHT="/usr/local/bin/claude-auth-preflight.sh"   # path INSIDE the api container
# $BROWSER of the agent session, path INSIDE the api container (repo bind mount): hands
# URLs — incl. the Claude Code sign-in page — to the open-bridge below.
CLAUDE_BROWSER="/workspaces/fm-lab/tools/lib/claude-browser.sh"

# --- Colours (only on a TTY) -------------------------------------------------------
if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_DIM=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi

info()    { echo "${C_CYAN}▶${C_RESET} $*"; }
success() { echo "${C_GREEN}✅${C_RESET} $*"; }
warn()    { echo "${C_YELLOW}⚠${C_RESET}  $*" >&2; }
die()     { echo "${C_YELLOW}✗${C_RESET}  $*" >&2; exit 1; }

interactive() { [ -t 0 ] && [ -t 1 ]; }

# --- Resolve the compose command (v2 `docker compose`, fallback v1 `docker-compose`) -
detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die "Docker Compose not found. Install Docker Desktop (macOS/Windows) or Docker Engine + the compose plugin (Linux): https://docs.docker.com/get-docker/"
    fi
    command -v docker >/dev/null 2>&1 || die "The 'docker' CLI is not on PATH."
    docker info >/dev/null 2>&1 || warn "The Docker daemon does not seem to be running — start Docker Desktop / the Docker service first."
}

# --- compose file flags for the chosen mode ----------------------------------------
compose_files() {
    # $1 = "claude" | "base"
    if [ "$1" = "claude" ]; then
        printf '%s\n' -f "$BASE_COMPOSE" -f "$CLAUDE_COMPOSE"
    else
        printf '%s\n' -f "$BASE_COMPOSE"
    fi
}

usage() {
    cat <<EOF
${C_BOLD}fmlab${C_RESET} — thin wrapper around docker compose for FM-Lab

${C_BOLD}Usage:${C_RESET}
  bash tools/fmlab.sh <command> [options]

${C_BOLD}Commands:${C_RESET}
  up            Ask (Docker? then Claude?) and start accordingly:
                • Docker → stack in the background + web client / agent session
                • native (No to Docker) → hand off to tools/init.sh on this host
  agent         (Re)attach the Claude Code agent to a running stack.
  open-bridge   Run the host open-URL bridge standalone (auto-started during
                'up --claude' / 'agent'): opens URLs requested by the agent —
                the Claude Code sign-in page included — in your host browser.
                --check-url <url> tests the whitelist.
  down          Stop and remove the stack.
  logs          Follow the stack logs (opt-in; not shown during 'up').
  update        Update fm-lab to the newest release. Local changes in the way
                are saved to .fmlab/update-backup/ first (--dry-run: only show).
  language      Language of the AI agent: 'language de' pins it, 'language auto'
                follows your prompts, no argument shows the setting.
  help          Show this help.

${C_BOLD}Options for 'up':${C_RESET}
  --docker      Use Docker (skip the "Docker?" question).
  --native      Skip Docker: run the native setup via tools/init.sh, then stop.
  --claude      Docker + start with the Claude Code agent and drop into a session.
  --no-claude   Docker, analysis stack only (open the web client).
  -d, --detach  Only bring the stack up in the background, then return to the
                shell (do not attach the agent / open the browser).
  --no-open     Analysis path: do not open the browser, just print the URL.
  --            Pass any following args straight through to 'docker compose up'.

${C_BOLD}Examples:${C_RESET}
  bash tools/fmlab.sh up                 # interactive: Docker? → Claude?
  bash tools/fmlab.sh up --native        # native host setup (tools/init.sh)
  bash tools/fmlab.sh up --claude        # Docker → a running Claude Code session
  bash tools/fmlab.sh up -d              # Docker, background only, return to shell
  bash tools/fmlab.sh agent              # reattach the agent later
  bash tools/fmlab.sh down

Web client → $WEB_URL   ·   REST API → $API_URL
EOF
}

# --- Best-effort open a URL in the host browser (TTY only, opt-out via --no-open) ---
# Returns 0 only if an opener was actually launched; 1 otherwise (suppressed, no TTY,
# or no opener available — e.g. a headless/remote host) so the caller can word the
# message honestly.
open_browser() {
    local url="$1"
    [ "${FMLAB_NO_OPEN:-0}" = "1" ] && return 1
    interactive || return 1
    local opener=""
    if   command -v open      >/dev/null 2>&1; then opener="open"        # macOS
    elif command -v xdg-open  >/dev/null 2>&1; then opener="xdg-open"    # Linux desktop
    elif command -v wslview   >/dev/null 2>&1; then opener="wslview"     # WSL
    fi
    [ -n "$opener" ] || return 1
    "$opener" "$url" >/dev/null 2>&1 || true
    return 0
}

# --- Open-URL bridge (host side) ----------------------------------------------------
# Claude Code inside the plain-Docker container has no way to reach the host browser
# ($BROWSER exists only in VS Code dev containers). The bridge uses the bind-mounted
# repo as the channel: the container-side helper (.claude/skills/_shared/scripts/
# open_url.sh) drops one-line *.url request files into .fmlab/open-requests/, this
# watcher validates them against a whitelist and opens them with the host's opener.
# A heartbeat file (mtime-refreshed every poll) tells the container the bridge is
# live; without a fresh heartbeat the container falls back to printing the URL.
BRIDGE_DIR="$REPO_ROOT/.fmlab/open-requests"
BRIDGE_HEARTBEAT="$BRIDGE_DIR/.bridge-alive"
BRIDGE_LOG="$REPO_ROOT/.fmlab/open-bridge.log"
BRIDGE_PID=""
BRIDGE_ALLOW_LIST=""

# Plain, colorless watcher-loop logging: when auto-started around an agent session
# the loop's output goes to $BRIDGE_LOG — writing to the terminal would corrupt the
# agent's TUI screen (stray "open-bridge → …" lines until the next redraw).
bridge_log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Whitelist: URL must start with one of these prefixes. Built once at watcher start:
#   - localhost/127.0.0.1 (http/https) + fmp:// / fmps:// (FileMaker via fmIDE)
#   - the Claude Code sign-in pages (subscription and Console), sent by the session's
#     $BROWSER helper (tools/lib/claude-browser.sh) — the link wraps in the terminal
#   - FMLAB_OPEN_BRIDGE_ALLOW  (comma-separated extra prefixes, e.g. "http://192.168.1.20:3003")
#   - FMLAB_WEB_URL            (origin of a configured remote frontend)
#   - any http(s) URL value found in .fmlab/settings.json (server-side settings store;
#     picked up at runtime so a future remote-API key is whitelisted automatically)
bridge_build_allow_list() {
    printf '%s\n' \
        "http://localhost" "https://localhost" \
        "http://127.0.0.1" "https://127.0.0.1" \
        "fmp://" "fmps://" \
        "https://claude.com/cai/oauth/authorize?" \
        "https://platform.claude.com/oauth/authorize?"
    if [ -n "${FMLAB_OPEN_BRIDGE_ALLOW:-}" ]; then
        printf '%s\n' "$FMLAB_OPEN_BRIDGE_ALLOW" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//'
    fi
    if [ -n "${FMLAB_WEB_URL:-}" ]; then
        printf '%s\n' "$FMLAB_WEB_URL" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://[^/]+).*#\1#'
    fi
    if [ -f "$REPO_ROOT/.fmlab/settings.json" ]; then
        # Extract every http(s) URL string value and reduce it to its origin.
        grep -oE '"https?://[^"]+"' "$REPO_ROOT/.fmlab/settings.json" 2>/dev/null \
            | tr -d '"' \
            | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://[^/]+).*#\1#' \
            || true
    fi
}

bridge_url_allowed() {
    local url="$1" prefix=""
    while IFS= read -r prefix; do
        [ -n "$prefix" ] || continue
        case "$url" in "$prefix"*) return 0 ;; esac
    done <<EOF
$BRIDGE_ALLOW_LIST
EOF
    return 1
}

# Best-effort host opener for bridge requests (browser AND fmp:// handler).
bridge_open_host() {
    local url="$1"
    if   command -v open     >/dev/null 2>&1; then open "$url"     >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
    elif command -v wslview  >/dev/null 2>&1; then wslview "$url"  >/dev/null 2>&1 || true
    else
        bridge_log "no opener (open/xdg-open/wslview) on this host — cannot open: $url"
        return 1
    fi
    return 0
}

bridge_loop() {
    mkdir -p "$BRIDGE_DIR"
    rm -f "$BRIDGE_DIR"/*.url 2>/dev/null || true   # never replay pre-existing requests
    BRIDGE_ALLOW_LIST="$(bridge_build_allow_list)"
    local f="" url=""
    while :; do
        touch "$BRIDGE_HEARTBEAT" 2>/dev/null || true
        for f in "$BRIDGE_DIR"/*.url; do
            [ -e "$f" ] || continue
            url="$(head -n 1 "$f" 2>/dev/null || true)"
            rm -f "$f" 2>/dev/null || true
            [ -n "$url" ] || continue
            if bridge_url_allowed "$url"; then
                bridge_log "open → $url"
                bridge_open_host "$url" || true
            else
                bridge_log "BLOCKED (not whitelisted): $url"
            fi
        done
        sleep 1
    done
}

bridge_start() {
    [ "${FMLAB_NO_BRIDGE:-0}" = "1" ] && return 0
    [ -n "$BRIDGE_PID" ] && return 0
    # Silence the loop towards the terminal — the agent TUI owns the screen from
    # here on; loop activity goes to the log instead.
    mkdir -p "$REPO_ROOT/.fmlab"
    : > "$BRIDGE_LOG"
    bridge_loop >>"$BRIDGE_LOG" 2>&1 &
    BRIDGE_PID=$!
    info "open-bridge active — agent URLs open in your host browser (log: .fmlab/open-bridge.log · opt-out: FMLAB_NO_BRIDGE=1)"
}

bridge_stop() {
    if [ -n "$BRIDGE_PID" ]; then
        kill "$BRIDGE_PID" 2>/dev/null || true
        wait "$BRIDGE_PID" 2>/dev/null || true
        BRIDGE_PID=""
    fi
    rm -rf "$BRIDGE_DIR" 2>/dev/null || true
}

# Standalone watcher (for sessions not started via 'up --claude'/'agent'), plus a
# whitelist self-test: open-bridge --check-url <url> prints ALLOW/BLOCK and exits.
cmd_open_bridge() {
    if [ "${1:-}" = "--check-url" ]; then
        [ -n "${2:-}" ] || die "Usage: fmlab.sh open-bridge --check-url <url>"
        BRIDGE_ALLOW_LIST="$(bridge_build_allow_list)"
        if bridge_url_allowed "$2"; then echo "ALLOW $2"; return 0; else echo "BLOCK $2"; return 1; fi
    fi
    info "open-bridge running (Ctrl-C to stop) — watching $BRIDGE_DIR"
    trap 'bridge_stop; exit 0' INT TERM
    bridge_loop &
    BRIDGE_PID=$!
    wait "$BRIDGE_PID" 2>/dev/null || true
    bridge_stop
}

# --- Health gate: poll the API until it answers (portable; no compose-version deps) -
# Warn-and-continue on timeout — a slow web boot should not abort onboarding, and the
# agent itself does not need the API to be up.
wait_healthy() {
    command -v curl >/dev/null 2>&1 || return 0
    local timeout="${FMLAB_UP_TIMEOUT:-180}" waited=0 step=3
    printf '%b' "${C_CYAN}▶${C_RESET} Waiting for the stack to be ready"
    while [ "$waited" -lt "$timeout" ]; do
        if curl -fsS -o /dev/null "$API_URL/api/version" 2>/dev/null; then
            printf ' ✓\n'; return 0
        fi
        printf '.'; sleep "$step"; waited=$(( waited + step ))
    done
    printf '\n'
    warn "The API was not ready within ${timeout}s — it may still be starting. Logs: bash tools/fmlab.sh logs"
    return 0
}

# --- Is the Claude overlay currently active on the running api container? -----------
claude_overlay_running() {
    local img
    img="$("${COMPOSE[@]}" -f "$BASE_COMPOSE" -f "$CLAUDE_COMPOSE" ps --format '{{.Image}}' api 2>/dev/null || true)"
    case "$img" in *claude*) return 0;; esac
    return 1
}

# --- Surface the Claude auth state before attaching (the M2.1 preflight, run in the
# container). In the background model its output would otherwise be hidden in the
# detached `up` log. Reuses the single-source wording incl. the wrapped-URL caveat. ---
agent_auth_hint() {
    "${COMPOSE[@]}" -f "$BASE_COMPOSE" -f "$CLAUDE_COMPOSE" exec -T api "$PREFLIGHT" 2>/dev/null || true
}

# --- Enter (and, on exit, offer to stop) the interactive agent session. NOT exec, so
# control returns here afterwards for the stop prompt. ------------------------------
enter_agent() {
    # Host-side open-bridge for the agent session: lets the agent open URLs
    # (web deep links, fmp://) in the host browser despite running in Docker.
    bridge_start
    trap 'bridge_stop' EXIT INT TERM
    info "Opening Claude Code inside the container — exit with ${C_BOLD}Ctrl-D${C_RESET}; the stack keeps running."
    echo "${C_DIM}──────────────────────────────────────────────────────────────${C_RESET}"
    # BROWSER only for this session — the bridge above is what it talks to. The Dev
    # Container path never comes here; there VS Code supplies its own $BROWSER.
    "${COMPOSE[@]}" -f "$BASE_COMPOSE" -f "$CLAUDE_COMPOSE" exec -it -e BROWSER="$CLAUDE_BROWSER" api claude || true
    bridge_stop
    trap - EXIT INT TERM
    echo
    success "Claude session ended — stack still running → $WEB_URL"
    if interactive; then
        printf '%sStop the stack now?%s [y/N] ' "$C_BOLD" "$C_RESET"
        local ans=""; read -r ans || true
        case "$ans" in
            [yY]|[yY][eE][sS]) cmd_down ;;
            *) info "Left running.  reattach: ${C_BOLD}bash tools/fmlab.sh agent${C_RESET}   ·   stop: ${C_BOLD}bash tools/fmlab.sh down${C_RESET}" ;;
        esac
    else
        info "reattach: bash tools/fmlab.sh agent   ·   stop: bash tools/fmlab.sh down"
    fi
}

cmd_up() {
    local mode="" hold="" use_docker="" passthrough=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --claude)             mode="claude"; use_docker="1" ;;   # agent implies Docker
            --no-claude)          mode="base";   use_docker="1" ;;
            --docker)             use_docker="1" ;;
            --native|--no-docker) use_docker="0" ;;
            -d|--detach)          hold="1" ;;
            --no-open)            FMLAB_NO_OPEN="1" ;;
            --)                   shift; passthrough=("$@"); break ;;
            -h|--help)            usage; return 0 ;;
            *)                    passthrough+=("$1") ;;
        esac
        shift
    done

    # ── Q1 · Docker or native? (unifies onboarding paths a + c) ────────────────────
    # --claude/--no-claude/--docker imply Docker; --native forces the native path.
    # Otherwise ask on a TTY (default Yes = Docker, the recommended path); off a TTY
    # keep Docker (unchanged CI/pipe behaviour — never route to init.sh unattended).
    if [ -z "$use_docker" ]; then
        if interactive; then
            printf '%sUse Docker?%s [Y/n]  %s(No → native setup on this host via tools/init.sh)%s ' \
                "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
            local ans=""; read -r ans || true
            case "$ans" in [nN]|[nN][oO]) use_docker="0" ;; *) use_docker="1" ;; esac
        else
            use_docker="1"
        fi
    fi

    # Native path → hand off to init.sh and stop. init.sh runs the prereq checks,
    # bootstrap, and starts the servers itself, so there is nothing to do after it.
    if [ "$use_docker" = "0" ]; then
        info "Native setup (no Docker) → handing off to ${C_BOLD}tools/init.sh${C_RESET}"
        echo "${C_DIM}  bash tools/init.sh${C_RESET}"
        exec bash "$REPO_ROOT/tools/init.sh"
    fi

    # From here on the Docker path — resolve the compose command (may die if missing).
    detect_compose

    # ── Q2 · Claude agent? ────────────────────────────────────────────────────────
    # No explicit choice → ask on a TTY, default to base off a pipe/CI (no forced prompt).
    if [ -z "$mode" ]; then
        if interactive; then
            printf '%sStart with the Claude Code agent?%s [y/N] ' "$C_BOLD" "$C_RESET"
            local ans=""; read -r ans || true
            case "$ans" in [yY]|[yY][eE][sS]) mode="claude" ;; *) mode="base" ;; esac
        else
            mode="base"
        fi
    fi

    local files=(); while IFS= read -r f; do files+=("$f"); done < <(compose_files "$mode")

    if [ "$mode" = "claude" ]; then
        info "Starting FM-Lab ${C_BOLD}with the Claude Code agent${C_RESET} (first run builds the image, ~2–3 min) …"
    else
        info "Starting FM-Lab (analysis stack; first run builds the image, ~2–3 min) …"
    fi
    echo "${C_DIM}  ${COMPOSE[*]} ${files[*]} up -d${passthrough[*]:+ ${passthrough[*]}}${C_RESET}"

    # 1) Bring the stack up in the background. `up -d` still streams build/create
    #    progress; only the post-start service logs are detached.
    "${COMPOSE[@]}" "${files[@]}" up -d ${passthrough[@]+"${passthrough[@]}"}

    # 2) Health-gate, then a compact ready banner.
    wait_healthy
    success "FM-Lab is running in the background"
    echo "   Web client → ${C_BOLD}$WEB_URL${C_RESET}     REST API → $API_URL"

    # 3) -d / non-interactive → do not grab the terminal; print the next step and return.
    if [ -n "$hold" ] || ! interactive; then
        if [ "$mode" = "claude" ]; then
            info "Open the agent:  ${C_BOLD}bash tools/fmlab.sh agent${C_RESET}"
        else
            info "Open the web client:  $WEB_URL     (logs: bash tools/fmlab.sh logs · stop: bash tools/fmlab.sh down)"
        fi
        return 0
    fi

    # 4) Foreground = the product.
    if [ "$mode" = "claude" ]; then
        agent_auth_hint
        enter_agent
    else
        if open_browser "$WEB_URL"; then
            info "Opened the web client in your browser → $WEB_URL"
        else
            info "Open the web client → ${C_BOLD}$WEB_URL${C_RESET}"
        fi
        info "logs: ${C_BOLD}bash tools/fmlab.sh logs${C_RESET}   ·   stop: ${C_BOLD}bash tools/fmlab.sh down${C_RESET}"
    fi
}

cmd_agent() {
    if ! claude_overlay_running; then
        warn "The Claude agent overlay is not running."
        echo "  Start it first:  bash tools/fmlab.sh up --claude    (or: up --claude -d)"
        exit 1
    fi
    agent_auth_hint
    enter_agent
}

cmd_down() {
    # Tear down whichever combination is up; the claude overlay is a superset, so pass
    # both files (harmless when only the base stack is running).
    info "Stopping FM-Lab …"
    "${COMPOSE[@]}" -f "$BASE_COMPOSE" -f "$CLAUDE_COMPOSE" down
}

cmd_logs() {
    exec "${COMPOSE[@]}" -f "$BASE_COMPOSE" -f "$CLAUDE_COMPOSE" logs -f "$@"
}

# --- update: fetch, then run the update script of the NEW release ------------------
# The target release knows its own migrations; the local tools/update.sh is only the
# fallback when the release cannot be fetched or does not ship one.
cmd_update() {
    command -v git >/dev/null 2>&1 || die "git is not installed — it is needed to update fm-lab."
    local upstream
    upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo origin/main)"
    info "Fetching the newest release …"
    git fetch --quiet "${upstream%%/*}" || warn "Could not reach '${upstream%%/*}' — continuing with the release fetched earlier."
    if git cat-file -e "$upstream:tools/update.sh" 2>/dev/null; then
        exec bash -c "$(git show "$upstream:tools/update.sh")" update.sh --no-fetch "$@"
    fi
    exec bash "$REPO_ROOT/tools/update.sh" --no-fetch "$@"
}

# --- language: the AI agent's working language (.fmlab/user.local.json) ------------
# Untracked on purpose: a setting in a shipped file (formerly CLAUDE.md) blocks every
# `git pull` that changes that file.
cmd_language() {
    local f=".fmlab/user.local.json" code="${1:-}"
    if [ -z "$code" ]; then
        local current=""
        [ -f "$f" ] && current="$(sed -n 's/.*"agent_language"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)"
        echo "Language of the AI agent: ${current:-auto} (auto = the language of your prompts)"
        echo "Change: bash tools/fmlab.sh language <code>   e.g. de, en, fr — or auto"
        return
    fi
    case "$code" in
        auto|[a-z][a-z]|[a-z][a-z]-[A-Za-z]*) ;;
        *) die "Not a language code: '$code' — use e.g. de, en, fr, zh-Hans or auto." ;;
    esac
    mkdir -p .fmlab
    if [ ! -s "$f" ] || [ "$(tr -d ' \t\r\n' < "$f")" = "{}" ]; then
        printf '{\n  "agent_language": "%s"\n}\n' "$code" > "$f"
    elif command -v node >/dev/null 2>&1; then
        node -e '
            const fs = require("fs"); const [f, v] = process.argv.slice(1);
            const d = JSON.parse(fs.readFileSync(f, "utf8")); d.agent_language = v;
            fs.writeFileSync(f, JSON.stringify(d, null, 2) + "\n");' "$f" "$code" \
            || die "$f is not valid JSON — fix or remove it, then run this again."
    elif grep -q '"agent_language"' "$f"; then
        local tmp; tmp="$(mktemp)"
        sed -e "s/\(\"agent_language\"[[:space:]]*:[[:space:]]*\)\"[^\"]*\"/\1\"$code\"/" "$f" > "$tmp" && cat "$tmp" > "$f"
        rm -f "$tmp"
    else
        local tmp; tmp="$(mktemp)"
        awk -v v="$code" '!done && /\{/ { sub(/\{/, "{\n  \"agent_language\": \"" v "\","); done = 1 } { print }' "$f" > "$tmp" && cat "$tmp" > "$f"
        rm -f "$tmp"
    fi
    success "Language of the AI agent: $code — takes effect in the next agent session."
}

# --- Dispatch ----------------------------------------------------------------------
main() {
    local cmd="${1:-up}"
    [ $# -gt 0 ] && shift || true
    case "$cmd" in
        up)             cmd_up "$@" ;;   # detect_compose runs INSIDE, after the Docker? choice
        agent|claude)   detect_compose; cmd_agent ;;
        open-bridge)    cmd_open_bridge "$@" ;;
        down|stop)      detect_compose; cmd_down ;;
        logs)           detect_compose; cmd_logs "$@" ;;
        update)         cmd_update "$@" ;;
        language)       cmd_language "$@" ;;
        help|-h|--help) usage ;;
        *)              warn "Unknown command: $cmd"; echo; usage; exit 2 ;;
    esac
}

# Run only when executed; sourcing (tests) just defines the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
