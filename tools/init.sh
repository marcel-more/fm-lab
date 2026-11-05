#!/usr/bin/env bash
# init.sh — First-time setup for fm-lab
# -E (errtrace): without it the ERR trap below is not inherited by shell
# functions, so any failure inside a function died silently despite F-A7.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT_START=$SECONDS

# DuckDB CLI agent mode (2.0+) off for init and everything it starts (bootstrap.sh,
# the servers — and through the REST API the web import): with AI_AGENT set and
# stdout not a terminal, the CLI would print markdown tables and JSON errors.
# DuckDB 1.x ignores the variable.
export DUCKDB_AGENT_MODE=0

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=true ;;
  esac
done

# Colors (terminal only)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi

info()   { echo -e "${GREEN}✓${NC} $1"; }
warn()   { echo -e "${YELLOW}⚠${NC} $1"; }
error()  { echo -e "${RED}✗${NC} $1"; }
header() { echo -e "\n${BOLD}$1${NC}"; }

# Summary tracking
SUMMARY=()
summary_add() { SUMMARY+=("$1"); }
# Advisory entries (recommendations, missing optional parts) — rendered with ⚠
summary_warn() { SUMMARY+=("!$1"); }

# ─── Error handling ───────────────────────────────────────────
# On any uncaught failure (set -e), report which phase broke, where the logs are, and
# how to resume — instead of a bare non-zero exit with no context (F-A7). CURRENT_STEP
# is updated before each phase; explicit `exit N` (e.g. the prereq gate) does not
# trigger ERR, so those keep their own tailored message.
CURRENT_STEP="starting up"
on_error() {
  local ec=$?
  echo ""
  error "init.sh failed during: ${CURRENT_STEP} (exit ${ec})"
  echo  "    Logs:   logs/rest-api.log · logs/frontend.log  (plus the convert log printed above, if any)"
  echo  "    Retry:  bash tools/init.sh          — idempotent; unchanged steps are skipped or fast"
  echo  "    Detail: bash tools/init.sh --verbose"
  exit "$ec"
}
trap on_error ERR

# ─── FM-Lab version (central manifest version.json) ───────────
# Shown at the very top so the user always sees which fm-lab build they
# are setting up. jq-optional: falls back to a sed scrape of the first
# top-level "version" key when jq is unavailable (e.g. a stock macOS).
VERSION_JSON="$PROJECT_ROOT/version.json"
read_fmlab_version() {
  local v=""
  [ -f "$VERSION_JSON" ] || { printf ''; return 0; }
  if command -v jq >/dev/null 2>&1; then
    v=$(jq -r '.version // empty' "$VERSION_JSON" 2>/dev/null)
  fi
  if [ -z "$v" ]; then
    v=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_JSON" | head -1)
  fi
  printf '%s' "$v"
}
FMLAB_VERSION=$(read_fmlab_version)

# ─── DuckDB baseline (stable, tested setup) ───────────────────
# The recommended floor lives data-driven in the webbed capability registry
# (ingestion/version_check.json → .tested_baseline). We only WARN when the
# installed DuckDB CLI is older — never abort, never block init. webbed itself is a
# runtime extension; the convert pipeline probes it separately (.capabilities[]).
VERSION_MANIFEST="$SCRIPT_DIR/../ingestion/version_check.json"

