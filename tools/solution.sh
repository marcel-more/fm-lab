#!/usr/bin/env bash
# solution.sh — thin multi-solution control tool.
#
#   solution.sh list                       list all solution bundles
#   solution.sh use <id>                   switch the active solution:
#                                          pointer file + workspace symlinks
#                                          + API reload (if running)
#   solution.sh create <id> [display name] create an empty bundle + manifest v1
#   solution.sh rename <old> <new>         bundle rename (folder/id; the manifest
#                                          UUID keeps the identity). Renaming
#                                          'default' moves the bundle and re-creates
#                                          an empty 'default' (invariant I1)
#   solution.sh export <id> [--include-xml] [-o <file.zip>]
#                                          zip the bundle — default WITHOUT xml/
#                                          and state/ (manifest + DBs: analyzable,
#                                          not re-convertible); --include-xml adds
#                                          the XML sources (re-convertible)
#   solution.sh logs <id>                  list the convert logs of a solution
#   solution.sh current [--path db|xml|state] [--source]
#                                          resolve the SESSION solution context
#                                          (cascade: FMLAB_SOLUTION env →
#                                          FMLAB_CONTEXT file → pointer →
#                                          'default') — id + source, or a
#                                          repo-root-relative bundle path
#   solution.sh context create <name> [--solution <id>] [--owner <label>] [--note <text>]
#   solution.sh context list               named session contexts (.fmlab/contexts/)
#   solution.sh context delete <name>      for agents & pinned sessions
#
# The pointer file .fmlab/active_solution.json is the machine-readable source
# of truth for the WORKSPACE DEFAULT; the db/ symlinks are its convenience
# projection for CLI readers. Session pinning (FMLAB_SOLUTION / FMLAB_CONTEXT)
# overlays the pointer per shell/agent without touching it. The REST API
# resolves paths itself (pointer file) and never depends on the symlinks —
# `use` also fires POST /api/admin/reload so a running server switches
# immediately.
set -u

PROJECT_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd))"
cd "$PROJECT_ROOT"

SOLUTIONS_ROOT="solutions"
POINTER=".fmlab/active_solution.json"
CONTEXTS_DIR=".fmlab/contexts"
API_BASE="${FMLAB_API_BASE:-http://localhost:3003}"

. "$PROJECT_ROOT/tools/lib/resolve_solution.sh"

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

# id validation, pointer read and JSON extraction live in the shared resolver
# (tools/lib/resolve_solution.sh) — single implementation for all CLI tools.
valid_id() { _fmlab_valid_id "$1"; }

active_id() { # workspace default (K2) only — session pins never touch it
    if [ -f "$POINTER" ]; then
        _fmlab_json_get "$POINTER" active
    fi
}

manifest_get() { # $1=manifest $2=key — first string value of a top-level key
    _fmlab_json_get "$1" "$2"
}

write_manifest() { # $1=id $2=display name — minimal manifest v1 (user block only)
    local uuid now
    uuid=$( (command -v uuidgen >/dev/null && uuidgen) || python3 -c 'import uuid;print(uuid.uuid4())' )
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$SOLUTIONS_ROOT/$1/solution.json" <<EOF
{
  "manifest_version": 1,
  "uuid": "$uuid",
  "id": "$1",
  "display_name": "$2",
  "description": "",
  "maintainer": "",
  "url": "",
  "contact": { "name": "", "email": "" },
  "created_at": "$now",
  "notes": ""
}
EOF
}

# Invariant I1: the 'default' solution always exists — it is
# the fixed entry point (XML drop-off without an id, pointer fallback target).
# Idempotent and silent; called before every command.
ensure_default() {
    mkdir -p "$SOLUTIONS_ROOT/default/xml" "$SOLUTIONS_ROOT/default/db" \
             "$SOLUTIONS_ROOT/default/state/logs" 2>/dev/null || return 0
    [ -f "$SOLUTIONS_ROOT/default/solution.json" ] || write_manifest default default
}

