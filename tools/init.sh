#!/usr/bin/env bash
# init.sh — First-time setup for fm-lab
# -E (errtrace): without it the ERR trap below is not inherited by shell
# functions, so any failure inside a function died silently despite F-A7.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT_START=$SECONDS

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

# Warn (recommendation only) when DuckDB is older than the tested baseline.
check_duckdb_baseline() {
  local installed_raw="$1" base_duckdb="" base_webbed="" base_url="" installed
  if [ -f "$VERSION_MANIFEST" ] && command -v jq >/dev/null 2>&1; then
    base_duckdb=$(jq -r '.tested_baseline.duckdb_min_version // empty' "$VERSION_MANIFEST" 2>/dev/null)
    base_webbed=$(jq -r '.tested_baseline.webbed_min_version // empty' "$VERSION_MANIFEST" 2>/dev/null)
    base_url=$(jq -r '.tested_baseline.update_url // empty' "$VERSION_MANIFEST" 2>/dev/null)
  fi
  # Fallback if the manifest or jq is unavailable — never let the check itself fail.
  [ -n "$base_duckdb" ] || base_duckdb="1.5.4"
  [ -n "$base_webbed" ] || base_webbed="2.2.1"
  [ -n "$base_url" ]    || base_url="https://duckdb.org/docs/installation/"

  # Extract the numeric version, e.g. "1.5.4" from "v1.5.4 (Variegata) 08e34c447b".
  installed=$(printf '%s' "$installed_raw" | sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/')
  case "$installed" in
    ''|*[!0-9.]*) return 0 ;;   # couldn't parse a version → stay silent
  esac

  if [ "$(version_cmp "$installed" "$base_duckdb")" = "-1" ]; then
    warn "DuckDB $installed is older than the tested fm-lab baseline (v$base_duckdb + webbed $base_webbed)."
    echo  "    Recommended: update DuckDB to ≥ $base_duckdb — the validated setup for webbed $base_webbed."
    echo  "    → $base_url   (init continues; this is a recommendation, not a requirement)"
    summary_add "DuckDB baseline   v$installed < v$base_duckdb (update recommended — see above)"
  fi
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
    summary_add "webbed            MISSING — run: FORCE INSTALL webbed FROM community;"
    ok=false
  fi
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
      summary_add "RAM               ${ram_gb} GB (< ${RAM_MIN_GB} GB recommended)"
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
      summary_add "Disk              ${disk_gb} GB free (< ${DISK_MIN_GB} GB recommended)"
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

# DuckDB — check PATH first, then common install locations
DUCKDB_BIN=""
DUCKDB_DIR=""
if command -v duckdb &>/dev/null; then
  DUCKDB_BIN=$(command -v duckdb)
else
  for candidate in \
    "$HOME/.duckdb/cli/latest/duckdb" \
    "/opt/homebrew/bin/duckdb" \
    "/usr/local/bin/duckdb"; do
    if [ -x "$candidate" ]; then
      DUCKDB_BIN="$candidate"
      break
    fi
  done
fi

if [ -n "$DUCKDB_BIN" ]; then
  DUCKDB_VER=$("$DUCKDB_BIN" --version 2>/dev/null | head -1 || echo "unknown")
  DUCKDB_DIR=$(dirname "$DUCKDB_BIN")
  info "DuckDB: $DUCKDB_VER ($DUCKDB_BIN)"
  check_duckdb_baseline "$DUCKDB_VER"
  check_webbed_extension
else
  error "DuckDB CLI not found. Install it from https://duckdb.org/docs/installation/"
  ok=false
fi

# Node.js (≥20)
if command -v node &>/dev/null; then
  NODE_VER=$(node --version)
  NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v\([0-9]*\).*/\1/')
  if [ "$NODE_MAJOR" -ge 20 ]; then
    info "Node.js: $NODE_VER"
  else
    error "Node.js $NODE_VER found, but ≥20 is required."
    ok=false
  fi
else
  error "Node.js not found. Install it from https://nodejs.org/"
  ok=false
fi

# npm (≥10)
if command -v npm &>/dev/null; then
  NPM_VER=$(npm --version)
  NPM_MAJOR=$(echo "$NPM_VER" | sed 's/\([0-9]*\).*/\1/')
  if [ "$NPM_MAJOR" -ge 10 ]; then
    info "npm: $NPM_VER"
  else
    error "npm $NPM_VER found, but ≥10 is required. Run: npm install -g npm"
    ok=false
  fi
else
  error "npm not found."
  ok=false
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
  summary_add "Claude settings    .claude/settings.json created"
else
  info ".claude/settings.json already exists"
  summary_add "Claude settings    already present (skipped)"
fi

# ─── DuckDB path → .claude/settings.json ─────────────────────
# VS Code / Claude Code inherits a restricted PATH and may not find DuckDB.
# We write the resolved binary directory into env.PATH so Claude Code can
# always locate duckdb without trying to install it.

if [ -n "$DUCKDB_DIR" ] && [ -f "$SETTINGS_FILE" ]; then
  export DUCKDB_DIR PROJECT_ROOT
  node - <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const settingsPath = process.env.PROJECT_ROOT + '/.claude/settings.json';
const duckdbDir   = process.env.DUCKDB_DIR;
const settings    = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
settings.env      = settings.env || {};
const existingPath = settings.env.PATH || '';
if (!existingPath.split(':').includes(duckdbDir)) {
  // Prepend duckdb dir; keep the rest of the explicit PATH if already set,
  // otherwise fall back to common system dirs so other tools still work.
  const base = existingPath || '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin';
  settings.env.PATH = duckdbDir + ':' + base;
}
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
NODEEOF
  info "DuckDB path written to .claude/settings.json"
  summary_add "Claude Code PATH   $DUCKDB_DIR added to .claude/settings.json"
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

print_summary() {
  local elapsed=$((SECONDS - INIT_START))
  echo ""
  echo -e "${BOLD}══════════════════════════════════════${NC}"
  echo -e "${BOLD}fm-lab setup complete (${elapsed}s)${NC}"
  echo ""
  for line in "${SUMMARY[@]}"; do
    echo -e "  ${GREEN}✓${NC} $line"
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
  if [ -f "$PROJECT_ROOT/rest-api/db/fm_catalog.duckdb" ] && bash "$SCRIPT_DIR/start-servers.sh"; then
    summary_add "servers started   http://localhost:3003  |  http://localhost:5173"
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
# the already-running server picks up the real data automatically — no restart, and the
# progress is watchable in the browser instead of a blocking terminal phase (F-A4).
CURRENT_STEP="starting servers"
header "Starting servers"
bash "$SCRIPT_DIR/start-servers.sh"
summary_add "servers started   http://localhost:3003  |  http://localhost:5173"

# --batch picks the adaptive default itself (Turbo + --auto OOM-backoff, plus SAX
# streaming when the patched webbed is present) — no manual mode flag needed; it
# never hard-aborts on tight RAM. FM_FORCE_DOM=1 keeps turbo+auto but on DOM.
CURRENT_STEP="converting XML (bash ingestion/convert_fm_xml.sh --batch)"
header "FileMaker XML conversion"
CONVERT_ARGS=(--batch)
info "Found $XML_FILES XML file(s) — starting conversion (adaptive mode)"
echo "  Follow live progress in the web client:  http://localhost:5173  (XML import dashboard)"
T0=$SECONDS
bash "$SCRIPT_DIR/convert_fm_xml.sh" "${CONVERT_ARGS[@]}"
summary_add "XML conversion    $XML_FILES file(s) → fm_catalog.duckdb ($((SECONDS - T0))s)"

print_summary
echo ""
echo "  Web Client:  http://localhost:5173"
echo "  REST API:    http://localhost:3003"
