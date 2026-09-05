#!/usr/bin/env bash
#
# cluster.sh — Community-Detection batch (P5)
#
# Builds ObjectClusters + CommunityNames in the master DB from the cleaned
# logical graph. Engine: Louvain (Node/graphology) by default, Leiden
# (Python/igraph) when available. Standalone batch — NOT a convert-xml phase
# yet (wire in only after the perf numbers below justify it).
#
# Pipeline:
#   1. duckdb master < graph_export_logical.sql   → edges.csv  (logical, no builtins/orphans)
#   2. <engine>      edges.csv communities.csv     → node→community
#   3. duckdb master . cluster_load.sql            → ObjectClusters + CommunityNames (heuristic names)
#   4. (opt) sync master → rest-api/db + /api/admin/reload
#
# Env knobs:
#   FMLAB_CLUSTER_ENGINE      auto | leiden | louvain     (default: cluster.json, else auto)
#   FMLAB_CLUSTER_RESOLUTION  Louvain/Leiden resolution   (default: cluster.json, else 1.0)
#   FMLAB_CLUSTER_SEED        PRNG seed (reproducible)     (default: cluster.json, else 42)
#   Defaults come from solutions/<id>/state/cluster.json — the persisted
#   fm-graph-cluster sweep winner (tools/lib/cluster_config.sh).
#   FMLAB_CLUSTER_NO_SYNC     set to 1 to skip rest-api sync/reload
#   REST_API_RELOAD_URL       reload endpoint              (default localhost:3003)
#
# bash-3.2 compatible (macOS system bash): no `case` inside $(…), no bash-4+ features.

set -u

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Multi-solution: writers operate on the REAL bundle path, never through the
# db/ compat symlink. Shared cascade (tools/lib/resolve_solution.sh):
# FMLAB_SOLUTION env / FMLAB_CONTEXT file → pointer → 'default';
# unmigrated workspaces fall back to the flat db/ path.
. "$PROJECT_ROOT/tools/lib/resolve_solution.sh"
fmlab_resolve_solution || exit 1
SOLUTION="$FMLAB_RESOLVED_SOLUTION"
if [ -f "$PROJECT_ROOT/solutions/$SOLUTION/db/fm_catalog.duckdb" ]; then
  _DEFAULT_DB="$PROJECT_ROOT/solutions/$SOLUTION/db/fm_catalog.duckdb"
else
  _DEFAULT_DB="$PROJECT_ROOT/db/fm_catalog.duckdb"
fi
# DB_FILE override (FMLAB_CLUSTER_DB) — default master; lets tests run against a
# throwaway copy without touching the production DB. Sync still targets rest-api.
DB_FILE="${FMLAB_CLUSTER_DB:-$_DEFAULT_DB}"
EXPORT_SQL="$SCRIPT_DIR/graph_export_logical.sql"
LOAD_SQL="$SCRIPT_DIR/cluster_load.sql"
CACHE_SAVE_SQL="$SCRIPT_DIR/cache_save.sql"
CACHE_APPLY_SQL="$SCRIPT_DIR/cache_apply.sql"

# RESOLUTION / SEED / engine default are set below, after the duckdb binary is
# located: the defaults come from the persisted sweep winner (cluster.json).
# rest-api sync paths/URL live in sync_db.sh (step 5 delegates to it).

# ── Semantic-Name cache knobs ──────────────────────────────────────────────
CACHE_DISABLE="${FMLAB_CACHE_DISABLE:-0}"
CACHE_TAU_PURITY="${FMLAB_CACHE_TAU_PURITY:-0.6}"
CACHE_TAU_COVERAGE="${FMLAB_CACHE_TAU_COVERAGE:-0.5}"
CACHE_FLOOR="${FMLAB_CACHE_FLOOR:-0.5}"

# ── Locate duckdb (docs/agents/tooling.md well-known locations) ─────────────
DUCKDB=""
if command -v duckdb >/dev/null 2>&1; then
  DUCKDB="$(command -v duckdb)"
elif [ -x "$HOME/.duckdb/cli/latest/duckdb" ]; then
  DUCKDB="$HOME/.duckdb/cli/latest/duckdb"
elif [ -x "/opt/homebrew/bin/duckdb" ]; then
  DUCKDB="/opt/homebrew/bin/duckdb"
elif [ -x "/usr/local/bin/duckdb" ]; then
  DUCKDB="/usr/local/bin/duckdb"
else
  echo "ERROR: duckdb binary not found (see docs/agents/tooling.md for install locations)." >&2
  exit 3
