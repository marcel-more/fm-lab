#!/usr/bin/env bash
# start-servers.sh — Starts the REST API (port 3003) and/or the frontend (port 5173).
#
# Usage:  start-servers.sh [api|frontend|all] [--restart-running]   (default: all)
#   api        start only the REST API
#   frontend   ensure the API is up, then start the Vite dev server
#   all        start API, then frontend  (full stack)
#   --restart-running  restart a server that is already running instead of re-attaching
#              to it (init.sh passes this right after its bootstrap: a process started
#              before `npm install` / `build:shared` never sees the fresh build)
#
# A running server is re-attached only when it belongs to THIS checkout. One whose
# working directory was deleted (e.g. the folder was removed and cloned again) or lies
# in another checkout is restarted — it would keep serving the old code and stale
# module resolutions (a missing packages/shared/dist stays "missing" in Vite).
#
# Env:  FMLAB_START_STATUS_FILE=<path>  write "api=<state>" / "frontend=<state>" lines
#       (state: started | restarted | running) for the caller's summary (init.sh).
#
# Runtime scenarios (see project/todo/ticket_server_restart.md):
#   • native host / VS Code dev container  → FMLAB_RUNTIME unset → this script manages
#     the processes (nohup node) and is idempotent (port-based detection, no lsof needed).
#   • Docker Compose topology              → FMLAB_RUNTIME=container → the API/web run as
#     the container's main process under `restart: unless-stopped`; this script MUST NOT
#     nohup a second copy. It prints host-side `docker compose` guidance instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_ROOT_REAL="$(cd "$PROJECT_ROOT" && pwd -P)"

TARGET="all"
RESTART_RUNNING=false
for arg in "$@"; do
  case "$arg" in
    api|frontend|all) TARGET="$arg" ;;
    web) TARGET="frontend" ;;
    --restart-running) RESTART_RUNNING=true ;;
    *) echo "Usage: $(basename "$0") [api|frontend|all] [--restart-running]" >&2; exit 2 ;;
  esac
done

# Colors (only for terminal output)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
header(){ echo -e "\n${BOLD}$1${NC}"; }

# NOTE — no FMLAB_RUNTIME guard here (deliberately). Two topologies set
# FMLAB_RUNTIME=container yet need OPPOSITE handling, and they are NOT distinguishable by
# that variable alone:
#   1. `docker compose up` — the api service's own command runs `node src/index.js` as
#      PID 1. This script is NEVER invoked there, so there is nothing to guard against.
#   2. VS Code Dev Container (deploy/devcontainer-public) — a thin wrapper over the same
#      compose file with `overrideCommand: true`, so node is NOT the container command;
#      postStartCommand runs THIS script to start node + vite. Here it MUST start them.
# Keying a guard on FMLAB_RUNTIME broke case 2 (the dev-container autostart no-oped). The
# idempotent detection below already makes a stray manual `docker compose exec api
# start-servers.sh` harmless (it reports "already running" instead of double-starting).

# Is a process listening on the port? (lsof → ss → curl HTTP probe as a third fallback).
# The curl fallback is essential for the base dev container, which has NEITHER lsof NOR
# ss — without it, wait_for_port always failed there (F-C1) even though the server was
# running. A successful curl connect (even on HTTP 4xx) proves a listener.
port_listening() {
  local port=$1
  if command -v lsof &>/dev/null; then
    lsof -nP -iTCP:"$port" 2>/dev/null | grep -q LISTEN
  elif command -v ss &>/dev/null; then
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
  elif command -v curl &>/dev/null; then
    curl -s -o /dev/null --max-time 1 "http://localhost:${port}/" 2>/dev/null
  else
    return 1
  fi
}

# HTTP GET successful (2xx)? Used for the foreign-process / identity check. If curl is
# missing, return 0 (can't check → trust the listener, legacy behavior).
http_ok() {
  command -v curl &>/dev/null || return 0
  curl -fs --max-time 2 "$1" >/dev/null 2>&1
}

