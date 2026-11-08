#!/usr/bin/env bash
# stop-servers.sh — Stops the frontend (port 5173) and/or the REST API (port 3003).
#
# Usage:  stop-servers.sh [api|frontend|all] [--this-checkout]   (default: all)
#   api        stop ONLY the API. The frontend deliberately keeps running: killing the
#              Vite dev server mid-session drives the browser's HMR client into a
#              reload loop (Safari: endless reload; the former tab-opening/focus-stealing
#              side is defused since onAutoForward on 5173 is "notify", not "openBrowser").
#              While the API is down the web client degrades gracefully (transport-error
#              handling) and recovers on its own.
#   frontend   stop only the frontend
#   all        stop frontend + API   (frontend first, so the browser doesn't sit on a
#              dead API longer than necessary)
#   --this-checkout  stop only processes whose working directory lies in THIS fm-lab
#              folder. Anything else on the port is reported and left running — a
#              foreign Vite server on 5173, or Docker's port forwarder while the
#              container stack is up (macOS: com.docker.backend). `fmlab.sh down` uses
#              it; without the flag every listener on the port is stopped (unchanged).
#
# Test hook: FMLAB_TEST_API_PORT / FMLAB_TEST_WEB_PORT replace 3003 / 5173 (regression
# test only — start-servers.sh does not read them).
#
# In the Docker Compose topology (FMLAB_RUNTIME=container) the servers run under
# `restart: unless-stopped`; a plain kill is immediately resurrected. This script
# refuses to kill there and points at `docker compose stop` on the host instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT_REAL="$(cd "$SCRIPT_DIR/.." && pwd -P)"

TARGET="all"
OWN_ONLY=false
for arg in "$@"; do
  case "$arg" in
    api|all) TARGET="$arg" ;;
    frontend|web) TARGET="frontend" ;;
    --this-checkout) OWN_ONLY=true ;;
    *) echo "Usage: $(basename "$0") [api|frontend|all] [--this-checkout]" >&2; exit 2 ;;
  esac
done

API_PORT="${FMLAB_TEST_API_PORT:-3003}"
WEB_PORT="${FMLAB_TEST_WEB_PORT:-5173}"

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

# NOTE — no FMLAB_RUNTIME guard here (see the matching note in start-servers.sh). The VS
# Code Dev Container sets FMLAB_RUNTIME=container but starts the servers via THIS toolset
# (overrideCommand → node/vite are ordinary child processes, not PID 1), so stopping them
# here is correct and does NOT bounce the container. Only in the pure `docker compose up`
# path is node PID 1 under a restart policy — but there you stop with `docker compose
# stop`, not this script, so a guard here would only have broken the dev-container path.

# Determine all PIDs on a port (lsof if available, otherwise ss — IPv6-safe). The base
# dev container has NEITHER lsof NOR ss; there we fall back to fuser (which the ss/lsof
# absence otherwise left with no port→PID resolver). No lsof → no false "nothing found".
get_listen_pids() {
  local port=$1
  if command -v lsof &>/dev/null; then
    lsof -nP -iTCP:"$port" 2>/dev/null | awk '/LISTEN/ {print $2}' | sort -u
  elif command -v ss &>/dev/null; then
    ss -tlnpH 2>/dev/null | awk -v p="$port" '$4 ~ "[:.]"p"$"' \
      | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
  elif command -v fuser &>/dev/null; then
    fuser "${port}/tcp" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u
  fi
}

# Working directory of a process (lsof, else /proc); empty when it cannot be determined
# (foreign user, PID in another container). A " (deleted)" suffix (/proc, folder removed
# and cloned again) is dropped: the path still names the checkout the server came from.
process_cwd() {
  local pid=$1 path=""
  if command -v lsof &>/dev/null; then
    path=$( { lsof -a -p "$pid" -d cwd -Fn 2>/dev/null || true; } | sed -n 's/^n//p' | head -1)
  fi
  if [ -z "$path" ] && [ -e "/proc/$pid/cwd" ]; then
    path=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  fi
  printf '%s' "${path% (deleted)}"
}