cmd_list() {
    local act; act=$(active_id); [ -z "$act" ] && act="default"
    printf '%-1s %-24s %-24s %10s  %s\n' "" "ID" "NAME" "SIZE" "LAST IMPORT"
    local dir id m name size last mark
    for dir in "$SOLUTIONS_ROOT"/*/; do
        [ -d "$dir" ] || continue
        id=$(basename "$dir")
        m="$dir/solution.json"
        name=""; last=""
        if [ -f "$m" ]; then
            name=$(manifest_get "$m" display_name)
            last=$(manifest_get "$m" last_import_at)
        fi
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        mark=" "; [ "$id" = "$act" ] && mark="*"
        printf '%-1s %-24s %-24s %10s  %s\n' "$mark" "$id" "${name:-$id}" "${size:--}" "${last:--}"
    done
    echo ""
    echo "* = active solution (pointer: $POINTER)"
    # A session pin overlays the pointer for THIS shell — make that visible.
    if fmlab_resolve_solution 2>/dev/null; then
        if [ "$FMLAB_RESOLVED_SOURCE" = "env" ] || [ "$FMLAB_RESOLVED_SOURCE" = "context" ]; then
            echo "session pin: $FMLAB_RESOLVED_SOLUTION (source: $FMLAB_RESOLVED_SOURCE) — tools in this shell follow the pin, not the pointer"
        fi
    fi
}

repoint() { # $1=link $2=target — replace only symlinks/missing, never real files
    if [ -e "$1" ] && [ ! -L "$1" ]; then
        echo "WARNING: $1 is a real file — symlink NOT re-pointed (run tools/migrate-multisolution.sh?)"
        return 1
    fi
    ln -sfn "$2" "$1"
}

cmd_use() {
    local id="$1"
    valid_id "$id" || { echo "ERROR: invalid solution id '$id'"; exit 1; }
    [ -d "$SOLUTIONS_ROOT/$id" ] || { echo "ERROR: unknown solution '$id' (no $SOLUTIONS_ROOT/$id/)"; exit 1; }

    # 1. Pointer (source of truth), atomic.
    mkdir -p .fmlab
    printf '{\n  "active": "%s",\n  "switched_at": "%s"\n}\n' \
        "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$POINTER.tmp"
    mv -f "$POINTER.tmp" "$POINTER"

    # 2. Workspace symlinks (projection for CLI readers).
    repoint db/fm_catalog.duckdb "../solutions/$id/db/fm_catalog.duckdb"
    repoint db/fm_annotations.duckdb "../solutions/$id/db/fm_annotations.duckdb"
    repoint rest-api/db/fm_catalog.duckdb "solutions/$id/fm_catalog.duckdb"

    # 3. API reload (no body → server re-resolves the pointer). Non-fatal.
    local code
    code=$(curl -sS -X POST --max-time 5 -o /dev/null -w "%{http_code}" \
        ${ADMIN_RELOAD_TOKEN:+-H "X-Admin-Token: $ADMIN_RELOAD_TOKEN"} \
        "$API_BASE/api/admin/reload" 2>/dev/null || echo "000")
    case "$code" in
        200) echo "Active solution: $id (API reloaded)" ;;
        000) echo "Active solution: $id (API not running — will pick it up on start)" ;;
        *)   echo "Active solution: $id (API reload returned HTTP $code)" ;;
    esac
    echo "Scope: workspace-wide default (pointer + symlinks + API server default)."
    echo "To pin only THIS shell/agent session instead: export FMLAB_SOLUTION=$id"
    if [ -n "${FMLAB_SOLUTION:-}" ] || [ -n "${FMLAB_CONTEXT:-}" ]; then
        echo "NOTE: this shell has a session pin (FMLAB_SOLUTION/FMLAB_CONTEXT) — its tools keep following the pin, not this switch."
    fi
}

cmd_create() {
    local id="$1"; shift
    local display="${*:-$id}"
    valid_id "$id" || { echo "ERROR: invalid solution id '$id'"; exit 1; }
    # Case-insensitive clash guard (dev-container FS is case-insensitive).
    local dir existing
    for dir in "$SOLUTIONS_ROOT"/*/; do
        [ -d "$dir" ] || continue
        existing=$(basename "$dir")
        if [ "$(printf '%s' "$existing" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" ]; then
            echo "ERROR: solution '$existing' already exists (ids must differ beyond case)"; exit 1
        fi
    done
    mkdir -p "$SOLUTIONS_ROOT/$id/xml" "$SOLUTIONS_ROOT/$id/db" "$SOLUTIONS_ROOT/$id/state/logs"
    write_manifest "$id" "$display"
    echo "Created $SOLUTIONS_ROOT/$id/ (uuid=$(manifest_get "$SOLUTIONS_ROOT/$id/solution.json" uuid))"
    echo "XML inbox: $SOLUTIONS_ROOT/$id/xml/ — import with: ingestion/convert_fm_xml.sh --batch --solution $id"
}