fi

if [ ! -f "$DB_FILE" ]; then
  echo "ERROR: master DB not found at $DB_FILE — run convert-xml first." >&2
  exit 4
fi

# ── Granularity defaults: solutions/<id>/state/cluster.json (sweep winner) ──
# Same reader as the pipeline's Phase 7 (tools/lib/cluster_config.sh). Env knobs
# FMLAB_CLUSTER_* still override; without the file the classic defaults apply
# (auto|1.0|42). Previously a bare cluster.sh run always used 1.0 and silently
# re-partitioned at a different granularity than the sweep — invalidating names.
. "$PROJECT_ROOT/tools/lib/cluster_config.sh"
_CFG_DIR="$PROJECT_ROOT/solutions/$SOLUTION/state"
[ -d "$PROJECT_ROOT/solutions/$SOLUTION" ] || _CFG_DIR="$PROJECT_ROOT/.fmlab"
_CFG=$(fmlab_read_cluster_config "$_CFG_DIR" "$DUCKDB")
CFG_ENGINE="${_CFG%%|*}"; _CFG_REST="${_CFG#*|}"
CFG_RESOLUTION="${_CFG_REST%%|*}"; CFG_SEED="${_CFG_REST##*|}"
RESOLUTION="${FMLAB_CLUSTER_RESOLUTION:-$CFG_RESOLUTION}"
SEED="${FMLAB_CLUSTER_SEED:-$CFG_SEED}"
if [ -f "$_CFG_DIR/cluster.json" ]; then
  echo "granularity: cluster.json → engine=$CFG_ENGINE resolution=$CFG_RESOLUTION seed=$CFG_SEED (env overrides win)"
else
  echo "granularity: no cluster.json — defaults (run /fm-graph-cluster for a sweep)"
fi

# ── Engine detection / dispatch ─────────────────────────────────────────────
ENGINE="${FMLAB_CLUSTER_ENGINE:-$CFG_ENGINE}"
if [ "$ENGINE" = "auto" ]; then
  if command -v python3 >/dev/null 2>&1 && python3 -c "import igraph" >/dev/null 2>&1; then
    ENGINE="leiden"
  else
    ENGINE="louvain"   # guaranteed Node/npm fallback
  fi
elif [ "$ENGINE" = "leiden" ]; then
  if ! { command -v python3 >/dev/null 2>&1 && python3 -c "import igraph" >/dev/null 2>&1; }; then
    echo "ERROR: FMLAB_CLUSTER_ENGINE=leiden but python3+igraph not available." >&2
    exit 5
  fi
fi
echo "cluster engine: $ENGINE (resolution=$RESOLUTION seed=$SEED)"

# ── Work dir (temp CSVs land here; duckdb COPY/read_csv are CWD-relative) ────
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/fmlab-cluster.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
cd "$WORKDIR" || { echo "ERROR: cannot enter workdir $WORKDIR" >&2; exit 6; }

# ── 1) Export cleaned logical edges → edges.csv ─────────────────────────────
echo "→ exporting logical edges …"
T_EXPORT_START=$(date +%s)
if ! "$DUCKDB" "$DB_FILE" -readonly < "$EXPORT_SQL"; then
  echo "ERROR: edge export failed (is the master DB locked by convert-xml?)." >&2
  exit 7
fi
EDGE_COUNT=$(($(wc -l < edges.csv) - 1))
T_EXPORT_END=$(date +%s)
echo "  edges.csv: $EDGE_COUNT edges in $((T_EXPORT_END - T_EXPORT_START))s"

# ── 2) Cluster → communities.csv ────────────────────────────────────────────
# Die Engine schreibt ihre Kennzahl-Zeile (`[engine] nodes=… edges=… communities=…
# modularity=… resolution=… seed=…`) auf stderr. Wir fangen stderr in eine Datei,
# um modularity/nodes für die Run-Summary (Schritt 4b) zu parsen, und spiegeln sie
# danach unverändert nach stderr (Recluster-/Skill-Log sieht sie wie bisher).
echo "→ clustering ($ENGINE) …"
ENGINE_STATS_FILE="$WORKDIR/engine_stats.txt"
T_CLUSTER_START=$(date +%s)
if [ "$ENGINE" = "leiden" ]; then
  python3 "$SCRIPT_DIR/cluster_leiden.py" edges.csv communities.csv "$RESOLUTION" "$SEED" 2> "$ENGINE_STATS_FILE" || {
    cat "$ENGINE_STATS_FILE" >&2
    echo "ERROR: leiden clustering failed." >&2; exit 8; }
