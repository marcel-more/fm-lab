# cluster_config.sh — the ONE reader for the persisted clustering granularity.
# Source this file (do not execute).
#
#   fmlab_read_cluster_config <state_dir> <duckdb_bin>   → echoes "engine|resolution|seed"
#
# Reads <state_dir>/cluster.json — the last fm-graph-cluster sweep winner (engine,
# resolution, seed, modularity_q, updated_at). Missing/unparsable file → the
# cluster.sh defaults "auto|1.0|42". A stored 'leiden' is downgraded to 'auto' so a
# host without python3+igraph does not hard-abort (engine auto-detect still picks
# Leiden when it is available); resolution/seed are preserved.
#
# Callers: cluster.sh (its own defaults), convert_fm_xml.sh Phase 7 (auto-clustering);
# the REST Rebuild button has an equivalent JavaScript reader (recluster.service.js).
# bash-3.2 compatible.
fmlab_read_cluster_config() {
    local dir="$1" duckdb="$2"
    local f="$dir/cluster.json"
    local engine="auto" res="1.0" seed="42"
    if [ -f "$f" ] && [ -n "$duckdb" ]; then
        local parsed
        parsed=$("$duckdb" -noheader -list -c \
            "SELECT COALESCE(engine,'auto')||'|'||COALESCE(resolution,1.0)::VARCHAR||'|'||COALESCE(seed,42)::VARCHAR FROM read_json_auto('$f');" 2>/dev/null | head -n1)
        if [ -n "$parsed" ]; then
            engine="${parsed%%|*}"
            local rest="${parsed#*|}"
            res="${rest%%|*}"
            seed="${rest##*|}"
        fi
    fi
    [ "$engine" = "leiden" ] && engine="auto"
    printf '%s|%s|%s' "$engine" "$res" "$seed"
}