# Determine the PID on a port (lsof if available, otherwise ss — IPv6-safe)
get_listen_pid() {
  local port=$1
  if command -v lsof &>/dev/null; then
    lsof -nP -iTCP:"$port" 2>/dev/null | awk '/LISTEN/ {print $2}' | sort -u | head -1
  elif command -v ss &>/dev/null; then
    ss -tlnpH 2>/dev/null | awk -v p="$port" '$4 ~ "[:.]"p"$"' \
      | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
  fi
}

# Working directory of a process as "<inode> <path>" (lsof, else /proc). Empty when it
# cannot be determined (no lsof and no /proc, foreign user, PID in another container) —
# the caller then trusts the listener (legacy behavior). The inode is what detects a
# deleted-and-re-cloned folder: the path string is the same, the directory is not.
process_cwd() {
  local pid=$1 ino="" path=""
  if command -v lsof &>/dev/null; then
    local out
    out=$(lsof -a -p "$pid" -d cwd -Fin 2>/dev/null || true)
    ino=$(printf '%s\n' "$out" | sed -n 's/^i//p' | head -1)
    path=$(printf '%s\n' "$out" | sed -n 's/^n//p' | head -1)
  fi
  if { [ -z "$ino" ] || [ -z "$path" ]; } && [ -e "/proc/$pid/cwd" ]; then
    path=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
    ino=$(ls -dLi "/proc/$pid/cwd" 2>/dev/null | awk '{print $1}')
  fi
  [ -n "$ino" ] && [ -n "$path" ] && printf '%s %s' "$ino" "$path"
}

# Does the server process belong to a different (or vanished) checkout? Returns 0 and
# sets STALE_REASON when it does; 1 when it belongs to this checkout or is unknown.
STALE_REASON=""
server_is_stale() {
  local pid=$1 info ino path now_ino
  STALE_REASON=""
  [ -n "$pid" ] || return 1
  info=$(process_cwd "$pid")
  [ -n "$info" ] || return 1
  ino=${info%% *}
  path=${info#* }
  case "$path" in
    *" (deleted)")
      STALE_REASON="its working directory was deleted (${path% (deleted)})"
      return 0 ;;
  esac
  if [ ! -d "$path" ]; then
    STALE_REASON="its working directory no longer exists ($path)"
    return 0
  fi
  now_ino=$(ls -di "$path" 2>/dev/null | awk '{print $1}')
  if [ -n "$now_ino" ] && [ "$now_ino" != "$ino" ]; then
    STALE_REASON="it runs in a deleted copy of $path (folder removed and re-created, e.g. a fresh clone)"
    return 0
  fi
  case "$path" in
    "$PROJECT_ROOT_REAL"|"$PROJECT_ROOT_REAL"/*) return 1 ;;
  esac
  STALE_REASON="it belongs to another checkout ($path)"
  return 0
}

# Stop the server on a port via stop-servers.sh (output indented, it is a sub-step).
restart_stop() {
  bash "$SCRIPT_DIR/stop-servers.sh" "$1" 2>&1 | sed -n '/stopped\|SIGKILL/s/^/  /p' || true
}

# Wait until a port responds (max $2 seconds)
wait_for_port() {
  local port=$1 max=${2:-5} i=0
  while [ $i -lt $max ]; do
    if port_listening "$port"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# ─── Locate node/npm binaries ────────────────────────────────
# nohup inherits a restricted PATH; resolve the full binary path so the
# server starts reliably regardless of how Node was installed.
NODE_BIN=""
NPM_BIN=""

if command -v node &>/dev/null; then
  NODE_BIN=$(command -v node)
  NPM_BIN=$(command -v npm)
else
  # Homebrew (Apple Silicon / Intel)
  for _candidate in "/opt/homebrew/bin/node" "/usr/local/bin/node"; do
    if [ -x "$_candidate" ]; then
      NODE_BIN="$_candidate"
      NPM_BIN="$(dirname "$_candidate")/npm"
      break
    fi
  done

  # nvm — resolve via default alias, fall back to most recent installed version
  if [ -z "$NODE_BIN" ]; then
    _nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    _nvm_default="$_nvm_dir/alias/default"
    if [ -f "$_nvm_default" ]; then
      _ver=$(cat "$_nvm_default" | tr -d '[:space:]')
      _candidate="$_nvm_dir/versions/node/$_ver/bin/node"
      if [ ! -x "$_candidate" ]; then
        # alias may point to another alias (e.g. "lts/*") — take latest installed
        _candidate=$(ls -t "$_nvm_dir/versions/node/"*/bin/node 2>/dev/null | head -1)
      fi
      if [ -x "$_candidate" ]; then
        NODE_BIN="$_candidate"
        NPM_BIN="$(dirname "$_candidate")/npm"
      fi
    fi
  fi