else
  node "$SCRIPT_DIR/cluster_louvain.mjs" edges.csv communities.csv "$RESOLUTION" "$SEED" 2> "$ENGINE_STATS_FILE" || {
    cat "$ENGINE_STATS_FILE" >&2
    echo "ERROR: louvain clustering failed." >&2; exit 8; }
fi
cat "$ENGINE_STATS_FILE" >&2
T_CLUSTER_END=$(date +%s)
echo "  clustering wall-clock: $((T_CLUSTER_END - T_CLUSTER_START))s"

# ── 3a) Cache-Save: bestehende Semantic_Name auf Objekt-Ebene sichern ───────
# VOR dem Replace (Schritt 3). Nur wenn CommunityNames bereits benannte Module
# trägt — sonst würde ein leerer Snapshot einen guten Cache überschreiben.
if [ "$CACHE_DISABLE" != "1" ]; then
  HAS_CN=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='CommunityNames';" 2>/dev/null || echo 0)
  SEM_COUNT=0
  if [ "$HAS_CN" = "1" ]; then
    SEM_COUNT=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
      "SELECT COUNT(*) FROM CommunityNames WHERE Semantic_Name IS NOT NULL;" 2>/dev/null || echo 0)
  fi
  if [ "${SEM_COUNT:-0}" -gt 0 ]; then
    echo "→ cache-save: snapshotting $SEM_COUNT named communities (object-level) …"
    "$DUCKDB" "$DB_FILE" <<SQL || echo "  WARN: cache-save failed (continuing)" >&2
SET VARIABLE resolution = $RESOLUTION;
.read "$CACHE_SAVE_SQL"
SQL
  fi
fi

# ── 3) Load communities + build heuristic names ─────────────────────────────
echo "→ loading ObjectClusters + CommunityNames …"
"$DUCKDB" "$DB_FILE" <<SQL || { echo "ERROR: cluster load failed." >&2; exit 9; }
SET VARIABLE engine = '$ENGINE';
.read "$LOAD_SQL"
SQL

# ── 3c) Cache-Apply: Semantic_Name per Mehrheitsvotum restaurieren ──────────
# NACH dem Load (CommunityNames.Semantic_Name=NULL).
if [ "$CACHE_DISABLE" != "1" ]; then
  HAS_CACHE=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='SemanticNameCache';" 2>/dev/null || echo 0)
  CACHE_ROWS=0
  if [ "$HAS_CACHE" = "1" ]; then
    CACHE_ROWS=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
      "SELECT COUNT(*) FROM SemanticNameCache;" 2>/dev/null || echo 0)
  fi
  if [ "${CACHE_ROWS:-0}" -gt 0 ]; then
    echo "→ cache-apply: restoring names via majority vote (τ_purity=$CACHE_TAU_PURITY τ_coverage=$CACHE_TAU_COVERAGE) …"
    "$DUCKDB" "$DB_FILE" <<SQL || echo "  WARN: cache-apply failed (continuing)" >&2
SET VARIABLE tau_purity = $CACHE_TAU_PURITY;
SET VARIABLE tau_coverage = $CACHE_TAU_COVERAGE;
.read "$CACHE_APPLY_SQL"
SQL
    REUSE=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
      "SELECT ROUND(COALESCE(SUM(Member_Count) FILTER (WHERE Semantic_Name IS NOT NULL),0)::DOUBLE / SUM(Member_Count), 4) FROM CommunityNames;" 2>/dev/null || echo 0)
    NAMED=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
      "SELECT COUNT(*) FILTER (WHERE Semantic_Name IS NOT NULL) FROM CommunityNames;" 2>/dev/null || echo 0)
    TOTAL=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
      "SELECT COUNT(*) FROM CommunityNames;" 2>/dev/null || echo 0)
    echo "  cache: restored $NAMED/$TOTAL communities, node-reuse=$REUSE (floor=$CACHE_FLOOR)"
    # Floor-Check (advisory). bash-3.2 kann kein Float → awk-Vergleich.
    BELOW=$(awk "BEGIN{print (($REUSE) < ($CACHE_FLOOR)) ? 1 : 0}" 2>/dev/null || echo 0)
    if [ "$BELOW" = "1" ]; then
      echo "  WARN: node-reuse $REUSE < floor $CACHE_FLOOR — Partition stark gedriftet; Voll-Re-Naming via /fm-graph-cluster empfohlen." >&2
    fi
  else
    echo "  cache: empty (first run / no prior names) — skipping restore"
  fi
