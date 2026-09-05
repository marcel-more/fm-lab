#!/usr/bin/env bash
# cluster_run_named.sh — refresh "n_named" in solutions/<id>/state/cluster_run.json from the
# live CommunityNames count. cluster.sh writes the run summary BEFORE any semantic naming
# happens, so after fm-graph-cluster (Phase F) or fm-deep-research (write-back) the stored
# n_named is stale. This rewrites exactly that one field; finished_at and the rest stay.
#
# Usage:  bash .claude/skills/_shared/scripts/cluster_run_named.sh [--solution <id>]
# Exit:   0 updated (prints "n_named=<N> → <file>") · 1 no summary file (nothing to do)
#         2 usage · 3 no duckdb · 4 master DB missing
# bash-3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
EXPLICIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --solution) shift; EXPLICIT="${1:-}" ;;
    --solution=*) EXPLICIT="${1#--solution=}" ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
. "$PROJECT_ROOT/tools/lib/resolve_solution.sh"
fmlab_resolve_solution "$EXPLICIT" || exit 2
SOLUTION="$FMLAB_RESOLVED_SOLUTION"
if [ -f "$PROJECT_ROOT/solutions/$SOLUTION/db/fm_catalog.duckdb" ]; then
  DB_FILE="$PROJECT_ROOT/solutions/$SOLUTION/db/fm_catalog.duckdb"
  RUN_JSON="$PROJECT_ROOT/solutions/$SOLUTION/state/cluster_run.json"
else
  DB_FILE="$PROJECT_ROOT/db/fm_catalog.duckdb"
  RUN_JSON="$PROJECT_ROOT/.fmlab/cluster_run.json"
fi
DUCKDB="$(bash "$SCRIPT_DIR/resolve_duckdb_bin.sh")"
[ -z "$DUCKDB" ] && { echo "ERROR: duckdb binary not found." >&2; exit 3; }
[ -f "$DB_FILE" ] || { echo "ERROR: master DB not found." >&2; exit 4; }
[ -f "$RUN_JSON" ] || { echo "no cluster_run.json for solution '$SOLUTION' — nothing to update." >&2; exit 1; }
N=$("$DUCKDB" "$DB_FILE" -readonly -noheader -list -c \
  "SELECT COUNT(*) FILTER (WHERE Semantic_Name IS NOT NULL) FROM CommunityNames;" 2>/dev/null | head -n1)
[ -n "$N" ] || N=0
TMP="$RUN_JSON.tmp.$$"
sed 's/"n_named":[[:space:]]*[0-9null]*/"n_named": '"$N"'/' "$RUN_JSON" > "$TMP" && mv "$TMP" "$RUN_JSON" \
  || { rm -f "$TMP"; echo "ERROR: could not rewrite $RUN_JSON" >&2; exit 5; }
echo "n_named=$N → $RUN_JSON"
