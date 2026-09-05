#!/usr/bin/env bash
# cluster_state.sh — readiness of the cluster layer for ONE solution. Read-only; JSON on stdout.
#
# Shared by fm-graph-cluster (Preflight: warns on granularity drift) and fm-deep-research
# (readiness gate before writing a report). Sources, all best-effort:
#   master DB   ObjectClusters / CommunityNames / SemanticNameCache / FilesCatalog / ClusterEdges view
#   state dir   solutions/<id>/state/{cluster.json, cluster_run.json, last_xml_run.json}
#   sidecar     solutions/<id>/db/fm_annotations.duckdb → CommunityAnnotation (user names)
#
# Usage:  bash .claude/skills/_shared/scripts/cluster_state.sh [--solution <id>]
# Exit:   0 = JSON written (see "level") · 2 = usage · 3 = no duckdb · 4 = master DB missing
#
# Levels (decision rule of the fm-deep-research readiness gate):
#   L0  no partition (ObjectClusters missing/empty)
#   L1  partition present but raw: never swept (no cluster.json), or the last run's
#       resolution/engine differs from the sweep winner, or no run summary
#       (resolution unknown)
#   L2  swept partition — cluster.json ≙ cluster_run.json
# Band = the sweep rubric (sweep.mjs): mean module size 30–150 ⇒ K in [n/150, n/30],
# soft floor n_files. "k_out_of_band" is a flag, not a level trigger: the sweep's
# band penalty is soft, so a legitimate winner may sit outside the band (small
# solutions). It strengthens the recommendation to sweep only for raw partitions.
#
# bash-3.2 compatible (macOS system bash): no case in $(…), no bash-4+ features.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

EXPLICIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --solution) shift; EXPLICIT="${1:-}" ;;
    --solution=*) EXPLICIT="${1#--solution=}" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 2 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

# ── Solution (shared cascade: flag → env/context → pointer → default) ────────
. "$PROJECT_ROOT/tools/lib/resolve_solution.sh"
fmlab_resolve_solution "$EXPLICIT" || exit 2
SOLUTION="$FMLAB_RESOLVED_SOLUTION"
SOURCE="$FMLAB_RESOLVED_SOURCE"
BUNDLE="$PROJECT_ROOT/solutions/$SOLUTION"
if [ -f "$BUNDLE/db/fm_catalog.duckdb" ]; then
  DB_FILE="$BUNDLE/db/fm_catalog.duckdb"; DB_REL="solutions/$SOLUTION/db/fm_catalog.duckdb"
  STATE_DIR="$BUNDLE/state"
else
  DB_FILE="$PROJECT_ROOT/db/fm_catalog.duckdb"; DB_REL="db/fm_catalog.duckdb"
  STATE_DIR="$PROJECT_ROOT/.fmlab"
fi
SIDECAR="$BUNDLE/db/fm_annotations.duckdb"

DUCKDB="$(bash "$SCRIPT_DIR/resolve_duckdb_bin.sh")"
[ -z "$DUCKDB" ] && { echo "ERROR: duckdb binary not found (docs/agents/tooling.md)." >&2; exit 3; }
[ -f "$DB_FILE" ] || { echo "ERROR: master DB not found at $DB_REL — run convert-xml first." >&2; exit 4; }

q() { "$DUCKDB" "$DB_FILE" -readonly -noheader -list -c "$1" 2>/dev/null | head -n1; }
qmem() { "$DUCKDB" -noheader -list -c "$1" 2>/dev/null | head -n1; }   # in-memory (state files)
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
jnum() { if [ -z "${1:-}" ]; then printf 'null'; else printf '%s' "$1"; fi; }
jstr() { if [ -z "${1:-}" ]; then printf 'null'; else printf '"%s"' "$(printf '%s' "$1" | sed 's/"/\\"/g')"; fi; }
jbool() { if [ "${1:-0}" = "1" ]; then printf 'true'; else printf 'false'; fi; }
# $1=file $2=key — first top-level string value (no python/jq dependency)
json_get() { sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1; }