fi

if [ -z "$NODE_BIN" ]; then
  error "Node.js not found. Install it from https://nodejs.org/"
  exit 1
fi

# Ensure node's bin directory is in PATH so nohup child processes
# (e.g. vite with #!/usr/bin/env node) can find node regardless of
# how it was installed (nvm, Homebrew, system).
export PATH="$(dirname "$NODE_BIN"):$PATH"

# Ensure the log dir exists — nohup redirects into logs/*.log and would fail if the
# directory is missing (e.g. a fresh checkout without the logs/.gitkeep placeholder).
mkdir -p "$PROJECT_ROOT/logs"

api_started=false
frontend_started=false
# running | started | restarted — for the status block and FMLAB_START_STATUS_FILE
api_state="running"
frontend_state="running"

# Decide whether a verified own server on the port must be restarted, and stop it if so.
# Returns 0 when it was stopped (the caller then starts a fresh one).
restart_if_needed() {
  local pid=$1 target=$2 label=$3
  if server_is_stale "$pid"; then
    warn "$label${pid:+ (PID $pid)} is running, but $STALE_REASON — restarting it"
  elif [ "$RESTART_RUNNING" = true ]; then
    info "$label${pid:+ (PID $pid)} is running — restarting it to pick up the fresh bootstrap"
  else
    return 1
  fi
  restart_stop "$target"
  return 0
}

