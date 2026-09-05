#!/bin/bash
# katana-xml/lib/convert_report.sh — Conversion log v2: Phase Timeline, object counts,
# environment context, text log + JSON sidecar (write_text_log/write_json_sidecar).
#
# Module of ingestion/convert_fm_xml.sh (shell split) — pure code movement,
# behaviour unchanged. NOT independently executable: it is sourced by the driver
# (existence check there, A-B10) and uses its globals; the
# log-state arrays (PH_*/FL_*/FO_*) live here and are initialized on sourcing.
# bash-3.2 discipline (macOS system bash): no `case` in $(…), no bash-4+.

# ============================================================================
# Conversion log v2
# Phase timeline, object counts, environment context, JSON sidecar.
# Data-driven from parallel arrays (Bash 3 safe) → text log + JSON are written
# exactly ONCE at the end of the run (write_text_log / write_json_sidecar).
# ============================================================================

# --- Phase collection (parallel arrays) ---
PH_ID=();    PH_NAME=();     PH_START_ISO=(); PH_END_ISO=()
PH_DUR=();   PH_PROD_TXT=(); PH_PROD_JSON=()
_PH_CUR_ID=""; _PH_CUR_NAME=""; _PH_CUR_START_EPOCH=""; _PH_CUR_START_ISO=""

# --- Per-file collection (P1 per file) ---
FL_NAME=(); FL_SIZE=(); FL_ENC=(); FL_STATUS=()
FL_DUR=();  FL_COMPLETED=(); FL_ERR_CAT=(); FL_ERR_RC=(); FL_ERR_HINT=()
FL_PEAKRSS=(); FL_MINAVAIL=()   # memory forensics (KB; empty = not sampled/non-Linux)

# --- Per-file object counts (filled after P1) ---
FO_NAME=(); FO_COUNT=()

# Guard against double writes (multiple exit paths, e.g. fail-fast).
LOGS_FINALIZED=false

iso_now() { date '+%Y-%m-%dT%H:%M:%S'; }

# phase_begin <id> <name> — records the start time of the current phase.
# In quiet/web mode it also emits a live `phase` marker (state=begin) so the
# streamed/frontend log shows a clean per-phase trace for all 6 SQL phases P1–P6.
# In the CLI the section banners + the end-of-run phase table already cover this.
phase_begin() {
    _PH_CUR_ID="$1"; _PH_CUR_NAME="$2"
    _PH_CUR_START_EPOCH=$(now_epoch)
    _PH_CUR_START_ISO=$(iso_now)
    $QUIET_MODE && _emit_json phase id "$1" name "$2" state "begin"
}

# phase_finish <produced_text> <produced_json> — closes the current phase.
# Quiet/web: emits a live `phase` marker (state=done) carrying the duration and
# the produced summary (e.g. "12.345 references") — the per-phase result line.
phase_finish() {
    local end_epoch end_iso dur
    end_epoch=$(now_epoch); end_iso=$(iso_now)
    dur=$(awk -v a="$end_epoch" -v b="$_PH_CUR_START_EPOCH" 'BEGIN{printf "%.3f", a-b}')
    PH_ID+=("$_PH_CUR_ID");               PH_NAME+=("$_PH_CUR_NAME")
    PH_START_ISO+=("$_PH_CUR_START_ISO"); PH_END_ISO+=("$end_iso")
    PH_DUR+=("$dur");                     PH_PROD_TXT+=("$1")
    PH_PROD_JSON+=("$2")
    $QUIET_MODE && _emit_json phase id "$_PH_CUR_ID" name "$_PH_CUR_NAME" state "done" \
        duration "$(dur_human "$dur")" produced "$1"
}

# group_de <int> → German thousands separators (903141 → 903.141).
group_de() {
    awk -v n="$1" 'BEGIN{
        s=sprintf("%d", n+0); out=""; c=0
        for(i=length(s); i>=1; i--){ out=substr(s,i,1) out; c++; if(c%3==0 && i>1) out="." out }
        print out
    }'
}

# dur_human <seconds> → "54m 34.5s" or "11.8s".
dur_human() {
    awk -v d="$1" 'BEGIN{
        if(d+0>=60){ m=int(d/60); s=d-m*60; printf "%dm %.1fs", m, s }
        else printf "%.1fs", d+0
    }'
}

# fmt_gib <bytes> → "14.0 GiB" | "n/a".
fmt_gib() {
    awk -v b="$1" 'BEGIN{ if(b+0<=0) print "n/a"; else printf "%.1f GiB", b/1073741824 }'
}