# Compare two dotted numeric versions; echoes -1 / 0 / 1 for a<b / a==b / a>b.
# bash-3.2-safe (macOS): pure string/array ops, no `sort -V` (unavailable on BSD sort).
version_cmp() {
  local a="$1" b="$2" IFS=.
  local a_arr=($a) b_arr=($b)
  local i max=${#a_arr[@]}
  if [ "${#b_arr[@]}" -gt "$max" ]; then max=${#b_arr[@]}; fi
  for ((i=0; i<max; i++)); do
    local ai="${a_arr[i]:-0}" bi="${b_arr[i]:-0}"
    ai="${ai//[!0-9]/}"; bi="${bi//[!0-9]/}"
    ai="${ai:-0}"; bi="${bi:-0}"
    if [ "$ai" -gt "$bi" ]; then echo 1; return; fi
    if [ "$ai" -lt "$bi" ]; then echo -1; return; fi
  done
  echo 0
}

# Node.js security floor per supported release line: the version of the latest
# security release on each line. Update on every Node.js security release —
# release lines missing here are end-of-life (no more security fixes).
# Source: https://nodejs.org/en/blog/vulnerability/october-2026-security-releases
NODE_SECURITY_RELEASE="2026-10-21"
NODE_SECURITY_FLOOR="22.23.4 24.22.1 26.12.1"

# Warn (recommendation only — never aborts) when Node.js is below the security
# floor of its release line, or on a line that no longer receives security fixes.
check_node_security() {
  local installed v floor="" newest_major=0 maj lines=""
  installed=$(printf '%s' "$1" | sed -E 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  case "$installed" in
    ''|*[!0-9.]*) return 0 ;;   # unparsable → the prerequisite check already reported it
  esac
  maj=${installed%%.*}
  for v in $NODE_SECURITY_FLOOR; do
    [ "${v%%.*}" = "$maj" ] && floor="$v"
    [ "${v%%.*}" -gt "$newest_major" ] && newest_major="${v%%.*}"
    lines="${lines:+$lines, }${v%%.*}.x ≥ $v"
  done

  if [ -n "$floor" ]; then
    [ "$(version_cmp "$installed" "$floor")" = "-1" ] || return 0
    warn "Node.js $installed misses security fixes — the $maj.x line is patched in $floor (security release $NODE_SECURITY_RELEASE)."
    echo  "    Recommended: update Node.js to ≥ $floor → https://nodejs.org/en/download   (init continues; this is a recommendation)"
    summary_warn "Node.js security  v$installed < v$floor (security update recommended — see above)"
  elif [ "$maj" -lt "$newest_major" ]; then
    warn "Node.js $installed: the $maj.x line is end-of-life and no longer receives security fixes."
    echo  "    Recommended: switch to a supported line ($lines) → https://nodejs.org/en/download"
    echo  "    (init continues; this is a recommendation)"
    summary_warn "Node.js security  v$installed: $maj.x is end-of-life (update recommended — see above)"
  fi
  # A major newer than every listed line is unknown here → stay silent.
}

# Leading major number of a --version string ("v22.17.0" → 22, "10.9.2" → 10).
# Echoes empty when there is nothing numeric to read, so the caller can tell
# "too old" apart from "unreadable" — a bare `[ "$x" -ge N ]` on an empty value
# aborts with "integer expression expected" and hides the real prerequisite.
major_of() {
  printf '%s' "$1" | sed -E 's/^[^0-9]*([0-9]+).*/\1/' | tr -cd '0-9'
}

# Value of tested_baseline.<key> from the version manifest: jq when present, else a
# sed scrape (the keys are unique in the file, stock macOS has no jq). Empty when
# unreadable — the caller supplies a fallback, so the check itself never fails.
baseline_get() {
  local v=""
  [ -f "$VERSION_MANIFEST" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    v=$(jq -r --arg k "$1" '.tested_baseline[$k] // empty' "$VERSION_MANIFEST" 2>/dev/null)
  fi
  [ -n "$v" ] || v=$(sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_MANIFEST" | head -1)
  printf '%s' "$v"
}

# Node.js version advice (recommendation only, never aborts): on a supported release
# line below the Docker image's Node (tested_baseline.node_recommended_version) a hint,
# from the image's major on nothing. End-of-life lines are left to check_node_security,
# which already recommends switching.
check_node_recommended() {
  local installed rec rec_maj maj
  rec=$(baseline_get node_recommended_version)
  rec_maj=$(major_of "$rec")
  [ -n "$rec_maj" ] || return 0
  installed=$(printf '%s' "$1" | sed -E 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  maj=$(major_of "$installed")
  [ -n "$maj" ] && [ "$maj" -lt "$rec_maj" ] || return 0
  case " $NODE_SECURITY_FLOOR " in
    *" $maj."*) ;;
    *) return 0 ;;
  esac
  info "Node.js $installed is supported; recommended is Node.js $rec_maj (the version of the Docker image, $rec)."
  echo  "    → https://nodejs.org/en/download   (init continues; this is a recommendation)"
  summary_warn "Node.js version   v$installed supported, $rec_maj.x recommended (see above)"
}

# DuckDB version advice (recommendation only, never aborts): below the oldest
# supported version a warning, from there up to the recommended version an update
# hint with the standard installer command, at or above it nothing.
check_duckdb_baseline() {
  local installed rec sup webbed url cmd
  rec=$(baseline_get duckdb_min_version);           [ -n "$rec" ]    || rec="2.0.0"
  sup=$(baseline_get duckdb_supported_min_version); [ -n "$sup" ]    || sup="1.5.6"
  webbed=$(baseline_get webbed_min_version);        [ -n "$webbed" ] || webbed="2.13.0"
  url=$(baseline_get update_url);                   [ -n "$url" ]    || url="https://duckdb.org/docs/installation/"
  cmd=$(baseline_get install_command);              [ -n "$cmd" ]    || cmd="curl https://install.duckdb.org | sh"

  # Extract the numeric version, e.g. "1.5.4" from "v1.5.4 (Variegata) 08e34c447b".
  installed=$(printf '%s' "$1" | sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/')
  case "$installed" in
    ''|*[!0-9.]*) return 0 ;;   # couldn't parse a version → stay silent
  esac

  if [ "$(version_cmp "$installed" "$sup")" = "-1" ]; then
    warn "DuckDB $installed is older than the oldest version fm-lab supports (v$sup)."
    echo  "    Recommended: DuckDB $rec (validated with webbed $webbed) — standard installer:  $cmd"
    echo  "    → $url   (init continues; this is a recommendation, not a requirement)"
    summary_warn "DuckDB version    v$installed < supported v$sup (update recommended — see above)"
  elif [ "$(version_cmp "$installed" "$rec")" = "-1" ]; then
    info "DuckDB $installed is supported; recommended is $rec (validated with webbed $webbed)."
    echo  "    Update with the standard installer:  $cmd"
    summary_warn "DuckDB version    v$installed supported, v$rec recommended (see above)"
  fi
}

# Warn (recommendation only) when the CLI is on a newer DuckDB than the REST API's
# bundled @duckdb/node-api: catalogs it writes may use a storage format the REST API
# cannot open (web frontend: STORAGE_VERSION_MISMATCH). See tools/lib/duckdb_binding.sh.
check_duckdb_binding() {
  # Advisory only — a missing helper must never abort init (set -e).
  [ -f "$PROJECT_ROOT/tools/lib/duckdb_binding.sh" ] || return 0
  . "$PROJECT_ROOT/tools/lib/duckdb_binding.sh"
  fmlab_duckdb_binding_mismatch "$1" || return 0
  warn "DuckDB CLI $FMLAB_DUCKDB_CLI_VER is newer than the REST API's DuckDB $FMLAB_DUCKDB_BINDING_VER (@duckdb/node-api)."
  echo  "    Catalogs written by this CLI may be unreadable for the REST API / web frontend."
  echo  "    Recommended: use DuckDB CLI ${FMLAB_DUCKDB_BINDING_VER%.*}.x, which this fm-lab release supports, or update"
  echo  "    fm-lab to a release that supports DuckDB ${FMLAB_DUCKDB_CLI_VER%.*}.   (init continues; this is a recommendation)"
  summary_warn "DuckDB binding    CLI v$FMLAB_DUCKDB_CLI_VER > REST API v$FMLAB_DUCKDB_BINDING_VER (storage mismatch risk — see above)"
}

# Ensure the webbed community extension is loadable for the ACTIVE DuckDB version.
# webbed provides read_xml — the hard core of the convert pipeline. DuckDB stores
# extensions per version, so a DuckDB upgrade (e.g. 1.5.3 → 1.5.4) orphans a
# previously-working webbed: LOAD then fails for the new version until reinstalled.
# Probe LOAD; on failure auto-install from the community repo (needs network) and
# re-probe. Persistent failure is a hard error — without webbed every conversion
# fails with a cascade of "table does not exist". Needs $DUCKDB_BIN + $DUCKDB_VER.
check_webbed_extension() {
  local rc
  "$DUCKDB_BIN" :memory: -c "LOAD webbed;" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    info "webbed extension: loadable"
    return 0
  fi
  warn "webbed extension not loadable for $DUCKDB_VER — installing from the community repo…"
  if "$DUCKDB_BIN" :memory: -c "FORCE INSTALL webbed FROM community; LOAD webbed;" >/dev/null 2>&1; then
    info "webbed extension: installed for $DUCKDB_VER"
    summary_add "webbed            (re)installed for $DUCKDB_VER"
  else
    error "webbed extension could not be installed — the XML conversion needs it (read_xml)."
    echo  "    Fix manually (needs internet):  \"$DUCKDB_BIN\" -c \"FORCE INSTALL webbed FROM community;\""
    echo  "    Note: DuckDB stores extensions per version — reinstall webbed after every DuckDB upgrade."
    summary_warn "webbed            MISSING — run: FORCE INSTALL webbed FROM community;"
    ok=false
  fi
}

# ─── PATH shadowing diagnosis (node / npm) ────────────────────
# An older interpreter EARLIER in PATH silently wins over a freshly installed
# newer one — "I just installed Node 22" and "Node 18 found" are then both true,
# and reinstalling does not help until the PATH order is fixed. Called only when
# a version gate has already failed (so the extra `--version` probes cost nothing
# on a healthy host): name the binary that actually answers, then every other
# candidate we can see — PATH entries in resolution order first, then common
# install prefixes that a fresh install may have missed in PATH.
# Diagnosis only: init never edits a shell profile and never uninstalls anything —
# which binary is supposed to win is the host owner's decision, not ours.
diagnose_tool_path() {
  local name="$1" req_major="$2"
  local active="" search="" origin dir cand ver major
  local seen="" shadowed="" offpath=""

  active=$(command -v "$name" 2>/dev/null || true)

  search=$(printf '%s' "$PATH" | tr ':' '\n' | sed -e 's/^$/./' -e 's/^/P|/')
  for dir in /opt/homebrew/bin /usr/local/bin /usr/bin /opt/local/bin \
             "$HOME/.volta/bin" "$HOME/.local/bin" "$HOME"/.nvm/versions/node/*/bin; do
    [ -d "$dir" ] || continue
    search="$search
X|$dir"
  done

  while IFS='|' read -r origin dir; do
    [ -n "${dir:-}" ] || continue
    cand="$dir/$name"
    [ -x "$cand" ] && [ ! -d "$cand" ] || continue
    case "$seen" in *"[$cand]"*) continue ;; esac
    seen="$seen[$cand]"
    [ "$cand" = "$active" ] && continue
    ver=$("$cand" --version 2>/dev/null | head -1 || true)
    ver="${ver#v}"
    major="${ver%%.*}"; major="${major//[!0-9]/}"
    [ -n "$major" ] || continue
    [ "$major" -ge "$req_major" ] || continue
    if [ "$origin" = "P" ]; then
      shadowed="${shadowed}    Shadowed:      $cand → v$ver  (on PATH, but after the active one)
"
    else
      offpath="${offpath}    Not on PATH:   $cand → v$ver
"
    fi
  done <<EOF
$search
EOF

  if [ -n "$active" ]; then
    echo "    Active binary: $active  (the first $name in PATH)"
  else
    echo "    No $name in PATH at all."
  fi
  printf '%s' "$shadowed$offpath"

  if [ -n "$shadowed$offpath" ]; then
    warn "A suitable $name (≥ $req_major) is already installed — PATH decides which one answers."
    if [ -n "$shadowed" ]; then
      echo "    Installing it again will not help: an older build comes first in PATH."
    else
      echo "    Installing it again will not help: its directory is not on PATH."
    fi
    echo "    Put the directory of the newer $name first in PATH (shell profile, e.g. ~/.zshrc),"
    echo "    open a NEW shell, then re-run this script."
    echo "    Wiki → Troubleshooting → \"Old Node.js or npm keeps winning after an update\"."
    # No summary_add here on purpose: this runs only from a failing gate, and that
    # gate exits before the run summary is ever printed.
  else
    echo "    No newer $name found on this host. List every one PATH can see:  type -a $name"
  fi
  # Never let a diagnosis decide the exit status: a non-zero return here would
  # trip the ERR trap and replace the prerequisite message with a generic abort.
  return 0
}

# ─── Resource floors (advisory) ───────────────────────────────
# Soft thresholds for a comfortable convert of large catalogs. DuckDB's memory peak
# scales with the catalog size and spills to disk; below these floors the convert still
# runs (adaptive OOM-backoff) but slower. WARN only — never abort (mirrors the DuckDB
# baseline pattern). Kept as script defaults for now; a data-driven home next to
# tested_baseline is possible later.
RAM_MIN_GB=6
DISK_MIN_GB=20
check_resources() {
  # ── RAM ── Linux via /proc/meminfo, macOS via sysctl hw.memsize.
  # `|| true` on every probe: a blocked/failing probe command (e.g. sysctl in
  # hardened environments exits non-zero) must not kill an advisory check via
  # set -e — the assignment inherits the substitution's exit status.
  local ram_gb="" kb bytes
  if [ -r /proc/meminfo ]; then
    kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
    if [ -n "$kb" ]; then ram_gb=$(( kb / 1024 / 1024 )); fi
  elif command -v sysctl >/dev/null 2>&1; then
    bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
    if [ -n "$bytes" ]; then ram_gb=$(( bytes / 1024 / 1024 / 1024 )); fi
  fi
  if [ -n "$ram_gb" ]; then
    if [ "$ram_gb" -lt "$RAM_MIN_GB" ]; then
      warn "Only ${ram_gb} GB RAM detected — ≥ ${RAM_MIN_GB} GB recommended for large solutions."
      echo  "    Conversion still works (adaptive OOM-backoff), but large catalogs run slower."
      summary_warn "RAM               ${ram_gb} GB (< ${RAM_MIN_GB} GB recommended)"
    else
      info "RAM: ${ram_gb} GB"
    fi
  fi
  # ── Free disk on the project volume ── POSIX `df -Pk` (portable columns).
  local disk_gb="" avail_kb
  avail_kb=$(df -Pk "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {print $4; exit}' || true)
  if [ -n "$avail_kb" ]; then disk_gb=$(( avail_kb / 1024 / 1024 )); fi
  if [ -n "$disk_gb" ]; then
    if [ "$disk_gb" -lt "$DISK_MIN_GB" ]; then
      warn "Only ${disk_gb} GB free disk on the project volume — ≥ ${DISK_MIN_GB} GB recommended."
      echo  "    The DuckDB catalog + spill can reach double-digit GB on large solutions."
      summary_warn "Disk              ${disk_gb} GB free (< ${DISK_MIN_GB} GB recommended)"
    else
      info "Disk: ${disk_gb} GB free"
    fi
  fi
}

header "fm-lab init"
echo "  Project root: $PROJECT_ROOT"
[ -n "$FMLAB_VERSION" ] && echo "  Version: $FMLAB_VERSION"
[ "$VERBOSE" = true ] && echo "  Mode: verbose (--verbose)"

# ─── OS guard (Windows shells) ────────────────────────────────
# The bash harness (init + convert + server scripts) is only supported on
# macOS/Linux (incl. WSL2). Under Git-Bash / MSYS / Cygwin the run would fail
# diffusely later (paths, `find`, missing tools). Detect it here and point the
# user to the supported Windows path (Docker Desktop + WSL2) — fail early, clearly.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    error "Native Windows shells (Git-Bash / MSYS / Cygwin) are not supported."
    echo  "    On Windows, run fm-lab via Docker Desktop + WSL2 (clone the repo INSIDE the WSL2 filesystem)."
    echo  "    See the README Quickstart → Windows section. Aborting."
    exit 1
    ;;
esac

# ─── Prerequisites ────────────────────────────────────────────

CURRENT_STEP="checking prerequisites"
header "Checking prerequisites"

ok=true

# DuckDB — PATH first, then the installer's locations (see fmlab_find_duckdb)
DUCKDB_BIN=""
DUCKDB_DIR=""
# shellcheck source=lib/duckdb_binding.sh
. "$PROJECT_ROOT/tools/lib/duckdb_binding.sh"
DUCKDB_BIN=$(fmlab_find_duckdb || true)

if [ -n "$DUCKDB_BIN" ]; then
  DUCKDB_VER=$("$DUCKDB_BIN" --version 2>/dev/null | head -1 || echo "unknown")
  DUCKDB_DIR=$(dirname "$DUCKDB_BIN")
  info "DuckDB: $DUCKDB_VER ($DUCKDB_BIN)"
  check_duckdb_baseline "$DUCKDB_VER"
  check_duckdb_binding "$DUCKDB_VER"
  check_webbed_extension
else
  error "DuckDB CLI not found. Install it from https://duckdb.org/docs/installation/"
  ok=false
fi

# Node.js (≥22 — 20.x is end-of-life; the MBS docs reader needs node:sqlite from 22.13)
if command -v node &>/dev/null; then
  NODE_VER=$(node --version)
  NODE_MAJOR=$(major_of "$NODE_VER")
  if [ -z "$NODE_MAJOR" ]; then
    error "Node.js reported an unreadable version: '$NODE_VER' (expected e.g. v22.23.4)."
    diagnose_tool_path node 22
    ok=false
  elif [ "$NODE_MAJOR" -ge 22 ]; then
    info "Node.js: $NODE_VER"
    check_node_security "$NODE_VER"
    check_node_recommended "$NODE_VER"
  else
    error "Node.js $NODE_VER found, but ≥22 is required."
    diagnose_tool_path node 22
    ok=false
  fi
else
  error "Node.js not found. Install it from https://nodejs.org/"
  diagnose_tool_path node 22
  ok=false
fi

# npm (≥10)
if command -v npm &>/dev/null; then
  NPM_VER=$(npm --version)
  NPM_MAJOR=$(major_of "$NPM_VER")
  if [ -z "$NPM_MAJOR" ]; then
    error "npm reported an unreadable version: '$NPM_VER' (expected e.g. 10.9.2)."
    echo  "    npm runs on the node that PATH resolves first — a broken/old node breaks npm too."
    diagnose_tool_path npm 10
    ok=false
  elif [ "$NPM_MAJOR" -ge 10 ]; then
    info "npm: $NPM_VER"
  else
    error "npm $NPM_VER found, but ≥10 is required. Run: npm install -g npm"
    diagnose_tool_path npm 10
    ok=false
  fi
else
  error "npm not found — it ships with Node.js."
  echo  "    → https://docs.npmjs.com/downloading-and-installing-node-js-and-npm"
  diagnose_tool_path npm 10
  ok=false
fi

# Python 3 (optional) — import, analysis, the doc installers and solution.sh run
# on Node; Python serves code generation (fm-generate-script) and Leiden
# clustering (Louvain fallback without it).
# On macOS /usr/bin/python3 is a stub that only works with the Command Line Tools,
# so check xcode-select before running it (avoids the CLT install dialog).
PY3_BIN=$(command -v python3 2>/dev/null || true)
if [ "$PY3_BIN" = /usr/bin/python3 ] && [ "$(uname -s)" = Darwin ] \
   && ! xcode-select -p >/dev/null 2>&1; then
  PY3_BIN=""
fi
if [ -n "$PY3_BIN" ] && PY3_VER=$(python3 --version 2>/dev/null); then
  info "Python: ${PY3_VER#Python } (optional)"
else
  warn "Python 3 not found (optional) — import, analysis and the doc installers work without it."
  echo  "    Needed for code generation (fm-generate-script); graph clustering uses Louvain"
  echo  "    instead of Leiden."
  echo  "    macOS: xcode-select --install (or brew install python3) · Linux: apt install python3"
  summary_warn "python3           not found (optional — code generation, Leiden clustering)"
fi

if [ "$ok" = false ]; then
  echo ""
  error "Prerequisites missing — please install the tools above and run init.sh again."
  exit 1
fi

# ─── Resources (advisory) ─────────────────────────────────────

header "Checking resources (advisory)"
check_resources

# ─── Bootstrap (deps + shared build + env + placeholder DB) ───
# Shared with the Docker `setup` service via tools/bootstrap.sh — single source of
# truth for these idempotent steps, so the native and Docker bootstrap can't drift
# (F-B7). Native-only follow-ups (.claude settings, DuckDB PATH) stay below.

CURRENT_STEP="bootstrapping (npm install / build:shared)"
header "Bootstrapping project (deps + shared build + env; this may take 1–2 minutes)"
cd "$PROJECT_ROOT"
T0=$SECONDS
if [ "$VERBOSE" = true ]; then
  DUCKDB_BIN="$DUCKDB_BIN" bash "$SCRIPT_DIR/bootstrap.sh" "$PROJECT_ROOT"
else
  FMLAB_BOOTSTRAP_QUIET=1 DUCKDB_BIN="$DUCKDB_BIN" bash "$SCRIPT_DIR/bootstrap.sh" "$PROJECT_ROOT"
fi
PKG_COUNT=$(find node_modules -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
info "Bootstrap done — deps + shared build + env + placeholder DB (~${PKG_COUNT} packages, $((SECONDS - T0))s)"
summary_add "bootstrap         npm install + build:shared + env + placeholder DB (~${PKG_COUNT} pkgs, $((SECONDS - T0))s)"

# ─── .claude/settings.json ────────────────────────────────────

header "Claude Code settings"
SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
  mkdir -p "$PROJECT_ROOT/.claude"
  cat > "$SETTINGS_FILE" <<'SETTINGSEOF'
{
  "permissions": {
    "allow": [
      "Bash(npm:*)",
      "Bash(duckdb:*)",
      "Bash(/usr/local/bin/duckdb:*)",
      "Bash(/opt/homebrew/bin/duckdb:*)",
      "Bash(.claude/skills/*)",
      "Bash(bash .claude/skills/*)",
      "Bash(node .claude/skills/*)",
      "Bash(python3 .claude/skills/*)",
      "Bash(bash tools/*)",
      "Bash(tools/*)",
      "Bash(./tools/*)"
    ]
  },
  "extraKnownMarketplaces": {
    "duckdb-skills": {
      "source": { "source": "github", "repo": "duckdb/duckdb-skills" }
    }
  },
  "enabledPlugins": {
    "duckdb-skills@duckdb-skills": true
  }
}
SETTINGSEOF
  info "Created .claude/settings.json"
  summary_add "Claude settings   .claude/settings.json created"
else
  info ".claude/settings.json already exists"
  summary_add "Claude settings   already present (skipped)"
fi

# ─── DuckDB path → .claude/settings.json ─────────────────────
# VS Code / Claude Code inherits a restricted PATH and may not find DuckDB.
# We write the resolved binary directory into env.PATH so Claude Code can
# always locate duckdb without trying to install it. The resolved directory goes
# first, and every other DuckDB-installer directory (~/.duckdb/cli/<version>,
# ~/.duckdb/cli/latest) is dropped — otherwise each init run with another version
# stacked one more entry and an old version folder could shadow the current one.

if [ -n "$DUCKDB_DIR" ] && [ -f "$SETTINGS_FILE" ]; then
  export DUCKDB_DIR PROJECT_ROOT
  path_result=$(node - <<'NODEEOF'
const fs = require('fs');
const os = require('os');
const path = require('path');
const settingsPath = process.env.PROJECT_ROOT + '/.claude/settings.json';
const duckdbDir   = process.env.DUCKDB_DIR;
const settings    = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
settings.env      = settings.env || {};
const existingPath = settings.env.PATH || '';
// Keep the rest of an explicit PATH; without one fall back to common system dirs
// so other tools still work.
const base = (existingPath || '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin').split(':').filter(Boolean);
const installerRoot = path.join(os.homedir(), '.duckdb', 'cli') + path.sep;
const rest = base.filter((p) => p !== duckdbDir && !p.startsWith(installerRoot));
const next = [duckdbDir, ...rest].join(':');
if (next !== existingPath) {
  settings.env.PATH = next;
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
  process.stdout.write('changed');
} else {
  process.stdout.write('unchanged');
}
NODEEOF
)
  if [ "$path_result" = "changed" ]; then
    info "DuckDB path written to .claude/settings.json"
    summary_add "Claude Code PATH  $DUCKDB_DIR set first in .claude/settings.json"
  else
    info "DuckDB path already set in .claude/settings.json"
  fi
fi

# ─── Logs directory ───────────────────────────────────────────

mkdir -p "$PROJECT_ROOT/logs"

# ─── XML conversion ───────────────────────────────────────────

header "FileMaker XML export"
CURRENT_STEP="scanning XML inbox"

# XML inbox of the default solution (multi-solution layout); a flat pre-migration
# xml/ still counts — convert_fm_xml.sh reads it as the 'default' inbox.
# Ensure the inbox exists (git doesn't track empty dirs, so a fresh clone lacks it)
# and only search paths that actually exist: `find` exits non-zero on a missing path,
# which under `set -euo pipefail` aborts init before the empty-state branch below.
XML_INBOX="$PROJECT_ROOT/solutions/default/xml"
mkdir -p "$XML_INBOX"
XML_SEARCH_PATHS=("$XML_INBOX")
[ -d "$PROJECT_ROOT/xml" ] && XML_SEARCH_PATHS+=("$PROJECT_ROOT/xml")
XML_FILES=$(find "${XML_SEARCH_PATHS[@]}" -maxdepth 1 -name "*.xml" 2>/dev/null | wc -l | tr -d ' ')

# Start (or restart) the servers and record what actually happened in the summary.
# --restart-running: the bootstrap above just ran npm install + build:shared, and a
# server started before it keeps serving the old build (Vite even keeps an import of
# packages/shared that failed while dist/ was missing) — so running servers are restarted
# instead of re-attached. start-servers.sh reports the per-server state via a status file.
start_servers() {
  local status_file api_state="" fe_state="" line
  status_file=$(mktemp "${TMPDIR:-/tmp}/fmlab-start-status.XXXXXX")
  if ! FMLAB_START_STATUS_FILE="$status_file" bash "$SCRIPT_DIR/start-servers.sh" --restart-running; then
    rm -f "$status_file"
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      api=*)      api_state=${line#api=} ;;
      frontend=*) fe_state=${line#frontend=} ;;
    esac
  done < "$status_file"
  rm -f "$status_file"
  if [ "$api_state" = "running" ] || [ "$fe_state" = "running" ]; then
    summary_warn "servers           already running, not restarted (api: ${api_state:-?}, frontend: ${fe_state:-?}) — restart with tools/stop-servers.sh && tools/start-servers.sh"
  else
    local label="servers started"
    if [ "$api_state" = "restarted" ] || [ "$fe_state" = "restarted" ]; then
      label="servers restarted"
    fi
    summary_add "$(printf '%-18s' "$label")http://localhost:3003  |  http://localhost:5173"
  fi
}

print_summary() {
  local elapsed=$((SECONDS - INIT_START))
  echo ""
  echo -e "${BOLD}══════════════════════════════════════${NC}"
  echo -e "${BOLD}fm-lab setup complete (${elapsed}s)${NC}"
  echo ""
  for line in "${SUMMARY[@]}"; do
    case "$line" in
      '!'*) echo -e "  ${YELLOW}⚠${NC} ${line#!}" ;;
      *)    echo -e "  ${GREEN}✓${NC} $line" ;;
    esac
  done
  echo -e "${BOLD}══════════════════════════════════════${NC}"
}

if [ "$XML_FILES" -eq 0 ]; then
  warn "No XML files found in solutions/default/xml/."
  summary_add "XML conversion    skipped (no XML files yet)"

  # bootstrap.sh already seeded the empty placeholder catalog, so the READ_ONLY API can
  # boot on a fresh clone BEFORE any XML is converted (same as the Docker `setup`
  # service). Start the servers so the web client's guided empty-state card takes over
  # immediately (export instructions → open folder → one-click convert, live progress) —
  # the native path reaches the same betriebsbereit UX as Docker.
  header "Starting servers"
  if [ -f "$PROJECT_ROOT/rest-api/db/fm_catalog.duckdb" ] && start_servers; then
    print_summary
    echo ""
    echo "  → Open http://localhost:5173 — the guided empty-state walks you through"
    echo "    exporting your FileMaker solution and converting it (one click, live progress)."
    echo ""
    echo "  CLI alternative: drop .xml file(s) into solutions/default/xml/ and run  bash ingestion/convert_fm_xml.sh --batch"
    echo ""
    exit 0
  fi

  # Fallback: no placeholder DB (DuckDB missing) or server start failed → guide by text.
  print_summary
  echo ""
  echo "  Next step:"
  echo "  1. Export your FileMaker solution via 'Tools > Save a Copy As XML' + Option 'Include details for analysis tools'"
  echo "  2. Place the .xml file in solutions/default/xml/"
  echo "  3. Run:  bash ingestion/convert_fm_xml.sh --batch"
  echo "           (adaptive: chunked streaming + OOM-backoff automatically; even large solutions on tight RAM)"
  echo "  4. Then: bash tools/start-servers.sh"
  echo ""
  exit 0
fi

# ─── Start servers BEFORE the convert ─────────────────────────
# bootstrap.sh already seeded the placeholder catalog, so the READ_ONLY API boots now
# and the web client is up while the convert runs. In production mode (--batch) the
# convert syncs the finished catalog to the API copy and triggers /api/admin/reload, so
# the already-running server picks up the real data automatically — no restart. The
# web client sees the run's lock: it shows "running in the terminal" instead of offering
# a second start (a terminal run sends no events, so its progress shows only here).
CURRENT_STEP="starting servers"
header "Starting servers"
start_servers

# --batch picks the adaptive default itself (Turbo + --auto OOM-backoff, plus SAX
# streaming when the patched webbed is present) — no manual mode flag needed; it
# never hard-aborts on tight RAM. FM_FORCE_DOM=1 keeps turbo+auto but on DOM.
# --changed-only (same default as the web convert button): an unchanged XML inbox is
# skipped via the manifest instead of re-importing on every start; a converter or
# schema change after an update still triggers the full re-conversion (version gate).
CURRENT_STEP="converting XML (bash ingestion/convert_fm_xml.sh --batch --changed-only)"
header "FileMaker XML conversion"
CONVERT_ARGS=(--batch --changed-only)
info "Found $XML_FILES XML file(s) — converting changed files only (adaptive mode)"
# Progress of this terminal run shows only here; the web client marks the run as
# active (no second start) and shows the data once it is done.
echo "  Progress shows below. The web client (http://localhost:5173) shows the data when the conversion is done."
T0=$SECONDS
bash "$SCRIPT_DIR/convert_fm_xml.sh" "${CONVERT_ARGS[@]}"
summary_add "XML conversion    $XML_FILES file(s) → fm_catalog.duckdb ($((SECONDS - T0))s)"

print_summary
echo ""
echo "  Web Client:  http://localhost:5173"
echo "  REST API:    http://localhost:3003"