# ─── Start the REST API (idempotent) ─────────────────────────
start_api() {
  header "REST-API (Port 3003)"

  # Check the DB copy
  if [ ! -f "$PROJECT_ROOT/rest-api/db/fm_catalog.duckdb" ]; then
    error "Database not found: rest-api/db/fm_catalog.duckdb"
    error "Please run 'convert-xml --batch' first."
    exit 1
  fi

  # Check whether it's already active — and whether the listener really is OUR API (not a
  # foreign process on 3003). Identity via /api/version (F-A6).
  if port_listening 3003; then
    API_PID=$(get_listen_pid 3003 || true)
    if ! http_ok http://localhost:3003/api/version; then
      error "Port 3003 is in use${API_PID:+ (PID $API_PID)}, but /api/version does not respond — foreign process?"
      error "Please free the port (tools/stop-servers.sh api) or stop the foreign service."
      exit 1
    fi
    if restart_if_needed "$API_PID" api "REST API"; then
      api_state="restarted"
      if port_listening 3003; then
        error "REST API on port 3003 could not be stopped — please run tools/stop-servers.sh api"
        exit 1
      fi
    else
      info "REST API already running${API_PID:+ (PID $API_PID)}"
    fi
  fi
  if ! port_listening 3003; then
    # Start the server
    cd "$PROJECT_ROOT/rest-api"
    nohup "$NODE_BIN" src/index.js > "$PROJECT_ROOT/logs/rest-api.log" 2>&1 &
    API_PID=$!
    cd "$PROJECT_ROOT"

    if wait_for_port 3003 5; then
      info "REST API started (PID $API_PID)"
      api_started=true
      [ "$api_state" = "restarted" ] || api_state="started"
    else
      error "REST API could not be started. Log:"
      tail -20 "$PROJECT_ROOT/logs/rest-api.log" 2>/dev/null || true
      exit 1
    fi
  fi

  # Fetch the version
  API_VERSION=$(curl -s http://localhost:3003/api/version 2>/dev/null || echo "")
  if [ -n "$API_VERSION" ]; then
    TABLE_COUNT=$(echo "$API_VERSION" | grep -o '"table_count":[0-9]*' | grep -o '[0-9]*' || echo "?")
    UPTIME=$(echo "$API_VERSION" | grep -o '"uptime_seconds":[0-9]*' | grep -o '[0-9]*' || echo "")
    info "API responds — $TABLE_COUNT tables loaded${UPTIME:+, uptime ${UPTIME}s}"
    # A long uptime after a code change means a STALE process is still serving the old
    # code (the /api/admin/reload trap only reloads the DB, never the code). Flag it.
    if [ "$api_started" = false ] && [ -n "$UPTIME" ] && [ "$UPTIME" -gt 5 ]; then
      warn "This process has been up ${UPTIME}s — if you just changed API code, restart it:"
      warn "  tools/stop-servers.sh api && tools/start-servers.sh api"
    fi
  else
    warn "API is running, but /api/version does not respond"
  fi
}

# ─── Frontend filesystem preflight ───────────────────────────
# Reproduces Vite's async index.html read (see tools/preflight-fs-check.mjs) so a broken
# workspace mount is reported with a clear fix instead of Vite's cryptic EPERM overlay /
# white page. Non-fatal: it only WARNS and lets startup continue — if the diagnosis is
# wrong the user is never blocked, and if it is right the guidance sits right above the
# failure. Runs unconditionally (even when Vite "already running"), because the classic
# case is a server that came up but cannot serve index.html.
preflight_fs() {
  local target="$PROJECT_ROOT/apps/web/index.html"
  [ -f "$target" ] || return 0   # nothing to probe (e.g. incomplete checkout) — let Vite handle it

  local out rc
  set +e
  out=$("$NODE_BIN" "$PROJECT_ROOT/tools/preflight-fs-check.mjs" "$target" 2>&1)
  rc=$?
  set -e

  case "$rc" in
    0) ;;  # async read clean — nothing to report
    3)
      # sync read OK, async open EPERM → the macOS/VirtioFS async-open bug.
      error "Filesystem preflight: Node cannot open apps/web/index.html asynchronously (EPERM)."
      warn  "This is the known Docker Desktop / macOS VirtioFS bug — Vite would only show a"
      warn  "white page / an EPERM overlay. A plain read works, but Vite's async open does not."
      echo  "  Fix (either one):"
      echo  "    1) Docker Desktop -> Settings -> General -> 'file sharing implementation':"
      echo  "       switch VirtioFS -> gRPC FUSE -> Apply & Restart -> restart the dev container."
      echo  "    2) VS Code -> command palette -> 'Dev Containers: Clone Repository in Container Volume...'"
      echo  "       (moves the workspace into a named volume; bypasses VirtioFS entirely, and is faster on macOS)."
      echo  "  Probe: $out"
      ;;
    2)
      # even the synchronous read fails → real permission/ownership/missing-file problem.
      error "Filesystem preflight: apps/web/index.html is not readable."
      warn  "Likely an ownership/permission mismatch on the workspace mount (host UID ≠ container 'node')."
      echo  "  Diagnose & fix:"
      echo  "    ls -ln apps/web/index.html        # compare the owner UID against \`id\`"
      echo  "    # from the HOST terminal, as root:"
      echo  "    docker exec -u 0 <container> chown -R node:node /workspaces/fm-lab/apps/web"
      echo  "  Probe: $out"
      ;;
    *) ;;  # node missing / unexpected — stay silent, don't block startup
  esac
}

