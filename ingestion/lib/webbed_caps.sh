#!/bin/bash
# ingestion/lib/webbed_caps.sh — webbed capability/version probes (manifest-driven).
#
# Module of ingestion/convert_fm_xml.sh (shell split) — pure code movement,
# behaviour unchanged. NOT independently executable: is sourced by the driver
# (existence check there, A-B10) and uses its globals
# (ENGINE_ROOT, DUCKDB_BIN, WEBBED_* configuration).
# bash-3.2 discipline (macOS system bash): no `case` in $(…), no bash-4+.

# webbed capability registry (data-driven). RUNTIME source of the version check:
# ingestion/version_check.json — the single mechanism source.
# _vc_probe_sql <cap-id> returns the probe_sql stored in the manifest
# (@FIXTURE@ -> probe_fixture resolved, engine-relative); empty when manifest/jq/entry
# are missing → the caller falls back to the hardcoded fallback (robust, no
# weakening of the version floor). Deliberately string operations only (bash-3.2-safe).
WEBBED_VERSION_CHECK_MANIFEST="${FM_WEBBED_MANIFEST:-$ENGINE_ROOT/version_check.json}"
_vc_probe_sql() {
    local _id="$1" _s _fix
    { [ -f "$WEBBED_VERSION_CHECK_MANIFEST" ] && command -v jq >/dev/null 2>&1; } || return 0
    _s="$(jq -r --arg id "$_id" '.capabilities[] | select(.id==$id) | .probe_sql // empty' \
            "$WEBBED_VERSION_CHECK_MANIFEST" 2>/dev/null)"
    { [ -n "$_s" ] && [ "$_s" != "null" ]; } || return 0
    # per-capability probe_fixture (override) → otherwise the #98 default fixture $WEBBED_SAX_PROBE.
    _fix="$(jq -r --arg id "$_id" '.capabilities[] | select(.id==$id) | .probe_fixture // empty' \
            "$WEBBED_VERSION_CHECK_MANIFEST" 2>/dev/null)"
    if [ -n "$_fix" ] && [ "$_fix" != "null" ]; then _fix="$ENGINE_ROOT/$_fix"; else _fix="$WEBBED_SAX_PROBE"; fi
    printf '%s' "${_s//@FIXTURE@/$_fix}"
}

# Reduce a probe's captured 2>&1 output to its last non-empty, trimmed line.
# The DuckDB CLI can prepend banner lines to the result (e.g. a
# "-- Loading resources from …" notice when a user init file is present), which
# would break an exact match against the whole block. Keeping only the final
# value line makes the value comparison robust against such prefixes.
# Deliberately awk/sed only (bash-3.2-safe, no bash-4+ constructs).
_last_value_line() {
    printf '%s\n' "$1" | awk 'NF{v=$0} END{print v}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_probe_webbed_caps() {
    local _tgt="${FM_WEBBED_EXT:-webbed}" _flags=() _load _out _val _cr _ws _cr_out _ws_out
    # -no-init: run every probe against a pristine CLI, ignoring any user
    # ~/.duckdbrc — its banner line would otherwise contaminate the output and
    # silently derail the value match below.
    if [ "$_tgt" = "webbed" ]; then _load="LOAD webbed;"; else _load="LOAD '$_tgt';"; _flags+=(-unsigned); fi
    # #98 nested-attr-SAX + streaming param (single source: $_vc_nested_probe_sql)
    _out=$("$DUCKDB_BIN" "${_flags[@]}" :memory: -no-init -noheader -list -c "${_load} ${_vc_nested_probe_sql};" 2>&1)
    # Expose the raw LOAD+probe output so the driver, on a non-classifiable
    # error (→ streaming-param=unknown, e.g. `LOAD webbed` fails), can show the
    # real webbed message instead of just "unknown".
    WEBBED_PROBE_RAW="$_out"
    _val=$(_last_value_line "$_out")
    # Error patterns are matched against the full (possibly multi-line) output;
    # the 0/1 value only against the trimmed last line.
    case "$_out" in
        *"Invalid named parameter"*) WEBBED_HAS_STREAMING_PARAM=false; WEBBED_HAS_NESTED_ATTR_FIX=false ;;
        *)
            case "$_val" in
                1) WEBBED_HAS_STREAMING_PARAM=true;    WEBBED_HAS_NESTED_ATTR_FIX=true ;;
                0) WEBBED_HAS_STREAMING_PARAM=true;    WEBBED_HAS_NESTED_ATTR_FIX=false ;;
                *) WEBBED_HAS_STREAMING_PARAM=unknown; WEBBED_HAS_NESTED_ATTR_FIX=false ;;
            esac ;;
    esac
    # #109 SAX CR parity ($_vc_cr_probe_sql): three-state — 1 = CR preserved
    # DOM-faithful (fixed) → true, 0 = provably not → false, anything else =
    # the probe itself did not run cleanly (LOAD failure, empty output) →
    # 'error'. 'error' is deliberately NOT mapped to false: the probe outcome
    # stamps the run policy (SAX vs DOM) and thereby every content_hash — a
    # transient infra failure must stay distinguishable from "capability
    # provably absent" so the driver can keep the last successfully used
    # policy instead of silently flipping (policy-lock, sticky fallback).
    # WEBBED_PROBE_ERRORS collects the raw error text (analog WEBBED_PROBE_RAW),
    # newline-collapsed so warnings stay single-line (NDJSON-safe).
    _cr_out=$("$DUCKDB_BIN" "${_flags[@]}" :memory: -no-init -noheader -list -c "${_load} ${_vc_cr_probe_sql};" 2>&1)
    _cr=$(_last_value_line "$_cr_out")
    case "$_cr" in
        1) WEBBED_HAS_CR_PARITY=true ;;
        0) WEBBED_HAS_CR_PARITY=false ;;
        *) WEBBED_HAS_CR_PARITY=error
           WEBBED_PROBE_ERRORS="${WEBBED_PROBE_ERRORS:+$WEBBED_PROBE_ERRORS · }#109: $(printf '%s' "${_cr_out:-empty probe output}" | tr '\n' ' ')" ;;
    esac
    # #73 whitespace preservation ($_vc_ws_probe_sql): 1 = linebreak preserved
    # natively (DOM-faithful) → true; same three-state mapping as #109.
    _ws_out=$("$DUCKDB_BIN" "${_flags[@]}" :memory: -no-init -noheader -list -c "${_load} ${_vc_ws_probe_sql};" 2>&1)
    _ws=$(_last_value_line "$_ws_out")
    case "$_ws" in
        1) WEBBED_HAS_WS_PRESERVE=true ;;
        0) WEBBED_HAS_WS_PRESERVE=false ;;
        *) WEBBED_HAS_WS_PRESERVE=error
           WEBBED_PROBE_ERRORS="${WEBBED_PROBE_ERRORS:+$WEBBED_PROBE_ERRORS · }#73: $(printf '%s' "${_ws_out:-empty probe output}" | tr '\n' ' ')" ;;
    esac
    # Extension version for the log provenance block: the strategy decisions above
    # depend on webbed, not on the DuckDB version already logged. LIKE covers the
    # dev-patch path (loaded by file path); a failed LOAD yields error text →
    # sanity-gate to a version-shaped token, else "unknown".
    local _wv
    _wv=$(_last_value_line "$("$DUCKDB_BIN" "${_flags[@]}" :memory: -no-init -noheader -list -c "${_load} SELECT extension_version FROM duckdb_extensions() WHERE extension_name LIKE '%webbed%' AND loaded LIMIT 1;" 2>&1)")
    if [ -n "$_wv" ] && [[ "$_wv" =~ ^[0-9A-Za-z._+-]+$ ]]; then
        WEBBED_VERSION_DETECTED="$_wv"
    else
        WEBBED_VERSION_DETECTED="unknown"
    fi
}

