#!/usr/bin/env bash
# write_cluster_json.sh — persist the sweep winner as solutions/<id>/state/cluster.json (R1).
# The Auto-P7 pipeline phase, the Explorer's Rebuild button and cluster.sh reuse this
# granularity; without it a from-scratch build would silently fall back to auto/1.0/42 and
# invalidate every semantic/user name via a different partition.
#
# Usage: bash .claude/skills/fm-graph-cluster/scripts/write_cluster_json.sh <engine> <resolution> <seed> <modularity_q> [--solution <id>]
# bash-3.2 compatible.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
[ $# -ge 4 ] || { echo "usage: write_cluster_json.sh <engine> <resolution> <seed> <modularity_q> [--solution <id>]" >&2; exit 2; }
ENGINE="$1"; RES="$2"; SEED="$3"; Q="$4"; shift 4
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
STATE_DIR="$PROJECT_ROOT/solutions/$SOLUTION/state"
[ -d "$PROJECT_ROOT/solutions/$SOLUTION" ] || STATE_DIR="$PROJECT_ROOT/.fmlab"
mkdir -p "$STATE_DIR"
[ -z "$Q" ] && Q="null"
cat > "$STATE_DIR/cluster.json" <<JSON
{ "engine": "$ENGINE", "resolution": $RES, "seed": $SEED, "modularity_q": $Q, "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)" }
JSON
echo "cluster.json → $STATE_DIR/cluster.json (engine=$ENGINE resolution=$RES seed=$SEED Q=$Q)"