# phase_label_txt <id> <name> — decorative column label for the timeline.
phase_label_txt() {
    case "$1" in
        P1) echo "Extract  (XML → tables)" ;;
        P2) echo "Resolve  references" ;;
        P3) echo "Details  (variables)" ;;
        P4) echo "Catalog  (objects+links)" ;;
        P5) echo "Homes    (Cross-File)" ;;
        P6) echo "Validate (Post-Checks)" ;;
        P7) echo "Cluster  (Communities)" ;;
        *)  echo "$2" ;;
    esac
}

# ----------------------------------------------------------------------------
# Object counts — read-only COUNT(*) against the master DB after the phases finish.
# ----------------------------------------------------------------------------

# Fixed set of tables for objects_extracted. Excluded are pure
# metadata/helper tables (FilesCatalog, SchemaInfo, XMLMetadata, PasteIndexList);
# DDR_Calculations is counted separately as ddr_calc_chunks.
P1_OBJECT_TABLES=(
    BaseTableCatalog TableOccurrenceCatalog RelationshipCatalog FieldsForTables
    ScriptCatalog StepsForScripts Layouts LayoutObjects LayoutParts
    ValueListCatalog OptionsForValueLists CustomFunctionsCatalog CalcsForCustomFunctions
    AccountsCatalog PrivilegeSetsCatalog PrivilegeSetRecordAccess PrivilegeSetFieldAccess
    PrivilegeSetObjectAccess ThemeCatalog CustomMenuCatalog ExtendedPrivilegesCatalog
    ScriptTriggers ExternalDataSourceCatalog BaseDirectoryCatalog DDR_ScriptSteps
)

# Like pp_query, but quoting-free (-list instead of -csv): needed when the returned
# value itself contains commas (e.g. dynamically built SQL expressions), which the CSV
# writer would otherwise wrap in quotes and thereby break the follow-up query.
pp_query_raw() {
    "$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c "$1" 2>/dev/null | head -n1
}

# _sql_inlist <names...> → "'a','b',...".
_sql_inlist() {
    local t out=""
    for t in "$@"; do
        if [ -z "$out" ]; then out="'$t'"; else out="$out,'$t'"; fi
    done
    printf '%s' "$out"
}

# count_table_sum <names...> → Σ rows over all EXISTING tables in the list
# (robust against missing tables: the sum expression is built dynamically over only
# the present tables, missing ones do not count and do not abort).
count_table_sum() {
    local inlist sumexpr
    inlist=$(_sql_inlist "$@")
    sumexpr=$(pp_query_raw "SELECT string_agg('(SELECT COUNT(*) FROM '||table_name||')','+') FROM information_schema.tables WHERE table_name IN ($inlist)")
    [ -z "$sumexpr" ] && { echo 0; return; }
    pp_num "SELECT $sumexpr"
}