# ── Policy-lock sticky state (installation-wide) ─────────────────────────────
# $POLICY_STATE_FILE (driver-resolved; default .fmlab/webbed_policy.state) is a
# small Key=Value file holding the policy of the last SUCCESSFUL run. It is the
# sticky fallback when a capability probe or the streamify freshness gate fails
# with an INFRA error ('error' three-state above / gate rc 4): a transient
# failure must not flip the policy — the flip would restamp the Phase-S chunk
# bytes and devalue every stored content_hash (false-changed full reload).
# Installation-wide by design: the policy depends on webbed + repo state, not
# on the solution (and the decision block runs before solution resolution).
# Written ONLY at the end of a successful run — a sticky-adopted policy never
# perpetuates itself while runs fail.
_policy_state_read() {
    STICKY_POLICY=""; STICKY_WS_SENTINEL=""
    { [ -n "${POLICY_STATE_FILE:-}" ] && [ -f "$POLICY_STATE_FILE" ]; } || return 0
    local _line _key _val
    while IFS= read -r _line || [ -n "$_line" ]; do
        _key="${_line%%=*}"; _val="${_line#*=}"
        case "$_key" in
            parser_policy) case "$_val" in sax|dom) STICKY_POLICY="$_val" ;; esac ;;
            ws_sentinel)   case "$_val" in true|false) STICKY_WS_SENTINEL="$_val" ;; esac ;;
        esac
    done < "$POLICY_STATE_FILE" 2>/dev/null
    return 0
}

# _policy_state_write <parser_policy sax|dom> <ws_sentinel true|false>
# Atomic write-once: temp file IN THE TARGET DIRECTORY + mv. Deliberately not
# via ${TMPDIR} — a cross-filesystem mv is not atomic, and TMPDIR fragility is
# exactly the infra failure class this state protects against. Concurrent runs
# (CLI + web import) are last-writer-wins, which is fine: the policy is an
# installation property, all runs converge on the same value. Never fatal.
_policy_state_write() {
    [ -n "${POLICY_STATE_FILE:-}" ] || return 0
    local _dir _tmp
    _dir="$(dirname "$POLICY_STATE_FILE")"
    mkdir -p "$_dir" 2>/dev/null || return 0
    _tmp="$(mktemp "$_dir/.webbed_policy.state.XXXXXX" 2>/dev/null)" || return 0
    {
        printf 'parser_policy=%s\n' "$1"
        printf 'ws_sentinel=%s\n' "$2"
        printf 'webbed_version=%s\n' "${WEBBED_VERSION_DETECTED:-unknown}"
        printf 'converter_version=%s\n' "${CONVERTER_VERSION:-unknown}"
        printf 'ts=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$_tmp" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 0; }
    mv -f "$_tmp" "$POLICY_STATE_FILE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
    return 0
}