# ── 1) Tables / views present? ───────────────────────────────────────────────
EX=$(q "SELECT
  (SELECT COUNT(*) FROM information_schema.tables WHERE table_name='ObjectClusters') ||'|'||
  (SELECT COUNT(*) FROM information_schema.tables WHERE table_name='CommunityNames') ||'|'||
  (SELECT COUNT(*) FROM information_schema.tables WHERE table_name='SemanticNameCache') ||'|'||
  (SELECT COUNT(*) FROM information_schema.tables WHERE table_name='FilesCatalog') ||'|'||
  (SELECT COUNT(*) FROM duckdb_views() WHERE view_name='ClusterEdges');")
HAS_OC=$(field "$EX" 1); HAS_CN=$(field "$EX" 2); HAS_CACHE=$(field "$EX" 3)
HAS_FILES=$(field "$EX" 4); HAS_CE=$(field "$EX" 5)

N_FILES_CATALOG=""
[ "${HAS_FILES:-0}" = "1" ] && N_FILES_CATALOG=$(q "SELECT COUNT(*) FROM FilesCatalog;")

# ── 2) Partition metrics ─────────────────────────────────────────────────────
ENGINE=""; N_NODES=""; K=""; NAMED=""; DESCRIBED=""; LARGEST=""; SINGLETONS=""; N_FILES=""; CACHE_ROWS=""
PARTITION=0
if [ "${HAS_OC:-0}" = "1" ] && [ "${HAS_CN:-0}" = "1" ]; then
  M=$(q "SELECT
    COALESCE((SELECT mode(Engine) FROM ObjectClusters),'') ||'|'||
    (SELECT COUNT(*) FROM ObjectClusters) ||'|'||
    (SELECT COUNT(*) FROM CommunityNames) ||'|'||
    (SELECT COUNT(*) FILTER (WHERE Semantic_Name IS NOT NULL) FROM CommunityNames) ||'|'||
    (SELECT COUNT(*) FILTER (WHERE Semantic_Description IS NOT NULL) FROM CommunityNames) ||'|'||
    (SELECT COALESCE(MAX(Member_Count),0) FROM CommunityNames) ||'|'||
    (SELECT COUNT(*) FILTER (WHERE Member_Count = 1) FROM CommunityNames) ||'|'||
    (SELECT COUNT(DISTINCT File_Name) FROM ObjectClusters);")
  ENGINE=$(field "$M" 1); N_NODES=$(field "$M" 2); K=$(field "$M" 3); NAMED=$(field "$M" 4)
  DESCRIBED=$(field "$M" 5); LARGEST=$(field "$M" 6); SINGLETONS=$(field "$M" 7); N_FILES=$(field "$M" 8)
  [ "${N_NODES:-0}" -gt 0 ] 2>/dev/null && PARTITION=1
fi
[ -z "$N_FILES" ] && N_FILES="$N_FILES_CATALOG"
[ "${HAS_CACHE:-0}" = "1" ] && CACHE_ROWS=$(q "SELECT COUNT(*) FROM SemanticNameCache;")

# ── 3) User annotations (sidecar, best-effort: locked/absent → null) ─────────
USER_NAMED=""
if [ -f "$SIDECAR" ] && [ -n "$ENGINE" ]; then
  USER_NAMED=$("$DUCKDB" "$SIDECAR" -readonly -noheader -list -c \
    "SELECT COUNT(*) FROM CommunityAnnotation WHERE User_Name IS NOT NULL AND trim(User_Name) <> '' AND Engine='$ENGINE';" 2>/dev/null | head -n1)
fi

# ── 4) State files ───────────────────────────────────────────────────────────
SW_ENGINE=""; SW_RES=""; SW_SEED=""; SW_Q=""; SW_AT=""; SWEEP=0
if [ -f "$STATE_DIR/cluster.json" ]; then
  SWEEP=1
  S=$(qmem "SELECT COALESCE(engine,'')||'|'||COALESCE(resolution::VARCHAR,'')||'|'||COALESCE(seed::VARCHAR,'')||'|'||COALESCE(modularity_q::VARCHAR,'')||'|'||COALESCE(updated_at::VARCHAR,'') FROM read_json_auto('$STATE_DIR/cluster.json');")
  SW_ENGINE=$(field "$S" 1); SW_RES=$(field "$S" 2); SW_SEED=$(field "$S" 3); SW_Q=$(field "$S" 4); SW_AT=$(field "$S" 5)
fi
LR_ENGINE=""; LR_RES=""; LR_SEED=""; LR_Q=""; LR_NODES=""; LR_EDGES=""; LR_K=""; LR_NAMED=""; LR_AT=""; RUNSUM=0
if [ -f "$STATE_DIR/cluster_run.json" ]; then
  RUNSUM=1
  R=$(qmem "SELECT COALESCE(engine,'')||'|'||COALESCE(resolution::VARCHAR,'')||'|'||COALESCE(seed::VARCHAR,'')||'|'||COALESCE(modularity_q::VARCHAR,'')||'|'||COALESCE(n_nodes::VARCHAR,'')||'|'||COALESCE(n_edges::VARCHAR,'')||'|'||COALESCE(n_communities::VARCHAR,'')||'|'||COALESCE(n_named::VARCHAR,'')||'|'||COALESCE(finished_at::VARCHAR,'') FROM read_json_auto('$STATE_DIR/cluster_run.json');")
  LR_ENGINE=$(field "$R" 1); LR_RES=$(field "$R" 2); LR_SEED=$(field "$R" 3); LR_Q=$(field "$R" 4)
  LR_NODES=$(field "$R" 5); LR_EDGES=$(field "$R" 6); LR_K=$(field "$R" 7); LR_NAMED=$(field "$R" 8); LR_AT=$(field "$R" 9)
fi
IMPORT_AT=""; IMPORT_OK=""
if [ -f "$STATE_DIR/last_xml_run.json" ]; then
  IMPORT_AT=$(json_get "$STATE_DIR/last_xml_run.json" finished_at)
  IMPORT_OK=$(sed -n 's/.*"ok"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$STATE_DIR/last_xml_run.json" | head -n1)
fi

# ── 5) Band + flags + level ──────────────────────────────────────────────────
K_LO=""; K_HI=""; IN_BAND=""
if [ "$PARTITION" = "1" ]; then
  K_LO=$(awk -v n="$N_NODES" -v f="${N_FILES:-0}" 'BEGIN{lo=n/150; if (f>lo) lo=f; printf "%d", int(lo+0.5)}')
  K_HI=$(awk -v n="$N_NODES" 'BEGIN{printf "%d", int(n/30+0.5)}')
  IN_BAND=$(awk -v k="$K" -v lo="$K_LO" -v hi="$K_HI" 'BEGIN{print (k>=lo && k<=hi) ? 1 : 0}')
fi

FLAGS=""
addflag() { if [ -z "$FLAGS" ]; then FLAGS="\"$1\""; else FLAGS="$FLAGS, \"$1\""; fi; }
[ "${HAS_CE:-0}" = "1" ] || addflag views_missing
if [ "$PARTITION" = "0" ]; then
  addflag no_partition
else
  [ "$SWEEP" = "1" ] || addflag no_sweep
  [ "$RUNSUM" = "1" ] || addflag no_run_summary
  if [ "$SWEEP" = "1" ] && [ "$RUNSUM" = "1" ] && [ -n "$SW_RES" ] && [ -n "$LR_RES" ]; then
    [ "$(awk -v a="$SW_RES" -v b="$LR_RES" 'BEGIN{print (a+0==b+0)?1:0}')" = "1" ] || addflag resolution_mismatch
  fi
  if [ "$SWEEP" = "1" ] && [ -n "$SW_ENGINE" ] && [ "$SW_ENGINE" != "auto" ] && [ -n "$ENGINE" ] && [ "$SW_ENGINE" != "$ENGINE" ]; then
    addflag engine_mismatch
  fi
  [ "${IN_BAND:-1}" = "1" ] || addflag k_out_of_band
  [ "${NAMED:-0}" -gt 0 ] 2>/dev/null || addflag unnamed
  if [ -n "$IMPORT_AT" ] && [ -n "$LR_AT" ] && [ "$IMPORT_AT" \> "$LR_AT" ]; then addflag partition_older_than_import; fi
fi

LEVEL="L2"
if [ "$PARTITION" = "0" ]; then
  LEVEL="L0"
else
  case ",$FLAGS," in
    *no_sweep*|*no_run_summary*|*resolution_mismatch*|*engine_mismatch*) LEVEL="L1" ;;
  esac
fi

# ── 6) JSON ──────────────────────────────────────────────────────────────────
printf '{\n'
printf '  "solution": %s, "source": %s, "db": %s,\n' "$(jstr "$SOLUTION")" "$(jstr "$SOURCE")" "$(jstr "$DB_REL")"
printf '  "partition": { "present": %s, "engine": %s, "k": %s, "n_nodes": %s, "n_files": %s,\n' \
  "$(jbool "$PARTITION")" "$(jstr "$ENGINE")" "$(jnum "$K")" "$(jnum "$N_NODES")" "$(jnum "$N_FILES")"
printf '                 "named": %s, "described": %s, "user_named": %s, "cache_rows": %s,\n' \
  "$(jnum "$NAMED")" "$(jnum "$DESCRIBED")" "$(jnum "$USER_NAMED")" "$(jnum "$CACHE_ROWS")"
printf '                 "largest": %s, "singletons": %s, "views_present": %s },\n' \
  "$(jnum "$LARGEST")" "$(jnum "$SINGLETONS")" "$(jbool "$HAS_CE")"
printf '  "sweep": { "present": %s, "engine": %s, "resolution": %s, "seed": %s, "modularity_q": %s, "updated_at": %s },\n' \
  "$(jbool "$SWEEP")" "$(jstr "$SW_ENGINE")" "$(jnum "$SW_RES")" "$(jnum "$SW_SEED")" "$(jnum "$SW_Q")" "$(jstr "$SW_AT")"
printf '  "last_run": { "present": %s, "engine": %s, "resolution": %s, "seed": %s, "modularity_q": %s,\n' \
  "$(jbool "$RUNSUM")" "$(jstr "$LR_ENGINE")" "$(jnum "$LR_RES")" "$(jnum "$LR_SEED")" "$(jnum "$LR_Q")"
printf '                "n_nodes": %s, "n_edges": %s, "n_communities": %s, "n_named": %s, "finished_at": %s },\n' \
  "$(jnum "$LR_NODES")" "$(jnum "$LR_EDGES")" "$(jnum "$LR_K")" "$(jnum "$LR_NAMED")" "$(jstr "$LR_AT")"
printf '  "last_import": { "finished_at": %s, "ok": %s },\n' "$(jstr "$IMPORT_AT")" "$(jnum "$IMPORT_OK")"
printf '  "band": { "k_lo": %s, "k_hi": %s, "in_band": %s },\n' "$(jnum "$K_LO")" "$(jnum "$K_HI")" "$(if [ -z "$IN_BAND" ]; then printf 'null'; else jbool "$IN_BAND"; fi)"
printf '  "flags": [%s],\n' "$FLAGS"
printf '  "level": "%s"\n' "$LEVEL"
printf '}\n'