fi

# ── 4) Report ───────────────────────────────────────────────────────────────
echo "→ result:"
"$DUCKDB" "$DB_FILE" -readonly -c "
  SELECT
    (SELECT COUNT(*) FROM ObjectClusters)                       AS clustered_objects,
    (SELECT COUNT(*) FROM CommunityNames)                       AS communities,
    (SELECT MAX(Member_Count) FROM CommunityNames)              AS largest_community,
    (SELECT ROUND(AVG(Member_Count), 1) FROM CommunityNames)    AS avg_size;
  SELECT Community, Member_Count, Dominant_Type, Heuristic_Name
  FROM CommunityNames ORDER BY Member_Count DESC LIMIT 8;
"

# ── 4b) Run-Summary → .fmlab/cluster_run.json ───────────────────────────────
# Persistiert die bereits berechneten Lauf-Metriken maschinenlesbar für die
# /cluster-Status-Leiste. modularity/edges lassen sich nicht
# billig live nachrechnen (Modularity kennt nur die Engine; ClusterEdges ist eine
# teure View) → hier als JSON sichern. Greift uniform für alle Lauf-Pfade (Skill
# Phase H, Auto-P7, Recluster-Button) — alle rufen cluster.sh. Abgrenzung:
# .fmlab/cluster.json bleibt die Config-für-Reuse; cluster_run.json ist das
# Ergebnis-für-Anzeige (jeder Lauf). Additiver Write, best-effort.
RUN_NODES=$(sed -n 's/.*nodes=\([0-9][0-9]*\).*/\1/p' "$ENGINE_STATS_FILE" 2>/dev/null | tail -1)
RUN_MOD=$(sed -n 's/.*modularity=\([0-9][0-9.]*\).*/\1/p' "$ENGINE_STATS_FILE" 2>/dev/null | tail -1)
RUN_COMMUNITIES=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
  "SELECT COUNT(*) FROM CommunityNames;" 2>/dev/null || echo "")
RUN_NAMED=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
  "SELECT COUNT(*) FILTER (WHERE Semantic_Name IS NOT NULL) FROM CommunityNames;" 2>/dev/null || echo "")
RUN_FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Per-solution state (bundle); unmigrated workspaces fall back to flat .fmlab/.
RUN_DIR="$PROJECT_ROOT/solutions/$SOLUTION/state"
[ -d "$RUN_DIR" ] || RUN_DIR="$PROJECT_ROOT/.fmlab"
RUN_JSON="$RUN_DIR/cluster_run.json"
# Numerisches JSON-Feld: leer → null, sonst Roh-Zahl (kein Quoting).
jnum() { if [ -z "$1" ]; then printf 'null'; else printf '%s' "$1"; fi; }
mkdir -p "$RUN_DIR" 2>/dev/null
{
  printf '{\n'
  printf '  "engine": "%s",\n'        "$ENGINE"
  printf '  "resolution": %s,\n'      "$(jnum "$RESOLUTION")"
  printf '  "seed": %s,\n'            "$(jnum "$SEED")"
  printf '  "modularity_q": %s,\n'    "$(jnum "$RUN_MOD")"
  printf '  "n_nodes": %s,\n'         "$(jnum "$RUN_NODES")"
  printf '  "n_edges": %s,\n'         "$(jnum "$EDGE_COUNT")"
  printf '  "n_communities": %s,\n'   "$(jnum "$RUN_COMMUNITIES")"
  printf '  "n_named": %s,\n'         "$(jnum "$RUN_NAMED")"
  printf '  "finished_at": "%s"\n'    "$RUN_FINISHED"
  printf '}\n'
} > "$RUN_JSON" 2>/dev/null \
  && echo "  run-summary → $RUN_JSON (modularity=$RUN_MOD nodes=$RUN_NODES)" \
  || echo "  WARN: could not write cluster_run.json" >&2

# ── 5) Sync master → rest-api copy + reload (optional) ──────────────────────
# Sync logic lives in sync_db.sh (reused by the fm-graph-cluster skill); the
# NO_SYNC gate stays here so cluster.sh's own behaviour is unchanged.
if [ "${FMLAB_CLUSTER_NO_SYNC:-0}" != "1" ]; then
  FMLAB_SOLUTION="$SOLUTION" bash "$SCRIPT_DIR/sync_db.sh" "$DB_FILE" || echo "  WARN: sync step failed" >&2
fi

echo "done."