# Does the process run inside this checkout? Unknown counts as "no" — --this-checkout
# never stops what it cannot attribute.
in_this_checkout() {
  local path
  path=$(process_cwd "$1")
  case "$path" in
    "$PROJECT_ROOT_REAL"|"$PROJECT_ROOT_REAL"/*) return 0 ;;
  esac
  return 1
}

# PIDs on the port this run may stop: never our own shell; with --this-checkout only
# the processes of this checkout.
stop_candidates() {
  local pid
  for pid in $(get_listen_pids "$1"); do
    [ "$pid" = "$$" ] && continue
    if [ "$OWN_ONLY" = true ] && ! in_this_checkout "$pid"; then
      continue
    fi
    echo "$pid"
  done
}

# Listeners on the port that --this-checkout leaves alone, as "PID <n> (<command>)".
foreign_listeners() {
  local pid cmd out=""
  for pid in $(get_listen_pids "$1"); do
    [ "$pid" = "$$" ] && continue
    in_this_checkout "$pid" && continue
    cmd=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    cmd=${cmd##*/}
    out="${out:+$out, }PID $pid${cmd:+ ($cmd)}"
  done
  printf '%s' "$out"
}

# Gracefully stop processes on a port
stop_port() {
  local port=$1 label=$2
  local pids foreign=""
  pids=$(stop_candidates "$port")

  if [ "$OWN_ONLY" = true ]; then
    foreign=$(foreign_listeners "$port")
    if [ -n "$foreign" ]; then
      warn "Port $port is held by $foreign outside this fm-lab folder — left running"
    fi
  fi

  if [ -z "$pids" ]; then
    [ -z "$foreign" ] && info "No $label active on port $port"
    return 1
  fi

  # Send SIGTERM (our own PID is already excluded by stop_candidates).
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done

  # Wait briefly and check
  sleep 1
  local remaining
  remaining=$(stop_candidates "$port")

  if [ -n "$remaining" ]; then
    # SIGKILL as a fallback
    for pid in $remaining; do
      kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.5
    warn "$label stopped (SIGKILL for PID $remaining)"
  else
    info "$label stopped (PID $pids)"
  fi
  return 0
}

fe_stopped=false
api_stopped=false

# ─── Frontend first (so the browser doesn't see API errors) ──
# Skipped for the `api` target: the Vite dev server must survive an API restart,
# otherwise the browser's HMR client enters its reload loop (see header).
if [ "$TARGET" != "api" ]; then
  header "Frontend (Port $WEB_PORT)"
  if stop_port "$WEB_PORT" "frontend server"; then
    fe_stopped=true
  fi
fi

# ─── REST API (only when the API is a stop target) ───────────
if [ "$TARGET" != "frontend" ]; then
  header "REST API (Port $API_PORT)"
  if stop_port "$API_PORT" "REST API server"; then
    api_stopped=true
  fi
fi

# ─── Summary ─────────────────────────────────────────────────
header "Status"
if [ "$fe_stopped" = true ] || [ "$api_stopped" = true ]; then
  if [ "$TARGET" != "frontend" ]; then
    [ "$api_stopped" = true ] && echo "  REST API:  stopped" || echo "  REST API:  was not active"
  fi
  if [ "$TARGET" != "api" ]; then
    [ "$fe_stopped" = true ]  && echo "  Frontend:  stopped" || echo "  Frontend:  was not active"
  fi
  if [ "$TARGET" = "frontend" ]; then
    echo "  REST API:  untouched (still running on $API_PORT if it was up)"
  fi
  if [ "$TARGET" = "api" ]; then
    echo "  Frontend:  untouched (keeps running on $WEB_PORT if it was up)"
  fi
else
  if [ "$OWN_ONLY" = true ]; then echo "  No servers of this fm-lab folder were active."; else echo "  No servers were active."; fi
fi
exit 0