# load_per_file_objects — a grouped query over all existing P1 object tables →
# FO_NAME[]/FO_COUNT[]. The key is the ORIGINAL XML filename (incl. .xml),
# reconstructed from FilesCatalog.XML_Path (which holds the `<base>_clean.xml`
# name). So the lookup matches directly on the loop's XML basename — robust even
# where the internal File_Name differs from the XML filename (e.g. test data); in
# production they are equal anyway.
load_per_file_objects() {
    FO_NAME=(); FO_COUNT=()
    local inlist unionexpr
    inlist=$(_sql_inlist "${P1_OBJECT_TABLES[@]}")
    unionexpr=$(pp_query_raw "SELECT string_agg('SELECT File_Name AS fn, COUNT(*) AS c FROM '||table_name||' GROUP BY File_Name', ' UNION ALL ') FROM information_schema.tables WHERE table_name IN ($inlist)")
    [ -z "$unionexpr" ] && return 0
    local cnt fn
    while IFS=$'\t' read -r cnt fn; do
        [ -z "$fn" ] && continue
        FO_NAME+=("$fn"); FO_COUNT+=("$cnt")
    done < <("$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c \
        "WITH per_file AS ($unionexpr),
              mapped AS (
                SELECT p.c AS c,
                       COALESCE(regexp_replace(regexp_replace(f.XML_Path, '^.*/', ''), '_clean\.xml\$', '.xml'), p.fn || '.xml') AS xml_name
                FROM per_file p
                LEFT JOIN FilesCatalog f ON f.File_Name = p.fn
              )
         SELECT SUM(c)::BIGINT || chr(9) || xml_name FROM mapped GROUP BY xml_name" 2>/dev/null)
}

# lookup_file_objects <XML file name incl. .xml> → object count or empty (unknown).
lookup_file_objects() {
    local i
    for i in "${!FO_NAME[@]}"; do
        if [ "${FO_NAME[$i]}" = "$1" ]; then echo "${FO_COUNT[$i]}"; return; fi
    done
    echo ""
}

# ----------------------------------------------------------------------------
# Environment context — robust detection with fallbacks, never hard-aborts.
# Fills the ENV_* globals; collect_duckdb_settings adds the effective settings
# (with the memory_limit_prefix active — otherwise wrong defaults would be logged).
# ----------------------------------------------------------------------------
collect_environment() {
    ENV_OS_PRETTY=$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
    [ -z "$ENV_OS_PRETTY" ] && ENV_OS_PRETTY="unknown"
    ENV_KERNEL=$(uname -r 2>/dev/null || echo "unknown")
    ENV_ARCH=$(uname -m 2>/dev/null || echo "unknown")

    if [ -n "$CODESPACES" ]; then
        ENV_CONTAINER_MODE="codespaces"
    elif [ -f /.dockerenv ] && [ "$REMOTE_CONTAINERS" = "true" ]; then
        ENV_CONTAINER_MODE="devcontainer"
    elif [ -f /.dockerenv ]; then
        ENV_CONTAINER_MODE="container"
    else
        ENV_CONTAINER_MODE="host"
    fi

    ENV_CPU_CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 0)

    # RAM limit: cgroup v2 → v1 → /proc/meminfo (bytes). 'max' (no limit) → fallback.
    ENV_RAM_BYTES=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
    if [[ ! "$ENV_RAM_BYTES" =~ ^[0-9]+$ ]]; then
        ENV_RAM_BYTES=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
    fi
    if [[ ! "$ENV_RAM_BYTES" =~ ^[0-9]+$ ]]; then
        local memkb
        memkb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
        if [[ "$memkb" =~ ^[0-9]+$ ]]; then ENV_RAM_BYTES=$((memkb * 1024)); else ENV_RAM_BYTES=0; fi
    fi
    ENV_SWAP_BYTES=$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null)
    [[ "$ENV_SWAP_BYTES" =~ ^[0-9]+$ ]] || ENV_SWAP_BYTES=0

    local dv
    dv=$("$DUCKDB_BIN" --version 2>/dev/null)
    ENV_DUCKDB_VERSION=$(echo "$dv" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v')
    [ -z "$ENV_DUCKDB_VERSION" ] && ENV_DUCKDB_VERSION="unknown"
    ENV_DUCKDB_BUILD=$(echo "$dv" | grep -oE '[0-9a-f]{8,}$' | head -1)
    # Display without the build hash, e.g. "v1.5.3 (Variegata)".
    ENV_DUCKDB_DISPLAY=$(echo "$dv" | sed -E 's/[[:space:]]+[0-9a-f]{8,}$//')
    [ -z "$ENV_DUCKDB_DISPLAY" ] && ENV_DUCKDB_DISPLAY="unknown"

    # awk binary + flavor — resolved path plus a one-line flavor tag, so every
    # report answers the "which awk ran Phase S?" question by itself (the awk
    # cascade lands on different flavors per host: mawk/gawk/BWK awk on stock
    # macOS). --version covers gawk/BWK, -W version covers mawk; both quiet
    # failures fall through to "unknown".
    ENV_AWK_BIN="${AWK_BIN:-$(command -v awk 2>/dev/null || echo awk)}"
    ENV_AWK_FLAVOR=$("$ENV_AWK_BIN" --version 2>/dev/null | head -1)
    [ -z "$ENV_AWK_FLAVOR" ] && ENV_AWK_FLAVOR=$("$ENV_AWK_BIN" -W version 2>&1 | head -1 | grep -iE 'awk|version')
    [ -z "$ENV_AWK_FLAVOR" ] && ENV_AWK_FLAVOR="unknown"
}

# Determine the effective DuckDB settings WITH memory_limit_prefix active.
collect_duckdb_settings() {
    local row
    row=$( { memory_limit_prefix
             echo "SELECT current_setting('threads')||chr(9)||current_setting('memory_limit')||chr(9)||current_setting('temp_directory')||chr(9)||current_setting('max_temp_directory_size')||chr(9)||current_setting('preserve_insertion_order');"
           } | "$DUCKDB_BIN" -noheader -list 2>/dev/null | head -1 )
    IFS=$'\t' read -r ENV_DUCKDB_THREADS ENV_DUCKDB_MEM ENV_SPILL_DIR ENV_SPILL_MAX ENV_PRESERVE_ORDER <<< "$row"
    [ -z "$ENV_DUCKDB_THREADS" ] && ENV_DUCKDB_THREADS="n/a"
    [ -z "$ENV_DUCKDB_MEM" ]     && ENV_DUCKDB_MEM="n/a"
    [ -z "$ENV_SPILL_DIR" ]      && ENV_SPILL_DIR="n/a"
    [ -z "$ENV_SPILL_MAX" ]      && ENV_SPILL_MAX="n/a"
    [ -z "$ENV_PRESERVE_ORDER" ] && ENV_PRESERVE_ORDER="n/a"

    # Is the spill dir its own mount? (mountpoint preferred, /proc/mounts as fallback).
    ENV_SPILL_DEDICATED=false
    if [ -n "$ENV_SPILL_DIR" ] && [ "$ENV_SPILL_DIR" != "n/a" ] && [ "$ENV_SPILL_DIR" != ".tmp" ]; then
        if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$ENV_SPILL_DIR" 2>/dev/null; then
            ENV_SPILL_DEDICATED=true
        elif grep -q " $ENV_SPILL_DIR " /proc/mounts 2>/dev/null; then
            ENV_SPILL_DEDICATED=true
        fi
    fi
    if $ENV_SPILL_DEDICATED; then ENV_SPILL_DEDICATED_TXT="dedicated volume"; else ENV_SPILL_DEDICATED_TXT="shared"; fi
}