# ─── Start the frontend (idempotent) ─────────────────────────
start_frontend() {
  header "Frontend (Port 5173)"

  # Check the Vite installation
  if [ ! -f "$PROJECT_ROOT/node_modules/.bin/vite" ]; then
    error "Vite not found. Please run 'npm install' in the project root."
    exit 1
  fi

  # Filesystem preflight — flag a VirtioFS/permission problem before Vite hits it.
  preflight_fs

  # Check whether it's already active — and whether it really is the Vite dev server (not a
  # foreign service on 5173). Identity via /@vite/client (only Vite serves that, F-A6).
  if port_listening 5173; then
    FE_PID=$(get_listen_pid 5173 || true)
    if ! http_ok http://localhost:5173/@vite/client; then
      error "Port 5173 is in use${FE_PID:+ (PID $FE_PID)}, but it is not a Vite dev server — foreign process?"
      error "Please free the port (tools/stop-servers.sh frontend) or stop the foreign service."
      exit 1
    fi
    if restart_if_needed "$FE_PID" frontend "Frontend"; then
      frontend_state="restarted"
      if port_listening 5173; then
        error "Frontend on port 5173 could not be stopped — please run tools/stop-servers.sh frontend"
        exit 1
      fi
    else
      info "Frontend already running${FE_PID:+ (PID $FE_PID)}"
    fi
  fi
  if ! port_listening 5173; then
    # Start Vite
    cd "$PROJECT_ROOT/apps/web"
    nohup "$NPM_BIN" run dev > "$PROJECT_ROOT/logs/frontend.log" 2>&1 &
    FE_PID=$!
    cd "$PROJECT_ROOT"

    if wait_for_port 5173 8; then
      # Read the PID again (npm spawns a child process)
      FE_PID=$(get_listen_pid 5173 || true)
      info "Frontend started (PID $FE_PID)"
      frontend_started=true
      [ "$frontend_state" = "restarted" ] || frontend_state="started"
    else
      error "Frontend could not be started. Log:"
      tail -20 "$PROJECT_ROOT/logs/frontend.log" 2>/dev/null || true
      exit 1
    fi
  fi
}

# ─── Dispatch ────────────────────────────────────────────────
# The frontend is useless without the API, so `frontend`/`all` always ensure the API
# first (start_api is idempotent — it no-ops if the API already runs).
case "$TARGET" in
  api)       start_api ;;
  frontend)  start_api; start_frontend ;;
  all)       start_api; start_frontend ;;
esac

# ─── Summary ─────────────────────────────────────────────────
header "Status"
state_label() {
  case "$1" in
    started)   echo '(newly started)' ;;
    restarted) echo '(restarted)' ;;
    *)         echo '(already running, not restarted)' ;;
  esac
}
if [ "$TARGET" = "api" ] || [ "$TARGET" = "all" ] || [ "$TARGET" = "frontend" ]; then
  echo "  REST API:  http://localhost:3003  $(state_label "$api_state")"
fi
if [ "$TARGET" = "frontend" ] || [ "$TARGET" = "all" ]; then
  echo "  Frontend:  http://localhost:5173  $(state_label "$frontend_state")"
fi
if [ -n "${FMLAB_START_STATUS_FILE:-}" ]; then
  {
    echo "api=$api_state"
    [ "$TARGET" = "api" ] || echo "frontend=$frontend_state"
  } > "$FMLAB_START_STATUS_FILE" 2>/dev/null || true
fi
echo ""
echo "  Stop:      bash tools/fmlab.sh down   (or tools/stop-servers.sh)"
echo "  API log:   logs/rest-api.log"
[ "$TARGET" != "api" ] && echo "  FE log:    logs/frontend.log"
exit 0