cmd_rename() { # bundle rename (folder/id) — the manifest UUID keeps the identity
    local old="$1" new="$2"
    valid_id "$old" || { echo "ERROR: invalid solution id '$old'"; exit 1; }
    valid_id "$new" || { echo "ERROR: invalid solution id '$new'"; exit 1; }
    [ -d "$SOLUTIONS_ROOT/$old" ] || { echo "ERROR: unknown solution '$old'"; exit 1; }
    [ "$new" = "$old" ] && { echo "ERROR: new id equals the current id — nothing to rename."; exit 1; }
    # Case-insensitive clash guard (dev-container FS is case-insensitive) —
    # the solution's OWN id compares case-sensitively so a pure case rename
    # (Sales → sales) stays allowed.
    local dir existing
    for dir in "$SOLUTIONS_ROOT"/*/; do
        [ -d "$dir" ] || continue
        existing=$(basename "$dir")
        [ "$existing" = "$old" ] && continue
        if [ "$(printf '%s' "$existing" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$new" | tr '[:upper:]' '[:lower:]')" ]; then
            echo "ERROR: solution '$existing' already exists (ids must differ beyond case)"; exit 1
        fi
    done
    # No rename while an import runs (live per-solution lock).
    local lock="$SOLUTIONS_ROOT/$old/state/xml_convert.lock" pid
    if [ -f "$lock" ]; then
        pid=$(head -n1 "$lock" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$pid" ] && printf '%s' "$pid" | grep -q '^[0-9][0-9]*$' && kill -0 "$pid" 2>/dev/null; then
            echo "ERROR: solution '$old' has a running import (PID $pid) — try again after it finishes."; exit 1
        fi
    fi

    local was_active=false
    [ "$(active_id)" = "$old" ] && was_active=true

    # Move bundle + API copy; adjust the manifest id (UUID stays — identity).
    # Pure case rename goes through a temp name: on the case-insensitive FS the
    # target resolves to the source directory and a direct mv would fail/no-op.
    local lc_old lc_new
    lc_old=$(printf '%s' "$old" | tr '[:upper:]' '[:lower:]')
    lc_new=$(printf '%s' "$new" | tr '[:upper:]' '[:lower:]')
    if [ "$lc_old" = "$lc_new" ]; then
        mv "$SOLUTIONS_ROOT/$old" "$SOLUTIONS_ROOT/$old.tmp-rename-$$"
        mv "$SOLUTIONS_ROOT/$old.tmp-rename-$$" "$SOLUTIONS_ROOT/$new"
        if [ -d "rest-api/db/solutions/$old" ]; then
            mv "rest-api/db/solutions/$old" "rest-api/db/solutions/$old.tmp-rename-$$"
            mv "rest-api/db/solutions/$old.tmp-rename-$$" "rest-api/db/solutions/$new"
        fi
    else
        mv "$SOLUTIONS_ROOT/$old" "$SOLUTIONS_ROOT/$new"
        [ -d "rest-api/db/solutions/$old" ] && mv "rest-api/db/solutions/$old" "rest-api/db/solutions/$new"
    fi
    SOL="$SOLUTIONS_ROOT/$new/solution.json" OLD_ID="$old" NEW_ID="$new" python3 - <<'PYEOF'
import json, os
p = os.environ["SOL"]
try:
    with open(p) as f:
        m = json.load(f)
except Exception:
    m = {}
m["id"] = os.environ["NEW_ID"]
if m.get("display_name") == os.environ["OLD_ID"]:
    m["display_name"] = os.environ["NEW_ID"]
with open(p, "w") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

    # Invariant I1: renaming 'default' means "my working solution gets a real
    # name" — re-create an empty 'default' (new manifest, new UUID) right away.
    [ "$old" = "default" ] && ensure_default

    if $was_active; then
        # The renamed solution stays the active one (pointer + symlinks + reload).
        cmd_use "$new"
    fi
    echo "Renamed: $old → $new (uuid unchanged$( $was_active && printf ', active state carried over' ))"
}

cmd_export() {
    local id="" include_xml=false out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --include-xml) include_xml=true; shift ;;
            -o) [ $# -ge 2 ] || { echo "ERROR: -o needs a value"; exit 1; }; out="$2"; shift 2 ;;
            -*) echo "ERROR: unknown flag $1"; exit 1 ;;
            *) id="$1"; shift ;;
        esac
    done
    [ -n "$id" ] || usage
    [ -d "$SOLUTIONS_ROOT/$id" ] || { echo "ERROR: unknown solution '$id'"; exit 1; }
    local schema=""
    [ -f "$SOLUTIONS_ROOT/$id/solution.json" ] && schema=$(manifest_get "$SOLUTIONS_ROOT/$id/solution.json" db_schema_version)
    if [ -z "$out" ]; then
        out="output/solution_${id}$( [ -n "$schema" ] && printf '_schema-%s' "$schema" )_$(date -u +%Y%m%d).zip"
    fi
    mkdir -p "$(dirname "$out")"
    # python3 zipfile: portable (no zip binary in the container). Default
    # excludes xml/ (large, often confidential) and the volatile state/ —
    # package = manifest + catalog DB + annotations DB.
    SOL_DIR="$SOLUTIONS_ROOT/$id" OUT="$out" INCLUDE_XML="$include_xml" python3 - <<'PYEOF'
import os, sys, zipfile

sol_dir = os.environ["SOL_DIR"]
out = os.environ["OUT"]
include_xml = os.environ["INCLUDE_XML"] == "true"

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(sol_dir):
        rel_root = os.path.relpath(root, sol_dir)
        parts = [] if rel_root == "." else rel_root.split(os.sep)
        if parts and parts[0] == "state":
            dirs[:] = []
            continue
        if parts and parts[0] == "xml" and not include_xml:
            dirs[:] = []
            continue
        for f in files:
            if f.endswith((".tmp", ".lock", ".wal")):
                # A non-empty annotations WAL means the
                # sidecar holds un-checkpointed writes (API keeps it RW) — the
                # packaged fm_annotations.duckdb may be stale. Warn, don't fail.
                full = os.path.join(root, f)
                if f == "fm_annotations.duckdb.wal" and os.path.getsize(full) > 0:
                    print(f"WARNING: skipping non-empty {f} ({os.path.getsize(full)} bytes) — "
                          "annotations in the package may be stale. Stop the API "
                          "(checkpoints the sidecar) and re-export for a current state.",
                          file=sys.stderr)
                continue
            full = os.path.join(root, f)
            arc = os.path.join(os.path.basename(sol_dir), rel_root, f) if parts else os.path.join(os.path.basename(sol_dir), f)
            z.write(full, arc)
print(f"Exported: {out} ({os.path.getsize(out) / 1024 / 1024:.1f} MB)")
PYEOF
    $include_xml && echo "Included xml/ — the package is re-convertible." \
                 || echo "Without xml/ and state/ (default) — analyzable, not re-convertible. Use --include-xml for a full package."
}

cmd_logs() {
    local id="$1"
    [ -d "$SOLUTIONS_ROOT/$id/state/logs" ] || { echo "No logs for '$id'."; exit 0; }
    ls -lt "$SOLUTIONS_ROOT/$id/state/logs" | head -25
}

cmd_current() { # machine-readable session-context resolution (cascade K0–K3)
    local path_kind="" show_source=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --path) [ $# -ge 2 ] || { echo "ERROR: --path needs a value (db|xml|state)"; exit 1; }; path_kind="$2"; shift 2 ;;
            --source) show_source=true; shift ;;
            *) echo "ERROR: unknown flag $1"; exit 1 ;;
        esac
    done
    fmlab_resolve_solution || exit 1
    if [ -n "$path_kind" ]; then
        # Paths are repo-root relative — matches the permission convention of
        # literal duckdb invocations (duckdb solutions/<id>/db/…).
        case "$path_kind" in
            db)    echo "$SOLUTIONS_ROOT/$FMLAB_RESOLVED_SOLUTION/db/fm_catalog.duckdb" ;;
            xml)   echo "$SOLUTIONS_ROOT/$FMLAB_RESOLVED_SOLUTION/xml" ;;
            state) echo "$SOLUTIONS_ROOT/$FMLAB_RESOLVED_SOLUTION/state" ;;
            *)     echo "ERROR: unknown path kind '$path_kind' (db|xml|state)"; exit 1 ;;
        esac
    elif $show_source; then
        echo "$FMLAB_RESOLVED_SOURCE"
    else
        printf '%s\t%s\n' "$FMLAB_RESOLVED_SOLUTION" "$FMLAB_RESOLVED_SOURCE"
    fi
}

cmd_context() { # named session contexts — identity + state anchor for agents
    local sub="$1"; shift
    case "$sub" in
        create)
            [ $# -ge 1 ] || usage
            local name="$1"; shift
            valid_id "$name" || { echo "ERROR: invalid context name '$name'"; exit 1; }
            local solution="" owner="" note=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --solution) [ $# -ge 2 ] || { echo "ERROR: --solution needs a value"; exit 1; }; solution="$2"; shift 2 ;;
                    --owner)    [ $# -ge 2 ] || { echo "ERROR: --owner needs a value"; exit 1; }; owner="$2"; shift 2 ;;
                    --note)     [ $# -ge 2 ] || { echo "ERROR: --note needs a value"; exit 1; }; note="$2"; shift 2 ;;
                    *) echo "ERROR: unknown flag $1"; exit 1 ;;
                esac
            done
            if [ -z "$solution" ]; then
                # Default: the solution this shell currently resolves to.
                fmlab_resolve_solution || exit 1
                solution="$FMLAB_RESOLVED_SOLUTION"
            fi
            valid_id "$solution" || { echo "ERROR: invalid solution id '$solution'"; exit 1; }
            [ -d "$SOLUTIONS_ROOT/$solution" ] || { echo "ERROR: unknown solution '$solution' (no $SOLUTIONS_ROOT/$solution/)"; exit 1; }
            [ -f "$CONTEXTS_DIR/$name.json" ] && { echo "ERROR: context '$name' already exists — delete it first (context delete $name)."; exit 1; }
            [ -z "$owner" ] && owner="user:${USER:-unknown}"
            mkdir -p "$CONTEXTS_DIR"
            CTX_FILE="$CONTEXTS_DIR/$name.json" CTX_SOLUTION="$solution" CTX_OWNER="$owner" CTX_NOTE="$note" python3 - <<'PYEOF'
import json, os, datetime
with open(os.environ["CTX_FILE"], "w") as f:
    json.dump({
        "context_version": 1,
        "solution": os.environ["CTX_SOLUTION"],
        "owner": os.environ["CTX_OWNER"],
        "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note": os.environ["CTX_NOTE"],
    }, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
            echo "Created context '$name' → solution '$solution' (owner: $owner)"
            echo "Activate for a session: export FMLAB_CONTEXT=$name"
            ;;
        list)
            [ -d "$CONTEXTS_DIR" ] || { echo "No session contexts ($CONTEXTS_DIR/ is empty)."; exit 0; }
            printf '%-20s %-20s %-24s %s\n' "CONTEXT" "SOLUTION" "OWNER" "CREATED"
            local f name found=false
            for f in "$CONTEXTS_DIR"/*.json; do
                [ -f "$f" ] || continue
                found=true
                name=$(basename "$f" .json)
                printf '%-20s %-20s %-24s %s\n' "$name" \
                    "$(_fmlab_json_get "$f" solution)" \
                    "$(_fmlab_json_get "$f" owner)" \
                    "$(_fmlab_json_get "$f" created_at)"
            done
            $found || echo "(none)"
            ;;
        delete)
            [ $# -ge 1 ] || usage
            local name="$1"
            valid_id "$name" || { echo "ERROR: invalid context name '$name'"; exit 1; }
            [ -f "$CONTEXTS_DIR/$name.json" ] || { echo "ERROR: unknown context '$name'"; exit 1; }
            rm "$CONTEXTS_DIR/$name.json"
            echo "Deleted context '$name'."
            ;;
        *) usage ;;
    esac
}

[ $# -ge 1 ] || usage
ensure_default
CMD="$1"; shift
case "$CMD" in
    list)   cmd_list ;;
    use)    [ $# -ge 1 ] || usage; cmd_use "$1" ;;
    create) [ $# -ge 1 ] || usage; cmd_create "$@" ;;
    rename) [ $# -ge 2 ] || usage; cmd_rename "$1" "$2" ;;
    export) cmd_export "$@" ;;
    logs)   [ $# -ge 1 ] || usage; cmd_logs "$1" ;;
    current) cmd_current "$@" ;;
    context) [ $# -ge 1 ] || usage; cmd_context "$@" ;;
    *) usage ;;
esac