# build_run_meta — derived display strings (Options/Attempt/Mode) for the header.
build_run_meta() {
    if $TEST_MODE;          then RUN_MODE="test";   RUN_MODE_TITLE="TEST Batch"
    elif [[ "$MODE" == "single" ]]; then RUN_MODE="single"; RUN_MODE_TITLE="Single File"
    else                         RUN_MODE="batch";  RUN_MODE_TITLE="Batch"; fi

    local parts=()
    $FORCE_REBUILD && parts+=("force-rebuild")
    $SPLIT_MODE    && parts+=("split")
    parts+=("memory-limit=${MEMORY_LIMIT:-default}")
    if $FAIL_FAST;    then parts+=("fail-fast=on");    else parts+=("fail-fast=off");    fi
    if $NO_AUTO_HEAL; then parts+=("no-auto-heal=on"); else parts+=("no-auto-heal=off"); fi
    OPTIONS_TEXT=$(printf '%s · ' "${parts[@]}"); OPTIONS_TEXT="${OPTIONS_TEXT% · }"

    if [ "$ATTEMPT" -le 1 ] && [ -z "$RETRY_REASON" ] && [ -z "$RETRY_OF" ]; then
        ATTEMPT_TEXT="1 (first run)"
    else
        ATTEMPT_TEXT="$ATTEMPT"
        if [ -n "$RETRY_REASON" ]; then
            if $RETRY_REASON_KNOWN; then
                ATTEMPT_TEXT="$ATTEMPT_TEXT · retry-reason: $RETRY_REASON"
            else
                ATTEMPT_TEXT="$ATTEMPT_TEXT · retry-reason: $RETRY_REASON (custom)"
            fi
        fi
        [ -n "$RETRY_OF" ] && ATTEMPT_TEXT="$ATTEMPT_TEXT · retry-of: $RETRY_OF"
    fi
}

# ----------------------------------------------------------------------------
# Writer — text log + JSON sidecar (at the end of the run, idempotent).
# ----------------------------------------------------------------------------

write_text_log() {
    local logfile="$1"
    local phases_sum=0 i
    for i in "${!PH_DUR[@]}"; do
        phases_sum=$(awk -v a="$phases_sum" -v b="${PH_DUR[$i]}" 'BEGIN{printf "%.3f", a+b}')
    done

    {
        printf '================================================================================\n'
        printf 'FileMaker XML %s Import Log\n' "$RUN_MODE_TITLE"
        printf '================================================================================\n'
        printf 'Start Time:        %s\n' "$RUN_STARTED_HUMAN"
        printf 'End Time:          %s\n' "$RUN_ENDED_HUMAN"
        printf 'fm-lab Version:    %s  (commit %s)\n' "${FMLAB_VERSION:-unknown}" "${FMLAB_SOURCE_COMMIT:-unknown}"
        printf 'Converter Version: %s\n' "$CONVERTER_VERSION"
        printf 'Log Schema:        %s\n' "$LOG_SCHEMA"
        printf 'Schema Version:    %s  (Template)\n' "$SCHEMA_VERSION_EXPECTED"
        printf 'Mode:              %s\n' "$RUN_MODE"
        printf 'Options:           %s\n' "$OPTIONS_TEXT"
        printf 'Attempt:           %s\n' "$ATTEMPT_TEXT"
        printf 'Strategy:          %s\n' "${RUN_STRATEGY_TEXT:-n/a}"
        printf -- '--------------------------------------------------------------------------------\n'
        printf 'Environment\n'
        printf '  OS:              %s · %s %s\n' "$ENV_OS_PRETTY" "$ENV_KERNEL" "$ENV_ARCH"
        printf '  Container:       %s\n' "$ENV_CONTAINER_MODE"
        printf '  CPU cores:       %s\n' "$ENV_CPU_CORES"
        printf '  RAM limit:       %s  (swap %s)\n' "$(fmt_gib "$ENV_RAM_BYTES")" "$(fmt_gib "$ENV_SWAP_BYTES")"
        printf '  DuckDB:          %s\n' "$ENV_DUCKDB_DISPLAY"
        printf '  webbed:          %s\n' "${WEBBED_VERSION_DETECTED:-unknown}"
        printf '  AWK:             %s  (%s)\n' "$ENV_AWK_BIN" "$ENV_AWK_FLAVOR"
        printf '  DuckDB threads:  %s\n' "$ENV_DUCKDB_THREADS"
        printf '  DuckDB memory:   %s (effective)\n' "$ENV_DUCKDB_MEM"
        printf '  Spill dir:       %s  (%s, max %s)\n' "$ENV_SPILL_DIR" "$ENV_SPILL_DEDICATED_TXT" "$ENV_SPILL_MAX"
        printf '  preserve_order:  %s\n' "$ENV_PRESERVE_ORDER"
        printf -- '--------------------------------------------------------------------------------\n'
        printf 'Files:             %s   (Success %s · Skipped %s · Failed %s)\n' \
            "$TOTAL" "$SUCCESS_COUNT" "$SKIPPED_COUNT" "${#FAILED_FILES[@]}"
        printf 'Total Duration:    %s  (%s s)\n' "$(dur_human "$BATCH_DURATION")" "$BATCH_DURATION"

        if [[ "$SCHEMA_ACTION_EXECUTED" =~ ^(auto_heal_rebuild|force_rebuild)$ ]]; then
            printf '\nSchema Action:     %s (%s)\n' "$SCHEMA_ACTION_EXECUTED" "$SCHEMA_REASON"
        fi

        printf '\n'
        printf '================================================================================\n'
        printf 'Phase Timeline                                (P2–P6 batch-wide, not per file)\n'
        printf '================================================================================\n'
        printf '%-4s %-26s %-9s %-9s %-13s %s\n' "#" "Phase" "Start" "End" "Duration" "Produced"
        printf -- '--------------------------------------------------------------------------------\n'
        for i in "${!PH_ID[@]}"; do
            printf '%-4s %-26s %-9s %-9s %-13s %s\n' \
                "${PH_ID[$i]}" "$(phase_label_txt "${PH_ID[$i]}" "${PH_NAME[$i]}")" \
                "${PH_START_ISO[$i]#*T}" "${PH_END_ISO[$i]#*T}" \
                "$(dur_human "${PH_DUR[$i]}")" "${PH_PROD_TXT[$i]}"
        done
        printf -- '--------------------------------------------------------------------------------\n'
        printf '%-51s %s\n' "                                          Σ Phases" "$(dur_human "$phases_sum")"

        printf '\n'
        printf '================================================================================\n'
        printf 'P1 · Extract — per file                                (substep of Phase 1)\n'
        printf '================================================================================\n'
        printf '%-11s %-33s %-12s %-10s %-11s %s\n' "Finished at" "File" "Duration" "Peak-RSS" "Sys-Avail↓" "Objects"
        printf -- '--------------------------------------------------------------------------------\n'
        local sum_obj=0 j objs objs_disp peak_disp avail_disp
        for j in "${!FL_NAME[@]}"; do
            objs=$(lookup_file_objects "${FL_NAME[$j]}")
            if [ -n "$objs" ]; then sum_obj=$((sum_obj + objs)); objs_disp=$(group_de "$objs"); else objs_disp="n/a"; fi
            if [ -n "${FL_PEAKRSS[$j]:-}" ]; then peak_disp="$(_kb_mb "${FL_PEAKRSS[$j]}") MB"; else peak_disp="n/a"; fi
            if [ -n "${FL_MINAVAIL[$j]:-}" ]; then avail_disp="$(_kb_mb "${FL_MINAVAIL[$j]}") MB"; else avail_disp="n/a"; fi
            printf '%-11s %-33s %11.3fs %-10s %-11s %s\n' \
                "${FL_COMPLETED[$j]#*T}" "${FL_NAME[$j]}" "${FL_DUR[$j]}" "$peak_disp" "$avail_disp" "$objs_disp"
        done
        printf -- '--------------------------------------------------------------------------------\n'
        printf '%-11s %-33s %11.3fs %-10s %-11s %s\n' "" "Σ ${#FL_NAME[@]} files" "$phases_sum" "" "" "$(group_de "$sum_obj")"

        if [ "$SKIPPED_COUNT" -gt 0 ]; then
            printf '\nSkipped Files (unsupported format):\n'
            for j in "${SKIPPED_FILES[@]}"; do printf '  - %s\n' "$j"; done
        fi
        if [ "${#FAILED_FILES[@]}" -gt 0 ]; then
            printf '\nFailed Files:\n'
            for j in "${FAILED_FILES_INFO[@]}"; do
                local fn="${j%%|*}" rest="${j#*|}"; local cat="${rest%%|*}" hint="${rest#*|}"
                printf '  ✗ %s  [%s]\n      → %s\n' "$fn" "$cat" "$hint"
            done
        fi
        if [ "$POSTCHECK_WARN" -gt 0 ]; then
            printf '\nPost-Check Warnings: %s\n' "$POSTCHECK_WARN"
            for j in "${POSTCHECK_FINDINGS[@]}"; do printf '  - %s\n' "$j"; done
        fi
        printf '================================================================================\n'
    } > "$logfile"
}

write_json_sidecar() {
    local jsonfile="$1"
    local ph_tsv fl_tsv i j
    ph_tsv=$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX"); fl_tsv=$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")

    # Store phases/files as TAB-separated tables (idx as the first column for stable
    # order). DuckDB reads them as in-memory tables and assembles the JSON itself —
    # all escaping (filenames, quotes, Unicode) is done by json_object/COPY FORMAT json.
    # Scalars come via getenv() from the J_* env vars.
    for i in "${!PH_ID[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$i" "${PH_ID[$i]}" "${PH_NAME[$i]}" "${PH_START_ISO[$i]}" "${PH_END_ISO[$i]}" \
            "${PH_DUR[$i]}" "${PH_PROD_JSON[$i]}" >> "$ph_tsv"
    done
    for j in "${!FL_NAME[@]}"; do
        local objs; objs=$(lookup_file_objects "${FL_NAME[$j]}")
        [ -z "$objs" ] && objs="null"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$j" "${FL_NAME[$j]}" "${FL_SIZE[$j]:-null}" "${FL_ENC[$j]}" "${FL_STATUS[$j]}" \
            "${FL_DUR[$j]}" "${FL_COMPLETED[$j]}" "$objs" \
            "${FL_ERR_CAT[$j]}" "${FL_ERR_RC[$j]}" "${FL_ERR_HINT[$j]}" >> "$fl_tsv"
    done

    # read_csv fails on an EMPTY file (can happen with fail-fast before P1 finishes
    # → 0 phases). In that case create an empty, typed table instead, so the COPY
    # query (with COALESCE → '[]') still writes a valid document.
    local ph_cols="{'idx':'INT','id':'VARCHAR','name':'VARCHAR','started_at':'VARCHAR','ended_at':'VARCHAR','duration_s':'VARCHAR','produced':'VARCHAR'}"
    local fl_cols="{'idx':'INT','name':'VARCHAR','size':'VARCHAR','encoding':'VARCHAR','status':'VARCHAR','duration_s':'VARCHAR','completed_at':'VARCHAR','objects':'VARCHAR','ecat':'VARCHAR','erc':'VARCHAR','ehint':'VARCHAR'}"
    local ph_create fl_create
    if [ -s "$ph_tsv" ]; then
        ph_create="CREATE TEMP TABLE _ph AS SELECT * FROM read_csv('$ph_tsv', delim='\t', header=false, quote='', escape='', columns=$ph_cols);"
    else
        ph_create="CREATE TEMP TABLE _ph(idx INT, id VARCHAR, name VARCHAR, started_at VARCHAR, ended_at VARCHAR, duration_s VARCHAR, produced VARCHAR);"
    fi
    if [ -s "$fl_tsv" ]; then
        fl_create="CREATE TEMP TABLE _fl AS SELECT * FROM read_csv('$fl_tsv', delim='\t', header=false, quote='', escape='', columns=$fl_cols);"
    else
        fl_create="CREATE TEMP TABLE _fl(idx INT, name VARCHAR, size VARCHAR, encoding VARCHAR, status VARCHAR, duration_s VARCHAR, completed_at VARCHAR, objects VARCHAR, ecat VARCHAR, erc VARCHAR, ehint VARCHAR);"
    fi

    local rc=0
    # In-memory DuckDB (no master-DB access → no lock contention). getenv() reads the
    # exported J_* scalars; TRY_CAST keeps the output robust (non-numeric values →
    # JSON null instead of an abort). COPY … (FORMAT json) writes the document as one
    # line directly to *.json.tmp; then an atomic mv.
    if PH_TSV="$ph_tsv" FL_TSV="$fl_tsv" \
       J_SCHEMA="$LOG_SCHEMA" \
       J_STARTED="$RUN_STARTED_ISO" J_ENDED="$RUN_ENDED_ISO" J_DURATION="$BATCH_DURATION" \
       J_CONVERTER="$CONVERTER_VERSION" J_SCHEMAVER="$SCHEMA_VERSION_EXPECTED" \
       J_FMLAB_VER="${FMLAB_VERSION:-unknown}" J_FMLAB_COMMIT="${FMLAB_SOURCE_COMMIT:-unknown}" \
       J_POLICY="$($STREAMIFY_MODE && echo sax || echo dom)" \
       J_POLICY_SOURCE="${POLICY_SOURCE:-}" J_SENTINEL_SOURCE="${WS_SENTINEL_SOURCE:-}" \
       J_WS_SENTINEL="$WS_SENTINEL_ON" J_STRATEGY="${RUN_STRATEGY_TEXT:-}" \
       J_WEBBED_VER="${WEBBED_VERSION_DETECTED:-unknown}" \
       J_MODE="$RUN_MODE" \
       J_FORCE_REBUILD="$FORCE_REBUILD" J_SPLIT="$SPLIT_MODE" J_FAIL_FAST="$FAIL_FAST" \
       J_NO_AUTO_HEAL="$NO_AUTO_HEAL" J_QUIET="$QUIET_MODE" J_MEMORY_LIMIT="$MEMORY_LIMIT" \
       J_JOBS="$JOBS" J_PARALLEL="${PARALLEL_P1:-false}" \
       J_ATTEMPT="$ATTEMPT" J_RETRY_REASON="$RETRY_REASON" J_RETRY_REASON_KNOWN="$RETRY_REASON_KNOWN" \
       J_RETRY_OF="$RETRY_OF" J_SCHEMA_ACTION="$SCHEMA_ACTION_EXECUTED" \
       J_TOTAL="$TOTAL" J_SUCCESS="$SUCCESS_COUNT" J_SKIPPED="$SKIPPED_COUNT" J_FAILED="${#FAILED_FILES[@]}" \
       J_OS_PRETTY="$ENV_OS_PRETTY" J_KERNEL="$ENV_KERNEL" J_ARCH="$ENV_ARCH" \
       J_CONTAINER="$ENV_CONTAINER_MODE" J_CPU="$ENV_CPU_CORES" \
       J_RAM="$ENV_RAM_BYTES" J_SWAP="$ENV_SWAP_BYTES" \
       J_DUCKDB_VER="$ENV_DUCKDB_VERSION" J_DUCKDB_BUILD="$ENV_DUCKDB_BUILD" \
       J_DUCKDB_THREADS="$ENV_DUCKDB_THREADS" J_DUCKDB_MEM="$ENV_DUCKDB_MEM" \
       J_PRESERVE_ORDER="$ENV_PRESERVE_ORDER" \
       J_SPILL_DIR="$ENV_SPILL_DIR" J_SPILL_MAX="$ENV_SPILL_MAX" J_SPILL_DEDICATED="$ENV_SPILL_DEDICATED" \
       J_AWK_BIN="$ENV_AWK_BIN" J_AWK_FLAVOR="$ENV_AWK_FLAVOR" \
       "$DUCKDB_BIN" <<SQL >/dev/null 2>&1
$ph_create
$fl_create
COPY (
  SELECT
    getenv('J_SCHEMA') AS "schema",
    {
      'started_at': getenv('J_STARTED'),
      'ended_at': getenv('J_ENDED'),
      'duration_s': TRY_CAST(getenv('J_DURATION') AS DOUBLE),
      'converter_version': getenv('J_CONVERTER'),
      'schema_version': getenv('J_SCHEMAVER'),
      'fmlab_version': getenv('J_FMLAB_VER'),
      'source_commit': nullif(getenv('J_FMLAB_COMMIT'),'unknown'),
      'strategy': {
        'policy': getenv('J_POLICY'),
        'source': nullif(getenv('J_POLICY_SOURCE'),''),
        'ws_sentinel': getenv('J_WS_SENTINEL')='true',
        'sentinel_source': nullif(getenv('J_SENTINEL_SOURCE'),''),
        'text': nullif(getenv('J_STRATEGY'),'')
      },
      'mode': getenv('J_MODE'),
      'options': {
        'force_rebuild': getenv('J_FORCE_REBUILD')='true',
        'split': getenv('J_SPLIT')='true',
        'fail_fast': getenv('J_FAIL_FAST')='true',
        'no_auto_heal': getenv('J_NO_AUTO_HEAL')='true',
        'quiet': getenv('J_QUIET')='true',
        'memory_limit': nullif(getenv('J_MEMORY_LIMIT'),''),
        'jobs': TRY_CAST(getenv('J_JOBS') AS BIGINT),
        'parallel': getenv('J_PARALLEL')='true'
      },
      'attempt': TRY_CAST(getenv('J_ATTEMPT') AS BIGINT),
      'retry_reason': nullif(getenv('J_RETRY_REASON'),''),
      'retry_reason_known': getenv('J_RETRY_REASON_KNOWN')='true',
      'retry_of': nullif(getenv('J_RETRY_OF'),''),
      'schema_action': nullif(getenv('J_SCHEMA_ACTION'),''),
      'result': {
        'total': TRY_CAST(getenv('J_TOTAL') AS BIGINT),
        'success': TRY_CAST(getenv('J_SUCCESS') AS BIGINT),
        'skipped': TRY_CAST(getenv('J_SKIPPED') AS BIGINT),
        'failed': TRY_CAST(getenv('J_FAILED') AS BIGINT)
      }
    } AS run,
    {
      'os': {'pretty_name': getenv('J_OS_PRETTY'), 'kernel': getenv('J_KERNEL'), 'arch': getenv('J_ARCH')},
      'container_mode': getenv('J_CONTAINER'),
      'cpu_cores': TRY_CAST(getenv('J_CPU') AS BIGINT),
      'ram_limit_bytes': TRY_CAST(getenv('J_RAM') AS BIGINT),
      'swap_limit_bytes': TRY_CAST(getenv('J_SWAP') AS BIGINT),
      'duckdb': {
        'version': getenv('J_DUCKDB_VER'),
        'build': nullif(getenv('J_DUCKDB_BUILD'),''),
        'threads': TRY_CAST(getenv('J_DUCKDB_THREADS') AS BIGINT),
        'memory_limit': getenv('J_DUCKDB_MEM'),
        'preserve_insertion_order': getenv('J_PRESERVE_ORDER')='true'
      },
      'webbed': {'version': nullif(getenv('J_WEBBED_VER'),'unknown')},
      'spill': {'dir': getenv('J_SPILL_DIR'), 'max': getenv('J_SPILL_MAX'), 'dedicated_volume': getenv('J_SPILL_DEDICATED')='true'},
      'awk': {'bin': getenv('J_AWK_BIN'), 'flavor': nullif(getenv('J_AWK_FLAVOR'),'unknown')}
    } AS environment,
    COALESCE((SELECT to_json(list(json_object(
        'id', id, 'name', name,
        'started_at', started_at, 'ended_at', ended_at,
        'duration_s', TRY_CAST(duration_s AS DOUBLE),
        'produced', produced::JSON
      ) ORDER BY idx)) FROM _ph), '[]'::JSON) AS phases,
    COALESCE((SELECT to_json(list(json_object(
        'name', name,
        'size_bytes', CASE WHEN size IN ('','null') THEN NULL ELSE TRY_CAST(size AS BIGINT) END,
        'encoding', nullif(encoding,''),
        'status', status,
        'duration_s', TRY_CAST(duration_s AS DOUBLE),
        'completed_at', nullif(completed_at,''),
        'objects', CASE WHEN objects IN ('','null') THEN NULL ELSE TRY_CAST(objects AS BIGINT) END,
        'error', CASE WHEN status='failed'
                      THEN json_object('category', nullif(ecat,''), 'exit_code', TRY_CAST(nullif(erc,'') AS INT), 'hint', nullif(ehint,''))
                      ELSE NULL END
      ) ORDER BY idx)) FROM _fl), '[]'::JSON) AS files
) TO '$jsonfile.tmp' (FORMAT json);
SQL
    then
        mv -f "$jsonfile.tmp" "$jsonfile"
    else
        rc=1
        rm -f "$jsonfile.tmp" 2>/dev/null
    fi
    rm -f "$ph_tsv" "$fl_tsv"
    return $rc
}

# finalize_logs — writes the text log + JSON sidecar exactly once. Idempotent,
# so it can be called from multiple exit paths (normal end, fail-fast).
finalize_logs() {
    $LOGS_FINALIZED && return 0
    LOGS_FINALIZED=true
    mkdir -p "$LOG_DIR"
    # Ensure end time/duration are set in case they aren't yet (e.g. fail-fast).
    if [ -z "$BATCH_END" ]; then BATCH_END=$(now_epoch); fi
    if [ -z "$BATCH_DURATION" ]; then
        BATCH_DURATION=$(awk -v a="$BATCH_END" -v b="${BATCH_START:-$BATCH_END}" 'BEGIN{printf "%.3f", a-b}')
    fi
    [ -z "$RUN_ENDED_HUMAN" ] && RUN_ENDED_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
    [ -z "$RUN_ENDED_ISO" ]   && RUN_ENDED_ISO=$(iso_now)
    write_text_log "$LOG_FILE"
    write_json_sidecar "$JSON_FILE" || emit_warn "JSON sidecar could not be written ($JSON_FILE)"
}
