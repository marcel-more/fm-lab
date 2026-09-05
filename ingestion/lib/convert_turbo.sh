#!/bin/bash
# katana-xml/lib/convert_turbo.sh — Turbo pipeline: Phase S (Split), D (Dispatch),
# C (Catmerge) + parallel P1 (part DBs/merge), manifest & catalog gates.
#
# Module of ingestion/convert_fm_xml.sh (shell split) — pure code movement,
# behavior unchanged. NOT independently executable: it is sourced by the driver
# (existence check there, A-B10) and uses its globals
# (DB_FILE, JOBS, TURBO_*, SUBCHUNK/RECMAP/NEST_MAP, AWK_BIN, …).
# bash-3.2 discipline (macOS system bash): no `case` in $(…), no bash-4+.

# Turbo DB initialization (chunk map/manifest). Called as a function AFTER lock
# acquisition (A-B2): the earlier top-level `CREATE OR REPLACE TABLE chunkmap` ran
# BEFORE acquire_lock — a second start destroyed the chunk-map plan of a running
# import and only failed on the lock AFTERWARDS (exit 7).
init_turbo_dbs() {
    $TURBO_MODE || return 0
    mkdir -p "$STREAMING_DIR"
    # Fresh chunkmap per run (transient plan). Schema = core + operative columns.
    "$DUCKDB_BIN" "$CHUNKMAP_DB" -c "
        CREATE OR REPLACE TABLE chunkmap (
            chunk_id      BIGINT,        -- globally unique within the run
            file_name     VARCHAR,       -- FileMaker file (without .xml)
            catalog       VARCHAR,       -- branch/catalog (main, LayoutCatalog, …)
            split_group   VARCHAR,       -- file_name::catalog
            split_number  INTEGER,       -- 0-based, global per catalog (drives seq_offset)
            chunk_path    VARCHAR,       -- absolute path of the chunk XML
            record_count  INTEGER,       -- records in the sub-chunk (load weight)
            seq_offset    BIGINT,        -- split_number × sub_m (Sequence_ID bridge)
            content_hash  VARCHAR,       -- sha256 of the preprocessed chunk bytes
            parser_policy VARCHAR,       -- dom | sax
            est_bytes     BIGINT,        -- UTF-8 bytes of the chunk XML (granularity/backoff)
            status        VARCHAR,       -- pending | done | …
            attempt       INTEGER        -- backoff counter
        );" >/dev/null 2>&1 || { echo "ERROR: Chunk-map DB ($CHUNKMAP_DB) could not be initialized."; exit 3; }
    init_manifest_db
}

# Persistent manifest tables (manifest_file/manifest_catalog/pipeline_state).
# Split out of init_turbo_dbs: the classic single-file path (TURBO_MODE=false)
# also writes a manifest row after a complete P1–P6 chain and needs the tables
# without the transient chunkmap. Idempotent (CREATE IF NOT EXISTS).
init_manifest_db() {
    mkdir -p "$STREAMING_DIR"
    # Manifest (PERSISTENT): one row per source XML (key = XML base name).
    # internal_file_name = the internal FileMaker File_Name (multiple XML exports of the
    # same FileMaker file share it → Phase R must treat them as a group; collision case).
    "$DUCKDB_BIN" "$MANIFEST_DB" -c "
        CREATE TABLE IF NOT EXISTS manifest_file (
            file_name          VARCHAR PRIMARY KEY,  -- XML base name without .xml
            internal_file_name VARCHAR,              -- internal FileMaker File_Name
            file_mtime         BIGINT,               -- seconds (fast prefilter)
            file_size          BIGINT,               -- bytes (fast prefilter)
            file_hash          VARCHAR,              -- sha256 of the RAW XML (authoritative)
            saxml_version      VARCHAR,
            fm_version         VARCHAR,
            has_ddr_info       VARCHAR,
            converter_version  VARCHAR,              -- drift forces a full rebuild
            schema_version     VARCHAR,              -- drift forces a full rebuild
            last_ingest_ts     TIMESTAMP
        );" >/dev/null 2>&1 || { echo "ERROR: Manifest DB ($MANIFEST_DB) could not be initialized."; exit 3; }
    # manifest_catalog (PERSISTENT): one row per (file × catalog).
    # catalog_hash = md5(string_agg(content_hash ORDER BY seq_offset, split_number))
    # over all sub-chunks of the split-group (canonical global order —
    # split_number alone restarts per OOM-resplit group). Backoff-hit catalogs
    # (NULL content_hash rows) get NO row for that run — deleted, not upserted
    # (a subset hash would mismatch every future fresh split → permanent reload).
    # Gates the (expensive) P1 parse per catalog: same
    # hash → chunks skipped_unchanged. The key is the XML base name (like manifest_file),
    # NOT the internal File_Name — collision groups fall back to whole-file anyway.
    "$DUCKDB_BIN" "$MANIFEST_DB" -c "
        CREATE TABLE IF NOT EXISTS manifest_catalog (
            file_name      VARCHAR,       -- XML base name without .xml
            catalog        VARCHAR,       -- branch/catalog (main, LayoutCatalog, …)
            catalog_hash   VARCHAR,       -- md5 of the ordered content_hashes of the split-group
            record_count   BIGINT,        -- plausibility/telemetry
            last_ingest_ts TIMESTAMP,
            PRIMARY KEY (file_name, catalog)
        );" >/dev/null 2>&1 || { echo "ERROR: manifest_catalog could not be initialized."; exit 3; }
    # manifest_run (PERSISTENT, one row): policy fingerprint of the run that
    # wrote the currently stored hashes (policy-lock B1). The Phase-S chunk
    # bytes — and thus every content/catalog hash — are stamped by the SAX/DOM
    # policy and the chr(127) sentinel; the startup diagnosis compares this
    # fingerprint against the current run and NAMES a flip instead of leaving a
    # silent hash mismatch. Additive migration (CREATE IF NOT EXISTS): manifests
    # from older versions simply lack the row → the diagnosis stays silent
    # until the first successful run writes it (deliberate, no version bump).
    "$DUCKDB_BIN" "$MANIFEST_DB" -c "
        CREATE TABLE IF NOT EXISTS manifest_run (
            id                INTEGER PRIMARY KEY,  -- always 1 (single-row fingerprint)
            parser_policy     VARCHAR,              -- sax | dom
            ws_sentinel       VARCHAR,              -- true | false (chr(127) CR sentinel)
            webbed_version    VARCHAR,
            converter_version VARCHAR,
            ts                TIMESTAMP
        );" >/dev/null 2>&1 || { echo "ERROR: manifest_run could not be initialized."; exit 3; }
    # pipeline_state (PERSISTENT): small key/value table. Key 'catalogs_built'
    # = 'ok' as soon as P2–P6 ran COMPLETELY for the current manifest state.
    # Gate for the "no changes" short-circuit (safe against an abort between
    # Phase C [manifest written] and P6 [catalogs done]).
    "$DUCKDB_BIN" "$MANIFEST_DB" -c "
        CREATE TABLE IF NOT EXISTS pipeline_state (
            key   VARCHAR PRIMARY KEY,
            value VARCHAR
        );" >/dev/null 2>&1 || { echo "ERROR: pipeline_state could not be initialized."; exit 3; }
}

# ── Chunk/part-union merge hardening (a1) ──
# Space-delimited SET of tables in DB $1 that carry a PRIMARY KEY / UNIQUE constraint.
# The chunk/part-union merges (catmerge, _turbo_build_part, parquet variant) bulk-INSERT
# the parquet/chunk slices of one file into the master under the "chunks are record-disjoint"
# assumption. That breaks when a record lands in >1 chunk of the SAME file (multi-fed
# ScriptTriggers OR a sub-chunked DDR catalog) OR two exports share an internal File_Name
# (clone) → a plain INSERT raises a duplicate-key error and the whole catalog
# build is lost. Appending `ON CONFLICT DO NOTHING` absorbs such duplicates — but DuckDB
# requires a matching PK/UNIQUE constraint for that clause (it errors on a constraint-less
# table, which in turn can never raise a dup-key error on a plain INSERT). So the clause is
# applied ONLY to constrained tables; everything else stays a plain INSERT. Bit-identical on
# clean data (no conflicts → no-op), verified by the catmerge identity test.
_pk_constrained_tables() {
    "$DUCKDB_BIN" -readonly "$1" -noheader -list -c \
        "SELECT DISTINCT table_name FROM duckdb_constraints() WHERE constraint_type IN ('PRIMARY KEY','UNIQUE');" 2>/dev/null \
        | tr '\n' ' '
}

# Membership: echoes " ON CONFLICT DO NOTHING" if table $1 is in the PK set $2, else "".
_oc_clause() { case " $2 " in *" $1 "*) printf ' ON CONFLICT DO NOTHING' ;; *) printf '' ;; esac; }

# Boolean membership: is token $1 in the space-delimited set $2?
_in_set() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Schema-drift protection. Emits CREATE TABLE IF NOT EXISTS DDL (columns + NOT NULL + PRIMARY
# KEY, reconstructed from the seed DB $1) for the tables named in $2 (a comma-quoted IN
# list, e.g. "'A','B'"). Used before an incremental merge so a NEWLY-added part table
# exists in the master WITH its PK — required because the merge INSERT carries
# `ON CONFLICT DO NOTHING` for PK-constrained tables, which needs the PK to bind (a
# PK-less CREATE-AS-SELECT would fail with "no UNIQUE/PRIMARY KEY constraints"). Restricted
# to the MISSING tables (computed by the caller) so a pre-existing table's exotic column
# type can never break the parse. DEFAULT clauses are omitted — the merge supplies every
# column explicitly. UNIQUE-only tables (no PK) are not reconstructed (none in the schema).
_turbo_missing_table_ddl() {
    "$DUCKDB_BIN" -readonly "$1" -noheader -list -c "
WITH pk AS (
  SELECT table_name, string_agg('\"'||col||'\"', ',') AS cols
  FROM (SELECT table_name, unnest(constraint_column_names) AS col
        FROM duckdb_constraints() WHERE constraint_type='PRIMARY KEY')
  GROUP BY table_name)
SELECT 'CREATE TABLE IF NOT EXISTS \"' || c.table_name || '\" (' ||
       string_agg(c.column_name || ' ' || c.data_type || CASE WHEN c.is_nullable='NO' THEN ' NOT NULL' ELSE '' END, ', ' ORDER BY c.ordinal_position) ||
       COALESCE(', PRIMARY KEY (' || pk.cols || ')', '') || ');'
FROM information_schema.columns c
LEFT JOIN pk ON pk.table_name = c.table_name
WHERE c.table_schema='main' AND c.table_name IN ($2)
GROUP BY c.table_name, pk.cols;" 2>/dev/null
}

# Bring the (incremental) master $2 up to the seed $1's schema for the tables $4 (newline
# list), so the DELETE/INSERT merge — incl. `ON CONFLICT DO NOTHING` for PK tables — binds.
# Two self-healing cases (both no-ops in steady state / fresh build):
#   (1) ABSENT   — a newly-added part table missing in the master → CREATE it WITH its PK.
#   (2) PK-LESS  — a table the seed constrains with a PK but the master carries WITHOUT one
#                  (e.g. residue of an earlier PK-less create) → REBUILD it with the PK,
#                  preserving rows (rename→create→insert-ON-CONFLICT-dedupe→drop).
# Appends to log $3; sets MERGE_RC on failure.
_turbo_seed_missing_tables() {
    local seed="$1" master="$2" log="$3" tbls="$4"
    local have part_pk master_pk missing="" repair="" t2 ddl rt rddl
    have=$("$DUCKDB_BIN" -readonly "$master" -noheader -list -c \
        "SELECT table_name FROM information_schema.tables WHERE table_schema='main';" 2>/dev/null)
    part_pk=$(_pk_constrained_tables "$seed")
    master_pk=$(_pk_constrained_tables "$master")
    while IFS= read -r t2; do
        [ -z "$t2" ] && continue
        if ! printf '%s\n' "$have" | grep -qxF "$t2"; then
            missing="$missing${missing:+,}'$t2'"
        elif _in_set "$t2" "$part_pk" && ! _in_set "$t2" "$master_pk"; then
            repair="$repair $t2"
        fi
    done <<< "$tbls"

    # (1) create absent tables WITH their PK
    if [ -n "$missing" ]; then
        ddl=$(_turbo_missing_table_ddl "$seed" "$missing")
        [ -n "$ddl" ] && { "$DUCKDB_BIN" "$master" -c "$ddl" >> "$log" 2>&1 || MERGE_RC=$?; }
    fi
    # (2) repair PK-less tables in place (row-preserving, deduping)
    for rt in $repair; do
        rddl=$(_turbo_missing_table_ddl "$seed" "'$rt'")
        [ -z "$rddl" ] && continue
        "$DUCKDB_BIN" "$master" -c \
            "ALTER TABLE \"$rt\" RENAME TO \"${rt}__pkfix_old\"; $rddl INSERT INTO \"$rt\" SELECT * FROM \"${rt}__pkfix_old\" ON CONFLICT DO NOTHING; DROP TABLE \"${rt}__pkfix_old\";" \
            >> "$log" 2>&1 || MERGE_RC=$?
    done
    return 0
}

# a2 (visibility) — best-effort report of PK duplicates ABSORBED by the catmerge a1 guard.
# Without this the dedup is silent; here we name the tables whose parquet union carried
# duplicate primary keys (= 3A cross-chunk overlap or 3B clone collision actually fired).
# Reads PK columns from $1 (seed DB schema), scans the parquet dir $2 for the tables in $3.
# Never fails the build (all errors swallowed); logs one warning line per offending table.
# S0-2 (schema 1.17.0): the report is additionally PERSISTED into MergeAbsorptions in the
# master DB ($DB_FILE) so dashboards can surface it — same best-effort contract as the
# warning line (a failed persist never fails the build). Per merged table the persisted
# rows are refreshed (DELETE even when clean → a formerly-dup table goes back to 0 rows).
# The two root causes (3A chunk overlap = converter artifact vs. 3B clone file with the
# same internal File_Name = genuine UUID collision) are NOT distinguishable at the merge
# point; the table records the event, the dashboard labels it accordingly.
_turbo_catmerge_dup_report() {
    local _seed="$1" _pqdir="$2" _tables="$3" _map _t _cols _dcols _q n
    _map=$("$DUCKDB_BIN" -readonly "$_seed" -noheader -list -c \
        "SELECT table_name || chr(9) || '\"' || array_to_string(constraint_column_names, '\",\"') || '\"' \
         FROM duckdb_constraints() WHERE constraint_type = 'PRIMARY KEY';" 2>/dev/null) || return 0
    # DDL guard: P1 creates the table since 1.17.0; older incremental masters get it here.
    [ -n "${DB_FILE:-}" ] && "$DUCKDB_BIN" "$DB_FILE" -c \
        "CREATE TABLE IF NOT EXISTS MergeAbsorptions (Table_Name VARCHAR NOT NULL, File_Name VARCHAR, Absorbed_Count BIGINT, Merge_Path VARCHAR, Run_Timestamp TIMESTAMP);" \
        >/dev/null 2>&1
    while IFS=$'\t' read -r _t _cols; do
        [ -z "$_t" ] && continue
        case "$_tables" in *"$_t"*) ;; *) continue ;; esac
        ls "$_pqdir/$_t"/*.parquet >/dev/null 2>&1 || continue
        [ -n "${DB_FILE:-}" ] && "$DUCKDB_BIN" "$DB_FILE" -c \
            "DELETE FROM MergeAbsorptions WHERE Table_Name = '$_t' AND Merge_Path = 'catmerge';" >/dev/null 2>&1
        # H2: for heal tables with active healing, PK duplicates with DISTINCT
        # identity were REDISTRIBUTED (replacement UUIDs), not absorbed — count
        # only identity-identical collapses (3A chunk overlap / double
        # serialization) as absorbed, so MergeAbsorptions stays truthful.
        _dcols="$_cols"
        if [ "${FM_UUID_HEAL:-1}" != "0" ] && _turbo_heal_ident "$_t"; then
            _dcols="$_cols, $_hi_ident"
        fi
        _q="SELECT (SELECT COUNT(*) FROM read_parquet('$_pqdir/$_t/*.parquet')) \
             - (SELECT COUNT(*) FROM (SELECT DISTINCT $_dcols FROM read_parquet('$_pqdir/$_t/*.parquet')));"
        n=$("$DUCKDB_BIN" ":memory:" -noheader -list -c "$_q" 2>/dev/null)
        if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
            emit_warn "katmerge: $n duplicate PK in '$_t' absorbed (chunk overlap/clone, a1) — data consistent, but worth checking."
            if [ -n "${DB_FILE:-}" ]; then
                # Per-file attribution when the PK carries File_Name (all catalog tables do);
                # falls back to one unattributed row with the total.
                "$DUCKDB_BIN" "$DB_FILE" -c \
                    "INSERT INTO MergeAbsorptions \
                     SELECT '$_t', File_Name, COUNT(*) - COUNT(DISTINCT ($_dcols)), 'catmerge', (now() AT TIME ZONE 'UTC') \
                     FROM read_parquet('$_pqdir/$_t/*.parquet') \
                     GROUP BY File_Name HAVING COUNT(*) - COUNT(DISTINCT ($_dcols)) > 0;" \
                    >/dev/null 2>&1 \
                || "$DUCKDB_BIN" "$DB_FILE" -c \
                    "INSERT INTO MergeAbsorptions VALUES ('$_t', NULL, $n, 'catmerge', (now() AT TIME ZONE 'UTC'));" \
                    >/dev/null 2>&1
            fi
        fi
    done <<< "$_map"
    return 0
}

# ============================================================================
# UUID healing (H2) — cross-chunk heal merge for the sub-chunked catalogs
# (StepsForScripts, LayoutObjects, Layouts). Intra-chunk twins are healed in P1;
# a duplicate pair split across sub-chunk windows arrives here with the ORIGINAL
# UUID in both rows (each chunk saw one occurrence → thought it was survivor).
# The heal merge re-derives GLOBAL survivorship over the parquet union with the
# SAME formula/namespace/discriminator as P1 — deterministic: the same twin gets
# the same replacement UUID regardless of chunking (re-import stability). Rows
# with identical identity (3A chunk overlap / double serialization) yield
# identical UUIDs → the a1 ON CONFLICT guard collapses them exactly as before.
# The gate is a MANDATORY duplicate count (fail-hard) — unlike the best-effort
# a2 report: a silently failed count would skip healing while duplicates exist.
# Part-path fallback (_turbo_build_part/merge_part_dbs) intentionally does NOT
# heal cross-chunk pairs (stage-1 restriction): it keeps today's absorb+census
# behavior; v_check_absorbed_dups then shows the honest remainder.
# _turbo_heal_ident: per-table identity metadata; returns 1 for non-heal tables.
_turbo_heal_ident() {
    case "$1" in
    StepsForScripts)
        _hi_uuid='Step_UUID'
        _hi_ident='Script_ID, Step_Index'
        _hi_idnull='Script_ID IS NULL OR Step_Index IS NULL'
        _hi_disc="'script_id=' || Script_ID::VARCHAR || '·step_index=' || Step_Index::VARCHAR"
        ;;
    LayoutObjects)
        _hi_uuid='Object_UUID'
        _hi_ident='Layout_ID, Object_ID'
        _hi_idnull='Layout_ID IS NULL OR Object_ID IS NULL'
        _hi_disc="'layout_id=' || COALESCE(Layout_ID::VARCHAR, '') || '·object_id=' || COALESCE(Object_ID::VARCHAR, '')"
        ;;
    Layouts)
        _hi_uuid='L_UUID'
        _hi_ident='L_ID'
        _hi_idnull='L_ID IS NULL'
        _hi_disc="'layout_id=' || L_ID::VARCHAR"
        ;;
    *) return 1 ;;
    esac
    return 0
}

# Healing variant of the merge INSERT (replaces the plain a1 INSERT for heal
# tables when the gate saw duplicates). Runs against $DB_FILE → the P1 prelude
# macros (fm_heal_pick/fm_heal_uuid) are available there (master is a copy of a
# chunk DB; incremental masters are ≥ schema 1.19.0 after the version bump).
_turbo_emit_heal_merge() {  # $1 = table, $2 = pqdir → SQL on stdout
    _turbo_heal_ident "$1" || return 1
    cat <<EOF
INSERT INTO "$1" BY NAME
SELECT * EXCLUDE (_hm_surv)
       REPLACE (fm_heal_pick(_hm_surv, '$1', File_Name, $_hi_uuid, $_hi_disc) AS $_hi_uuid)
FROM (
    SELECT *,
        ($_hi_uuid IS NULL OR $_hi_idnull
         OR ($_hi_ident) = MIN(($_hi_ident)) OVER (PARTITION BY File_Name, $_hi_uuid)) AS _hm_surv
    FROM read_parquet('$2/$1/*.parquet')
)
ON CONFLICT DO NOTHING;
EOF
}

# Census completion for cross-chunk pairs: the chunk-local detail blocks only
# fire for UUIDs with >1 occurrence WITHIN a chunk — a chunk-split pair has no
# detail rows at all, and in mixed cases (2 twins in chunk A + 1 in chunk B) the
# chunk-local survivor label can differ from the global one. This emits, per
# heal table: (1) INSERT of missing identities (Chunk_Seq = -1 marks
# merge-derived rows), (2) UPDATE of chunk-local rows whose global status
# differs. Discriminator equality is the exact identity join (same format as P1).
_turbo_emit_heal_census() {  # $1 = table, $2 = pqdir → SQL on stdout
    _turbo_heal_ident "$1" || return 1
    local _nm _ty _pa _po
    case "$1" in
    StepsForScripts)
        _nm='any_value(Step_Name)'; _ty="'ScriptStep'"
        _pa='xml_unescape(any_value(Script_Name))'
        _po="'Step ' || (any_value(Step_Index) + 1)::VARCHAR" ;;
    LayoutObjects)
        _nm='any_value(Object_Name)'; _ty='any_value(Object_Type)'
        _pa='NULL'
        _po="'Layout ' || COALESCE(Layout_ID::VARCHAR, '?') || ' · object id ' || COALESCE(Object_ID::VARCHAR, '?')" ;;
    Layouts)
        _nm='xml_unescape(any_value(L_Name))'; _ty="'Layout'"
        _pa='NULL'
        _po="'layout id ' || L_ID::VARCHAR" ;;
    *) return 1 ;;
    esac
    cat <<EOF
CREATE OR REPLACE TEMP TABLE _hm_census AS
WITH occ AS (
    SELECT File_Name, $_hi_uuid AS Object_UUID, $_hi_ident,
           $_nm AS _cn_name, $_ty AS _cn_type, $_pa AS _cn_parent, $_po AS _cn_pos
    FROM read_parquet('$2/$1/*.parquet')
    WHERE $_hi_uuid IS NOT NULL
    GROUP BY File_Name, $_hi_uuid, $_hi_ident
),
dups AS (
    SELECT File_Name, Object_UUID FROM occ
    GROUP BY File_Name, Object_UUID HAVING COUNT(*) > 1
)
SELECT o.*,
       (($_hi_ident) = MIN(($_hi_ident)) OVER (PARTITION BY o.File_Name, o.Object_UUID)) AS is_min,
       $_hi_disc AS disc
FROM occ o
JOIN dups d USING (File_Name, Object_UUID);

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
SELECT m.File_Name, '$1', m.Object_UUID, m._cn_name, m._cn_type,
       ROW_NUMBER() OVER (PARTITION BY m.File_Name, m.Object_UUID ORDER BY ($_hi_ident)) AS Occurrence_Seq,
       -1 AS Chunk_Seq,
       m._cn_parent, m._cn_pos, left(COALESCE(m._cn_name, ''), 500), NULL,
       CASE WHEN NOT m.is_min THEN fm_heal_uuid('$1', m.File_Name, m.Object_UUID, m.disc) END,
       CASE WHEN m.is_min THEN 'kept-original' ELSE 'healed' END,
       m.disc
FROM _hm_census m
WHERE NOT EXISTS (
    SELECT 1 FROM DuplicateAbsorptionDetails d
    WHERE d.Catalog = '$1' AND d.File_Name = m.File_Name
      AND d.Object_UUID = m.Object_UUID AND d.Discriminator = m.disc)
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;

UPDATE DuplicateAbsorptionDetails d
SET Heal_Status = CASE WHEN m.is_min THEN 'kept-original' ELSE 'healed' END,
    Healed_UUID = CASE WHEN m.is_min THEN NULL
                       ELSE fm_heal_uuid('$1', m.File_Name, m.Object_UUID, m.disc) END
FROM _hm_census m
WHERE d.Catalog = '$1' AND d.File_Name = m.File_Name
  AND d.Object_UUID = m.Object_UUID AND d.Discriminator = m.disc
  AND d.Heal_Status IN ('kept-original', 'healed')
  AND d.Heal_Status IS DISTINCT FROM (CASE WHEN m.is_min THEN 'kept-original' ELSE 'healed' END);

DROP TABLE _hm_census;
EOF
}

# ============================================================================
# Parallel Phase-1 processing (opt-in via --jobs N)
# Each file runs into its own part DB under $PARTDB_DIR. Afterwards all successful
# part DBs are merged into the master DB. File_Names are disjoint per file → the
# merge is conflict-free (a DELETE pre-stage makes re-runs/incremental imports
# idempotent, analogous to the UPSERT/DELETE-INSERT semantics in P1).
# The result is bit-identical to the sequential run (verified via content hash).
# Per file $PARTDB_DIR/<idx>.{rc,out,dur} are written; the telemetry loop reads
# these instead of calling process_single_file itself. As its very last step the
# worker writes $PARTDB_DIR/<idx>.done — by that (and not by `kill -0`, which still
# reports an un-waited zombie as "alive") the rolling scheduler detects completion
# race-free.
# ============================================================================
_p1_worker() {
    local idx="$1"
    local fname; fname=$(basename "${XML_FILES[$idx]}")
    local pdb="$PARTDB_DIR/part_${idx}.duckdb"
    local t0 t1 out rc selfpid=$BASHPID sampler_pid=""
    # Memory sampler (Linux/proc only): every 0.2 s tracks the peak RSS of this
    # worker tree (duckdb) and the lowest system MemAvailable during the run;
    # continuously writes "<peak_rss_kb> <min_avail_kb>" to <idx>.mem, so the last
    # state survives even an OOM kill (SIGKILL).
    if [ -r /proc/meminfo ]; then
        (
            local peak=0 lowavail="" cur av
            while [ ! -f "$PARTDB_DIR/${idx}.memstop" ]; do
                cur=$(_tree_rss_kb "$selfpid"); [ "${cur:-0}" -gt "$peak" ] && peak=$cur
                av=$(_mem_avail_kb)
                if [ -n "$av" ] && { [ -z "$lowavail" ] || [ "$av" -lt "$lowavail" ]; }; then lowavail=$av; fi
                printf '%s %s' "$peak" "${lowavail:-}" > "$PARTDB_DIR/${idx}.mem"
                sleep 0.2
            done
        ) &
        sampler_pid=$!
    fi
    t0=$(now_epoch)
    out=$(P1_TARGET_DB="$pdb" process_single_file "$fname" 2>&1); rc=$?
    t1=$(now_epoch)
    if [ -n "$sampler_pid" ]; then
        : > "$PARTDB_DIR/${idx}.memstop"      # stop the sampler (it kept writing .mem)
        wait "$sampler_pid" 2>/dev/null
        rm -f "$PARTDB_DIR/${idx}.memstop"
    fi
    printf '%s' "$out" > "$PARTDB_DIR/${idx}.out"
    echo "$rc"        > "$PARTDB_DIR/${idx}.rc"
    awk -v a="$t1" -v b="$t0" 'BEGIN { printf "%.3f", a - b }' > "$PARTDB_DIR/${idx}.dur"
    # Keep the part DB only on success; failures/skips produce no merge.
    [ "$rc" -ne 0 ] && rm -f "$pdb"
    : > "$PARTDB_DIR/${idx}.done"   # sentinel: worker fully done (last action)
    return 0
}

# Live event for a file pre-processed in parallel mode (reads rc/out from
# $PARTDB_DIR). Quiet mode/parallel only — the detailed report/logging/array work
# is still done by the telemetry loop; this is solely about the `file` event for
# the frontend (counter + per-file highlight), which would otherwise arrive in one
# batch only after the (long) merge.
_emit_p1_file_event() {
    local idx="$1"
    local bn; bn=$(basename "${XML_FILES[$idx]}")
    local cur=$((idx + 1)) total=${#XML_FILES[@]}
    local rc; rc=$(cat "$PARTDB_DIR/${idx}.rc" 2>/dev/null); rc=${rc:-3}
    if [ "$rc" -eq 0 ]; then
        _emit_json file filename "$bn" index "int=$cur" total "int=$total" ok "bool=true"
    elif [ "$rc" -eq 4 ]; then
        _emit_json file filename "$bn" index "int=$cur" total "int=$total" ok "bool=false" status "skipped"
    else
        classify_error "$rc" "$(cat "$PARTDB_DIR/${idx}.out" 2>/dev/null)"
        _emit_json file filename "$bn" index "int=$cur" total "int=$total" ok "bool=false" status "failed" category "$ERR_CATEGORY"
    fi
}

# Rolling worker pool (bash-3.2-portable): continuously keeps up to $JOBS workers
# running — as soon as one finishes, the next file immediately moves into the freed
# slot (no waiting for the slowest of a wave). Completion is detected via the
# sentinel file $PARTDB_DIR/<idx>.done: `wait -n` only exists from bash 4.3
# (missing on macOS bash 3.2), and `kill -0` still reports an un-waited zombie as
# alive — the sentinel is portable and race-free. All NDJSON emissions stay here in
# the main process (serial) → no interleaving in the SSE stream; the workers only
# write sidecars. In quiet mode progress is emitted live per finished file
# (file_start at the start, file + phase_progress on collection). The 0.1 s poll
# latency is negligible against the seconds-long per-file parse times.
run_p1_parallel() {
    local n=${#XML_FILES[@]} i=0 done_count=0 s pid any bn
    local -a slot_pid slot_idx
    for ((s = 0; s < JOBS; s++)); do slot_pid[$s]=0; done

    while [ "$done_count" -lt "$n" ]; do
        # (a) fill free slots with the next file each
        for ((s = 0; s < JOBS && i < n; s++)); do
            [ "${slot_pid[$s]}" -ne 0 ] && continue
            if $QUIET_MODE; then
                bn=$(basename "${XML_FILES[$i]}")
                _emit_json file_start filename "$bn" index "int=$((i + 1))" total "int=$n"
                emit_log "[$((i + 1))/$n] Processing: $bn"
            fi
            rm -f "$PARTDB_DIR/${i}.done"
            _p1_worker "$i" &
            slot_pid[$s]=$!; slot_idx[$s]=$i; i=$((i + 1))
        done

        # (b) collect finished workers (sentinel file), free the slot immediately.
        # Zombie fallback (A-B5, pattern _turbo_dispatch): an OOM-/SIGKILL-killed
        # worker leaves NO sentinel — without the kill-0 fallback the pool would poll
        # forever. A missing .rc is treated downstream as an error.
        any=false
        for ((s = 0; s < JOBS; s++)); do
            pid=${slot_pid[$s]}; [ "$pid" -eq 0 ] && continue
            if [ -f "$PARTDB_DIR/${slot_idx[$s]}.done" ] || ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null   # reap the zombie (returns immediately)
                $QUIET_MODE && _emit_p1_file_event "${slot_idx[$s]}"
                slot_pid[$s]=0; done_count=$((done_count + 1)); any=true
            fi
        done

        if $QUIET_MODE && $any; then
            phase_progress extract $(( 10 + (done_count * 90) / n )) "Phase 1: $done_count/$n files"
        fi
        $any || sleep 0.1   # only wait if nothing finished (avoid a busy-spin)
    done
}

# Merge all successful part DBs (in file order) into the master DB.
# Sets $MERGE_RC (0 ok, otherwise the DuckDB exit code). Writes nothing to the
# master DB if no file succeeded (downstream P2-P6 then see an empty DB, just
# like the sequential case with no successful imports).
merge_part_dbs() {
    MERGE_RC=0
    local parts=() i
    for i in "${!XML_FILES[@]}"; do
        [ -f "$PARTDB_DIR/${i}.rc" ] && [ "$(cat "$PARTDB_DIR/${i}.rc")" = "0" ] \
            && [ -f "$PARTDB_DIR/part_${i}.duckdb" ] && parts+=("$PARTDB_DIR/part_${i}.duckdb")
    done
    [ ${#parts[@]} -eq 0 ] && return 0

    # Seed the master schema: if the master DB does not yet exist (force_rebuild
    # deleted it), copy the first part DB as the base (full schema + data of the
    # first file). Otherwise (incremental) the master DB stays the base.
    local start=0
    if [ ! -f "$DB_FILE" ]; then
        cp "${parts[0]}" "$DB_FILE" || { MERGE_RC=1; return 1; }
        start=1
    fi

    # Table list from a PART DB (not from the master DB!). The part DBs only run
    # P1 (extract) and carry exactly the mergeable tables. On an incremental run the
    # master DB additionally contains all P2–P6 objects (e.g. GetSubparameterMap,
    # MBS_SubnameMap) plus views (FolderHierarchy, v_check_*, v_*_stats) that are
    # absent from the part DBs — if they ended up here the merge would fail
    # ("Table does not exist" / "Can only delete from base table"). table_type='BASE
    # TABLE' additionally filters out views. parts[0] is representative; all part DBs
    # share the same P1 schema. SchemaInfo (version marker, one row) is omitted.
    local seed_db="${parts[0]}"
    local tables; tables=$("$DUCKDB_BIN" -readonly "$seed_db" -noheader -list -c \
        "SELECT table_name FROM information_schema.tables WHERE table_schema='main' AND table_type='BASE TABLE' AND table_name <> 'SchemaInfo' ORDER BY table_name;" 2>/dev/null)
    [ -z "$tables" ] && { MERGE_RC=0; return 0; }
    # Which tables carry a File_Name column? (Only for the DELETE pre-stage; a
    # "File_Name" reference to a table without that column is a bind error — so
    # decide per table up front.) Also from the part DB, so the DELETE pre-stage and
    # INSERT operate on the same set of tables.
    local fn_tables; fn_tables=$("$DUCKDB_BIN" -readonly "$seed_db" -noheader -list -c \
        "SELECT DISTINCT table_name FROM information_schema.columns WHERE table_schema='main' AND column_name='File_Name';" 2>/dev/null)

    # Schema-drift protection (incremental): create a NEWLY-introduced part table that is
    # still missing in the EXISTING master, with its PK from the part schema, before the
    # DELETE/INSERT loop (incl. ON CONFLICT DO NOTHING) references it.
    _turbo_seed_missing_tables "$seed_db" "$DB_FILE" "$PARTDB_DIR/merge.log" "$tables"
    [ "$MERGE_RC" -ne 0 ] && return $MERGE_RC

    # Generate merge SQL: per remaining part DB ATTACH (READ_ONLY) + per table
    # DELETE of the contained File_Names (idempotent) followed by INSERT BY NAME.
    local msql; msql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    local k=$start ai=0 p tbl
    while [ "$k" -lt "${#parts[@]}" ]; do
        p="${parts[$k]}"
        ai=$((ai + 1))
        echo "ATTACH '$p' AS p${ai} (READ_ONLY);" >> "$msql"
        while IFS= read -r tbl; do
            [ -z "$tbl" ] && continue
            # File_Name column present? Then delete the affected names up front
            # (makes re-import idempotent; a no-op on force_rebuild since disjoint).
            if printf '%s\n' "$fn_tables" | grep -qxF "$tbl"; then
                echo "DELETE FROM \"$tbl\" WHERE \"File_Name\" IN (SELECT DISTINCT \"File_Name\" FROM p${ai}.\"$tbl\");" >> "$msql"
            fi
            echo "INSERT INTO \"$tbl\" BY NAME SELECT * FROM p${ai}.\"$tbl\";" >> "$msql"
        done <<< "$tables"
        k=$((k + 1))
    done

    if [ -s "$msql" ]; then
        "$DUCKDB_BIN" "$DB_FILE" < "$msql" > "$PARTDB_DIR/merge.log" 2>&1 || MERGE_RC=$?
    fi
    rm -f "$msql"
    return $MERGE_RC
}

# Phase C, stage 2 — PARQUET variant (opt-in FM_TURBO_PARQUET, format eval).
# Instead of ATTACH+INSERT per part: parts (except seed) → Parquet per (table,part),
# then per table ONE wildcard INSERT via read_parquet('<tbl>/*.parquet'). No ATTACH.
# In isolation ~3.4× faster + −22% RAM, snapshot-byte-identical (CTAS/INSERT-from-parquet
# preserves the schema; verified). Seed = cp(parts[0]) (full schema incl. SchemaInfo +
# part0 data, exactly like merge_part_dbs).
# PRECONDITION: no File_Name collision across parts (prod: 57 XML = 57 distinct File_Name,
# verified) → additive union == merge_part_dbs result. Incremental (master exists) →
# safe fallback to merge_part_dbs (DELETE-last-wins, not covered parquet-side in the prototype).
# Returns via MERGE_RC (like merge_part_dbs).
_turbo_merge_parquet() {
    MERGE_RC=0
    local parts=() i
    for i in "${!XML_FILES[@]}"; do
        [ -f "$PARTDB_DIR/${i}.rc" ] && [ "$(cat "$PARTDB_DIR/${i}.rc")" = "0" ] \
            && [ -f "$PARTDB_DIR/part_${i}.duckdb" ] && parts+=("$PARTDB_DIR/part_${i}.duckdb")
    done
    [ ${#parts[@]} -eq 0 ] && return 0
    # Incremental (master exists) not covered parquet-side in the prototype → fallback.
    [ -f "$DB_FILE" ] && { echo "  [parquet] master exists (incremental) → fallback merge_part_dbs" >&2; merge_part_dbs; return $?; }

    # Seed: cp parts[0] (schema + SchemaInfo + part0 data) — identical to merge_part_dbs.
    cp "${parts[0]}" "$DB_FILE" || { MERGE_RC=1; return 1; }
    [ ${#parts[@]} -eq 1 ] && return 0

    local seed_db="${parts[0]}" tables
    tables=$("$DUCKDB_BIN" -readonly "$seed_db" -noheader -list -c \
        "SELECT table_name FROM information_schema.tables WHERE table_schema='main' AND table_type='BASE TABLE' AND table_name <> 'SchemaInfo' ORDER BY table_name;" 2>/dev/null)
    [ -z "$tables" ] && { MERGE_RC=0; return 0; }

    local pqdir="$PARTDB_DIR/pq"; mkdir -p "$pqdir"
    # Export parts[1..] → Parquet per (table, part) in ONE duckdb run (ATTACH + COPY).
    local esql k tbl; esql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    for ((k = 1; k < ${#parts[@]}; k++)); do echo "ATTACH '${parts[$k]}' AS p${k} (READ_ONLY);" >> "$esql"; done
    while IFS= read -r tbl; do
        [ -z "$tbl" ] && continue
        mkdir -p "$pqdir/$tbl"
        for ((k = 1; k < ${#parts[@]}; k++)); do
            echo "COPY (SELECT * FROM p${k}.\"$tbl\") TO '$pqdir/$tbl/${k}.parquet' (FORMAT parquet);" >> "$esql"
        done
    done <<< "$tables"
    "$DUCKDB_BIN" ":memory:" < "$esql" > "$PARTDB_DIR/parquet_merge.log" 2>&1 || MERGE_RC=$?
    rm -f "$esql"
    [ "$MERGE_RC" -ne 0 ] && return $MERGE_RC

    # Merge: per table ONE wildcard INSERT into the seeded master (no ATTACH/DELETE).
    # a1: guard PK/UNIQUE tables against cross-chunk/clone duplicates (see _pk_constrained_tables).
    local pk_tables; pk_tables=$(_pk_constrained_tables "$seed_db")
    local msql; msql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    while IFS= read -r tbl; do
        [ -z "$tbl" ] && continue
        echo "INSERT INTO \"$tbl\" BY NAME SELECT * FROM read_parquet('$pqdir/$tbl/*.parquet')$(_oc_clause "$tbl" "$pk_tables");" >> "$msql"
    done <<< "$tables"
    [ -s "$msql" ] && { "$DUCKDB_BIN" "$DB_FILE" < "$msql" >> "$PARTDB_DIR/parquet_merge.log" 2>&1 || MERGE_RC=$?; }
    rm -f "$msql"
    return $MERGE_RC
}

# Catalog→tables ownership (empirically verified): each P1 table is fed by exactly
# ONE catalog. Non-main catalogs own their specific tables (stable from the
# extract.sql branch mapping); main owns the rest (incl. per-doc
# FilesCatalog/XMLMetadata). Unknown non-main catalog → '?' (the caller aborts safely).
_turbo_catalog_owned() {
    case "$1" in
        main)            echo "__MAIN__" ;;
        StepsForScripts) echo "StepsForScripts" ;;
        DDR_INFO)        echo "DDR_Calculations DDR_ChunkListContexts DDR_ScriptSteps" ;;
        # DDR_INFO nest children. The Calculation half feeds ONLY DDR_Calculations
        # + DDR_ChunkListContexts (the Script XPath finds nothing → 0 rows), the
        # Script half ONLY DDR_ScriptSteps. They are mutually exclusive with
        # DDR_INFO (nest on XOR off) → no OWNER conflict. WITHOUT these lines
        # catmerge would fall back to the part path.
        Calculation)     echo "DDR_Calculations DDR_ChunkListContexts" ;;
        Script)          echo "DDR_ScriptSteps" ;;
        LayoutCatalog)   echo "Layouts LayoutObjects LayoutParts" ;;
        *)               echo "?" ;;
    esac
}

# Multi-fed tables: fed by MORE than one catalog → the single-owner model of the
# catmerge ownership does not apply. ScriptTriggers: file-level
# (//Metadata, main chunk) + layout-/object-level (//LayoutCatalog, LayoutCatalog chunk).
# As long as LayoutCatalog was NOT separated (old default SUBCHUNK=0), everything sat
# in the main chunk → single-fed. The windowing default separates LayoutCatalog → the
# layout/object triggers move into its chunk and were lost under single-owner catmerge.
# Fix: copy multi-fed tables from EVERY chunk (export below); the sources are
# record-disjoint (different Owner_Type/Owner_UUID, collision-free PK) → union = complete.
# DuplicateAbsorptions (Dup-Zensus): fed by main (typed catalog censuses) AND the two
# heavy chunks (StepsForScripts, LayoutCatalog→LayoutObjects census). Record-disjoint
# via PK (Catalog, File_Name, Chunk_Seq) — the Catalog column separates the feeders,
# Chunk_Seq (= seq_offset) separates sub-chunks of the same heavy branch.
# DuplicateAbsorptionDetails (1.17.0): fed by main (ScriptCatalog details) AND the two
# heavy chunks (StepsForScripts, LayoutCatalog→Layouts/LayoutObjects details). Same
# provenance model as DuplicateAbsorptions (Catalog column + Chunk_Seq in the PK) —
# without this registration the single-owner catmerge silently dropped every detail
# row written outside the main chunk.
_turbo_table_multifed() {
    case "$1" in
        ScriptTriggers)              return 0 ;;
        DuplicateAbsorptions)        return 0 ;;
        DuplicateAbsorptionDetails)  return 0 ;;
        *)                           return 1 ;;
    esac
}

# May catalog $1 NOT be skipped by the catalog gate because it feeds a multi-fed
# table whose provenance the merge CANNOT scope? Since the provenance-scoped merge
# DELETE (see _turbo_multifed_delete_types) the ONLY multi-fed table (ScriptTriggers)
# is separable via `Owner_Type` (File↔main, Layout/LayoutObject↔LayoutCatalog) →
# LayoutCatalog is now skippable (its triggers survive the main reparse). 'main' is
# never skipped anyway (the gate filters `catalog <> 'main'`). So there is currently NO
# non-scopable feeder anymore — the function remains as a hook for future multi-fed
# tables WITHOUT a separating provenance column (add them here then).
_turbo_catalog_feeds_multifed() {
    case "$1" in
        *) return 1 ;;
    esac
}

# For a multi-fed table $1: the provenance values of the feeders REPARSED in THIS run
# (from SEENCAT). Only these provenance classes are deleted in the master — the classes
# of skipped feeders stay untouched (this enables the LayoutCatalog skip). Empty
# → no known provenance map → the caller falls back to a File-scoped DELETE (conservative).
# Assumption: ScriptTriggers.Owner_Type ∈ {File(main), Layout/LayoutObject(LayoutCatalog)}
# (prod verified). New provenance/feeder → add it here.
# DuplicateAbsorptions uses the Catalog column as provenance (see _turbo_multifed_prov_col):
# main feeds the typed catalog censuses, the heavy chunks feed their own catalog rows.
_turbo_multifed_delete_types() {
    local t="$1" seen=" $2 " types=""   # $2 = space-delimited set of catalogs reparsed this run
    case "$t" in
        ScriptTriggers)
            case "$seen" in *" main "*)          types="$types${types:+,}'File'" ;; esac
            case "$seen" in *" LayoutCatalog "*) types="$types${types:+,}'Layout','LayoutObject'" ;; esac
            ;;
        DuplicateAbsorptions)
            case "$seen" in *" main "*)          types="$types${types:+,}'ExternalDataSourceCatalog','BaseTableCatalog','TableOccurrenceCatalog','RelationshipCatalog','FieldsForTables','ValueListCatalog','OptionsForValueLists','CustomFunctionsCatalog','AccountsCatalog'" ;; esac
            case "$seen" in *" StepsForScripts "*) types="$types${types:+,}'StepsForScripts'" ;; esac
            case "$seen" in *" LayoutCatalog "*)  types="$types${types:+,}'LayoutObjects'" ;; esac
            ;;
        DuplicateAbsorptionDetails)
            case "$seen" in *" main "*)            types="$types${types:+,}'ScriptCatalog'" ;; esac
            case "$seen" in *" StepsForScripts "*) types="$types${types:+,}'StepsForScripts'" ;; esac
            case "$seen" in *" LayoutCatalog "*)   types="$types${types:+,}'Layouts','LayoutObjects'" ;; esac
            ;;
    esac
    printf '%s' "$types"
}

# Provenance column of a multi-fed table (used by the provenance-scoped DELETE).
_turbo_multifed_prov_col() {
    case "$1" in
        DuplicateAbsorptions)       printf 'Catalog' ;;
        DuplicateAbsorptionDetails) printf 'Catalog' ;;
        *)                          printf 'Owner_Type' ;;
    esac
}

# Are ALL chunks of file $1 valid (rc=0 + DB present)? (for the per-file rc sidecar.)
# skipped_unchanged chunks (catalog gate) are deliberately NOT dispatched →
# they do not count as missing (their master rows are unchanged and valid).
_turbo_file_chunks_ok() {
    local idx="$1" fn cid
    fn="$(basename "${XML_FILES[$idx]}")"; fn="${fn%.xml}"
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        { [ "$(cat "$STREAMING_DIR/chunk_${cid}.rc" 2>/dev/null)" = "0" ] && [ -f "$STREAMING_DIR/chunk_${cid}.duckdb" ]; } || return 1
    done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT chunk_id FROM chunkmap WHERE file_name='${fn//\'/\'\'}' AND status<>'skipped_unchanged';")
    return 0
}

# Copy the stderr of file $1's FAILED chunks into the file-level .out sidecar. The
# catalog-granular merge reads chunks directly (no part DB), so a chunk parse error
# otherwise never reaches the file .out — the driver's classify_error then only sees
# the pre/split report and defaults to sql_error, masking the real cause behind the
# downstream NOT-NULL cascade. Surfacing the chunk stderr lets classify_error name
# the true category (e.g. invalid_xml, pointing at the pre-processor). Mirrors what
# the part-DB path (_turbo_build_part) already does with its bad-chunk .out.
_turbo_append_chunk_errs() {
    local idx="$1" fn cid
    fn="$(basename "${XML_FILES[$idx]}")"; fn="${fn%.xml}"
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        [ "$(cat "$STREAMING_DIR/chunk_${cid}.rc" 2>/dev/null)" = "0" ] && continue
        [ -s "$STREAMING_DIR/chunk_${cid}.out" ] && cat "$STREAMING_DIR/chunk_${cid}.out" >> "$PARTDB_DIR/${idx}.out"
    done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT chunk_id FROM chunkmap WHERE file_name='${fn//\'/\'\'}' AND status<>'skipped_unchanged';")
}

# Did any chunk of file $1 die from an OOM signal? A memory kill leaves the chunk with
# status='oom' (set from rc 137/143 during dispatch) and, because SIGKILL leaves no
# stderr, an empty .out — so the file-level classifier cannot see the cause in the
# text. Surface it via the per-file rc instead (137), so classify_error reports oom
# rather than defaulting to a generic sql_error.
_turbo_file_has_oom() {
    local idx="$1" fn n
    fn="$(basename "${XML_FILES[$idx]}")"; fn="${fn%.xml}"
    n=$("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c \
        "SELECT count(*) FROM chunkmap WHERE file_name='${fn//\'/\'\'}' AND status IN ('oom','oom_error');" 2>/dev/null)
    [ "${n:-0}" -gt 0 ]
}

# Phase C — CATALOG-GRANULAR (DEFAULT in turbo; opt-out FM_TURBO_NO_CATMERGE). Collapses C1+C2:
# chunks → master DIRECTLY (no part DBs), per catalog atomic DELETE-by-File + INSERT.
# Model: each (file×catalog) slice is record-disjoint & self-contained → wholesale
# replacement without a row-by-row reconciliation; matches the manifest hash
# (incremental) and per-catalog exports. Per-doc becomes a normal map rule (owned by
# main), no longer a special case. DELETE-by-File is a no-op on force-rebuild but makes
# the path collision-safe + incremental-capable (unlike the pure union in _turbo_merge_parquet).
# VARIANT A (export from chunk DBs); worker→parquet-direct (variant B, saves the C1 copy) later.
# Linear lookup over the catmerge OWNER_K/OWNER_V parallel arrays (dynamic scope from
# _turbo_merge_catalog — bash-3.2-safe stand-in for an associative array). Sets
# _owner_result to the catalog owning table $1 (empty if unmapped). Avoids command
# substitution so it can be called in the hot export loop without a per-call subshell.
_catmerge_owner_of() {
    local _j; _owner_result=""
    for _j in "${!OWNER_K[@]}"; do
        if [ "${OWNER_K[$_j]}" = "$1" ]; then _owner_result="${OWNER_V[$_j]}"; return 0; fi
    done
    return 1
}

_turbo_merge_catalog() {
    MERGE_RC=0
    local -a CID CCAT
    local cid cat
    while IFS=$'\t' read -r cid cat; do
        [ -z "$cid" ] && continue
        [ "$(cat "$STREAMING_DIR/chunk_${cid}.rc" 2>/dev/null)" = "0" ] || continue
        [ -f "$STREAMING_DIR/chunk_${cid}.duckdb" ] || continue
        CID+=("$cid"); CCAT+=("$cat")
    done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT chunk_id||chr(9)||catalog FROM chunkmap ORDER BY catalog, chunk_id;")
    [ ${#CID[@]} -eq 0 ] && return 0

    # P1 tables + File_Name tables from ONE chunk (NOT from the master — on incremental
    # the master additionally carries P2–P6 tables/views that must not be merged here).
    local seed_chunk="$STREAMING_DIR/chunk_${CID[0]}.duckdb" t
    local tables; tables=$("$DUCKDB_BIN" -readonly "$seed_chunk" -noheader -list -c \
        "SELECT table_name FROM information_schema.tables WHERE table_schema='main' AND table_type='BASE TABLE' AND table_name<>'SchemaInfo' ORDER BY table_name;")
    [ -z "$tables" ] && { MERGE_RC=0; return 0; }
    local fn_tables; fn_tables=$("$DUCKDB_BIN" -readonly "$seed_chunk" -noheader -list -c \
        "SELECT DISTINCT table_name FROM information_schema.columns WHERE table_schema='main' AND column_name='File_Name';")

    # Ownership: known non-main catalogs → their tables; main → the rest. (The
    # orchestrator pre-flight guarantees known catalogs; defensive abort if still unknown.)
    # bash-3.2-safe: OWNER as parallel indexed arrays (OWNER_K table → OWNER_V catalog)
    # with linear lookup (_catmerge_owner_of); SEENCAT as a space-delimited set of the
    # catalogs reparsed this run (catalog names are identifiers → no-space-safe).
    local -a OWNER_K OWNER_V; local _seencat="" _owner_result i owned tk cat
    for i in "${!CID[@]}"; do
        case " $_seencat " in *" ${CCAT[$i]} "*) ;; *) _seencat="$_seencat${_seencat:+ }${CCAT[$i]}" ;; esac
    done
    for cat in $_seencat; do
        owned="$(_turbo_catalog_owned "$cat")"
        [ "$owned" = "?" ] && { echo "  [catmerge] unknown catalog '$cat' → abort" >&2; MERGE_RC=2; return 2; }
        [ "$owned" = "__MAIN__" ] && continue
        for tk in $owned; do OWNER_K+=("$tk"); OWNER_V+=("$cat"); done
    done
    while IFS= read -r t; do [ -n "$t" ] && { _catmerge_owner_of "$t" || { OWNER_K+=("$t"); OWNER_V+=("main"); }; }; done <<< "$tables"

    # Seed ONLY in a full build (master missing): an empty, schema'd master from a chunk.
    # On incremental the existing master (with P2–P6) stays the base — below, DELETE-by-File
    # replaces only the rows of the (changed) files whose chunks are present.
    if [ ! -f "$DB_FILE" ]; then
        cp "$seed_chunk" "$DB_FILE" || { MERGE_RC=1; return 1; }
        local del=""
        while IFS= read -r t; do [ -n "$t" ] && del="$del DELETE FROM \"$t\";"; done <<< "$tables"
        "$DUCKDB_BIN" "$DB_FILE" -c "$del" >/dev/null 2>&1
    fi

    # Schema-drift protection (incremental): if a chunk table is missing in the EXISTING
    # master — e.g. a NEWLY-introduced catalog/monitoring table whose schema bump has not yet
    # triggered a full rebuild — we create it WITH its PK from the chunk schema, BEFORE the
    # DELETE/INSERT passes below reference it (incl. ON CONFLICT DO NOTHING).
    _turbo_seed_missing_tables "$seed_chunk" "$DB_FILE" "$PARTDB_DIR/catmerge.log" "$tables"
    [ "$MERGE_RC" -ne 0 ] && return $MERGE_RC

    # Export (low-RAM): ONE duckdb run, per chunk ATTACH→COPY-owned→DETACH (max. 1 DB attached
    # → no 57-way ATTACH peak). Per-doc falls out automatically (FilesCatalog/XMLMetadata
    # belong to main → only main chunks copy them).
    local pqdir="$PARTDB_DIR/pq"; mkdir -p "$pqdir"
    while IFS= read -r t; do [ -n "$t" ] && mkdir -p "$pqdir/$t"; done <<< "$tables"
    local esql; esql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    for i in "${!CID[@]}"; do
        echo "ATTACH '$STREAMING_DIR/chunk_${CID[$i]}.duckdb' AS k (READ_ONLY);" >> "$esql"
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            # Owner chunk OR multi-fed (from every chunk; record-disjoint → union correct).
            _catmerge_owner_of "$t"
            { [ "$_owner_result" = "${CCAT[$i]}" ] || _turbo_table_multifed "$t"; } || continue
            echo "COPY (SELECT * FROM k.\"$t\") TO '$pqdir/$t/${CID[$i]}.parquet' (FORMAT parquet);" >> "$esql"
        done <<< "$tables"
        echo "DETACH k;" >> "$esql"
    done
    [ -s "$esql" ] && { "$DUCKDB_BIN" ":memory:" < "$esql" >> "$PARTDB_DIR/catmerge.log" 2>&1 || MERGE_RC=$?; }
    rm -f "$esql"
    [ "$MERGE_RC" -ne 0 ] && return $MERGE_RC

    # UUID-healing gate (H2): MANDATORY duplicate count over the heal tables'
    # parquet unions. Fail-hard by design — the best-effort a2 contract would
    # silently skip healing on a failed count; here a failed/garbled count aborts
    # the merge (the part-path fallback then applies, which only censuses).
    # 0 duplicates → the plain a1 INSERT path below runs unchanged (zero overhead).
    local heal_dups=0
    if [ "${FM_UUID_HEAL:-1}" != "0" ]; then
        local _hq="" _ht
        for _ht in StepsForScripts LayoutObjects Layouts; do
            ls "$pqdir/$_ht"/*.parquet >/dev/null 2>&1 || continue
            _turbo_heal_ident "$_ht" || continue
            [ -n "$_hq" ] && _hq="$_hq + "
            _hq="${_hq}(SELECT COUNT(*) - COUNT(DISTINCT ($_hi_uuid, File_Name)) FROM read_parquet('$pqdir/$_ht/*.parquet'))"
        done
        if [ -n "$_hq" ]; then
            heal_dups=$("$DUCKDB_BIN" ":memory:" -noheader -list -c "SELECT $_hq;" 2>>"$PARTDB_DIR/catmerge.log")
            case "$heal_dups" in ''|*[!0-9]*)
                emit_warn "katmerge: mandatory heal dup-count failed — aborting catalog merge (heal gate is fail-hard)."
                MERGE_RC=1; return 1 ;;
            esac
        fi
    fi

    # Merge: per table with Parquet files: DELETE-by-File (no-op on an empty master, but
    # collision-/incremental-safe) + wildcard INSERT. Atomic per (file×catalog) via owner partition.
    # a1: tables that may carry `ON CONFLICT DO NOTHING` (PK/UNIQUE present). Computed once.
    local pk_tables; pk_tables=$(_pk_constrained_tables "$seed_chunk")
    local msql dtypes; msql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        ls "$pqdir/$t"/*.parquet >/dev/null 2>&1 || continue
        if _turbo_table_multifed "$t"; then
            # Provenance-scoped DELETE: delete only the Owner_Type classes of the feeders
            # reparsed in THIS run, across ALL processed files (the FilesCatalog parquet
            # carries the internal File_Names; main is always reparsed → contains all). This
            # keeps triggers of skipped feeders (e.g. LayoutCatalog) intact, while a trigger
            # removed in a reparsed feeder (drop-to-0) is still deleted.
            # Without a provenance map OR without the FilesCatalog parquet → conservatively File-scoped.
            dtypes="$(_turbo_multifed_delete_types "$t" "$_seencat")"
            if [ -n "$dtypes" ] && ls "$pqdir/FilesCatalog"/*.parquet >/dev/null 2>&1; then
                echo "DELETE FROM \"$t\" WHERE \"File_Name\" IN (SELECT \"File_Name\" FROM read_parquet('$pqdir/FilesCatalog/*.parquet')) AND \"$(_turbo_multifed_prov_col "$t")\" IN ($dtypes);" >> "$msql"
            else
                echo "DELETE FROM \"$t\" WHERE \"File_Name\" IN (SELECT DISTINCT \"File_Name\" FROM read_parquet('$pqdir/$t/*.parquet'));" >> "$msql"
            fi
        elif printf '%s\n' "$fn_tables" | grep -qxF "$t"; then
            echo "DELETE FROM \"$t\" WHERE \"File_Name\" IN (SELECT DISTINCT \"File_Name\" FROM read_parquet('$pqdir/$t/*.parquet'));" >> "$msql"
        fi
        # H2: heal tables get the healing INSERT variant when the gate saw
        # duplicates — global min-identity survivorship instead of glob-order
        # last-write-wins; identical identities still collapse via the a1 guard.
        if [ "${heal_dups:-0}" -gt 0 ] && _turbo_heal_ident "$t"; then
            _turbo_emit_heal_merge "$t" "$pqdir" >> "$msql"
        else
            echo "INSERT INTO \"$t\" BY NAME SELECT * FROM read_parquet('$pqdir/$t/*.parquet')$(_oc_clause "$t" "$pk_tables");" >> "$msql"
        fi
    done <<< "$tables"
    # H2: census completion for cross-chunk pairs (after all table merges — the
    # statements only touch DuplicateAbsorptionDetails + the parquet union).
    if [ "${heal_dups:-0}" -gt 0 ]; then
        local _hc
        for _hc in StepsForScripts LayoutObjects Layouts; do
            ls "$pqdir/$_hc"/*.parquet >/dev/null 2>&1 || continue
            _turbo_emit_heal_census "$_hc" "$pqdir" >> "$msql"
        done
    fi
    [ -s "$msql" ] && { "$DUCKDB_BIN" "$DB_FILE" < "$msql" >> "$PARTDB_DIR/catmerge.log" 2>&1 || MERGE_RC=$?; }
    rm -f "$msql"
    # a2: surface any PK duplicates the a1 guard absorbed (best-effort, only on success).
    [ "$MERGE_RC" -eq 0 ] && _turbo_catmerge_dup_report "$seed_chunk" "$pqdir" "$tables"
    return $MERGE_RC
}

# Pre-flight: is the catalog-granular merge applicable? Two conditions:
#  (1) all catalogs in the chunkmap have an owner map (empty chunkmap = yes);
#  (2) NO internal File_Name collision — if multiple XML exports share the same
#      internal FileMaker File_Name (e.g. with + without DDR), the catmerge bulk
#      `INSERT BY NAME` over ALL chunks at once would violate the PK/UNIQUE constraints
#      (duplicate key "<UUID>, <File>"); the part path (merge_part_dbs) by contrast
#      resolves this correctly via sequential DELETE-by-File → "last wins" (long
#      documented as a catmerge precondition, but it was unchecked → test-data-specific crash).
# Either not met → return 1 → part-path fallback (catalog-agnostic, collision-safe).
_turbo_catmerge_ok() {
    local c
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        [ "$(_turbo_catalog_owned "$c")" = "?" ] && return 1
    done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT DISTINCT catalog FROM chunkmap;" 2>/dev/null)

    # (2) Collect the internal File_Name per main chunk (= per physical XML file) and
    # check for duplicates. ONE duckdb run (sequential ATTACH→SELECT→DETACH, max. 1 DB
    # attached → no RAM peak). Prod (57 distinct File_Name) → no collision → catmerge.
    local esql; esql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")" || return 0
    local cid
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        [ -f "$STREAMING_DIR/chunk_${cid}.duckdb" ] || continue
        printf "ATTACH '%s' AS k (READ_ONLY); SELECT File_Name FROM k.FilesCatalog LIMIT 1; DETACH k;\n" \
            "$STREAMING_DIR/chunk_${cid}.duckdb" >> "$esql"
    done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT chunk_id FROM chunkmap WHERE catalog='main' ORDER BY chunk_id;" 2>/dev/null)
    local dup=0
    if [ -s "$esql" ]; then
        dup=$("$DUCKDB_BIN" ":memory:" -noheader -list < "$esql" 2>/dev/null \
              | grep -v '^$' | sort | uniq -d | head -1 | wc -l | tr -d ' ')
    fi
    rm -f "$esql"
    [ "${dup:-0}" -ge 1 ] && return 1
    return 0
}

# ============================================================================
# Turbo mode — phases S/D/C
# Generalizes run_p1_parallel/merge_part_dbs from file to CHUNK granularity:
#   Phase S (Split & Plan)  — preprocess+split all files sequentially, populate the
#                             chunkmap; chunks persist under db/streaming/chunks/.
#   Phase D (Dispatch)      — worker pool (W=JOBS) pulls open chunks from the chunkmap
#                             (heaviest-first) → one chunk_<id>.duckdb per chunk.
#   Phase C (Consolidate)   — merge all chunk DBs into the master (DELETE-by-File for
#                             idempotency + INSERT … BY NAME; separated branches are
#                             record-disjoint, hence additive — verified).
# Produces the same per-file sidecars as the file-parallel path ($PARTDB_DIR/<i>.{out,
# rc,dur}) so the telemetry loop keeps running unchanged (P1_PREPROCESSED=true).
# ============================================================================

# Phase S for ONE file: preprocess + (streamify) + root check + split (with a chunkmap
# sidecar) → persistent chunks under $STREAMING_DIR/chunks/<idx>. Loads the chunkmap.
# Writes the pre-/split report to $PARTDB_DIR/<idx>.out (for FILE_ENC grep + errors).
# Returns: 0 ok | 1 not-found | 2 enc | 4 skip (legacy/unknown) | 5 preprocess/streamify | 3 split/load.
_turbo_split_one_file() {
    local idx="$1" FILENAME="$2"
    local out="$PARTDB_DIR/${idx}.out"
    : > "$out"
    local src="$XML_DIR/$FILENAME"
    [ -f "$src" ] || { echo "ERROR: File not found: $FILENAME" >>"$out"; return 1; }

    local cdir="$STREAMING_DIR/chunks/$idx"
    mkdir -p "$cdir"
    local BASENAME="${FILENAME%.xml}"
    # FM_T5_TRACE (opt-in, default-off → byte-identical): per-step markers, to attribute
    # the iconv share vs. the fused-awk share per file after the pass fusion.
    local _t5_on=""; [ -n "${FM_T5_TRACE:-}" ] && _t5_on=1

    # ---- (P2.1) Encoding → UTF-8 (the only remaining non-awk full pass) ----
    # iconv keeps the BOM; the fused awk strips it (NR==1). No more _clean.xml
    # round-trip — clean/rename/split/counts is done by the single awk pass below.
    local UTF8="$cdir/${BASENAME}.utf8.xml"
    # Save the full UTF-8 copy : if the source is already UTF-8, it is
    # ONLY read downstream (root check, DDR recmap scan, fused awk < "$UTF8") —
    # the earlier cp copy duplicated GB-sized files purely as awk fodder. Instead
    # point directly at $src; _UTF8_IS_SRC guards the rm cleanups (the original
    # must never be deleted). The iconv branch (UTF-16) stays unchanged.
    local _UTF8_IS_SRC=false
    local PRE_ENCODING; PRE_ENCODING=$(detect_encoding "$src")
    [ -n "$_t5_on" ] && echo "@T5 ${idx} iconv_start $(now_epoch)" >>"$out"
    case "$PRE_ENCODING" in
        utf-16le) iconv -f UTF-16LE -t UTF-8 "$src" > "$UTF8" 2>>"$out" || { echo "  ERROR: UTF-8 conversion failed" >>"$out"; rm -f "$UTF8"; return 2; } ;;
        utf-16be) iconv -f UTF-16BE -t UTF-8 "$src" > "$UTF8" 2>>"$out" || { echo "  ERROR: UTF-8 conversion failed" >>"$out"; rm -f "$UTF8"; return 2; } ;;
        *)        UTF8="$src"; _UTF8_IS_SRC=true ;;
    esac
    [ -n "$_t5_on" ] && echo "@T5 ${idx} iconv_end $(now_epoch)" >>"$out"

    # Root detection on the UTF-8 stream (grep finds <FMSaveAsXML even behind the BOM).
    local ROOT_ELEMENT
    ROOT_ELEMENT=$(head -c 4096 "$UTF8" | grep -oE '<(FMSaveAsXML|FMDynamicTemplate)[ >]' | head -1 | sed 's/[< >]//g')
    if [ "$ROOT_ELEMENT" = "FMDynamicTemplate" ]; then
        echo "  WARNING: Skipped — legacy SaXML v2.0.0.0 format (FMDynamicTemplate)" >>"$out"
        echo "  This format (FileMaker 18.x) is not supported. Minimum: SaXML v2.1.0.0 (FileMaker 19+)." >>"$out"
        $_UTF8_IS_SRC || rm -f "$UTF8"; return 4
    fi
    [ -z "$ROOT_ELEMENT" ] && { echo "  WARNING: Skipped — could not detect XML root element (expected FMSaveAsXML)" >>"$out"; $_UTF8_IS_SRC || rm -f "$UTF8"; return 4; }

    # recmap (streamify-aware, identical to the process_single_file logic): in
    # --streamify mode map to the renamed record anchors, otherwise the original SUBCHUNK_RECMAP.
    local EFFECTIVE_RECMAP="$SUBCHUNK_RECMAP"
    if $STREAMIFY_MODE && [ -n "$STREAMIFY_RULES" ] && [ "${SUBCHUNK:-0}" -gt 0 ]; then
        local _erm="" _e _br _rec _new
        for _e in $SUBCHUNK_RECMAP; do
            _br="${_e%%:*}"; _rec="${_e##*:}"
            _new=$(printf '%s' "$STREAMIFY_RULES" | tr ',' '\n' \
                   | awk -F: -v b="$_br" -v r="$_rec" '$1==b && $2==r {print $3; exit}')
            [ -n "$_new" ] && _rec="$_new"
            _erm="$_erm${_erm:+ }$_br:$_rec"
        done
        EFFECTIVE_RECMAP="$_erm"
    fi
    # DDR-2-level sub-chunk entries (Calculation:*:M Script:*:M): per-file M (capped), the
    # `*` anchor has no streamify rename, so it is appended AFTER the rename pass verbatim.
    local _ddr_rm; _ddr_rm=$(_ddr_recmap_for_file "$UTF8")
    if [ -n "$_ddr_rm" ]; then
        EFFECTIVE_RECMAP="$EFFECTIVE_RECMAP $_ddr_rm"
        echo "  DDR-Subchunk: $FILENAME → ${_ddr_rm%% *}" >>"$out"
    fi

    # ---- (P2.1/P2.2) Fused pass: clean + counts + (streamify-rename) + split ----
    # ONE awk (mawk via AWK_BIN, LC_ALL=C for byte transparency) replaces the earlier
    # ~7 passes (tr-clean, 4× wc/tr-counts, streamify-awk+mv, splitter-awk). Empty rules
    # ⇒ no rename (DOM mode). The counts sidecar provides the report counters.
    local _rules=""; $STREAMIFY_MODE && _rules="$STREAMIFY_RULES"
    local NCHUNKS
    [ -n "$_t5_on" ] && echo "@T5 ${idx} fuse_start $(now_epoch)" >>"$out"
    # ws_sentinel=1/0 gates the CR→0x7F conversion in the byte clean (clean_line) — mirror of
    # the bash preprocess_file gating (WS_SENTINEL_ON). 0 = webbed preserves whitespace natively →
    # CR is kept (parser normalizes to LF). Default 1 (sentinel ON, conservative).
    local _ws_sentinel=1; [ "${WS_SENTINEL_ON:-true}" = "false" ] && _ws_sentinel=0
    NCHUNKS=$(LC_ALL=C "$AWK_BIN" -v outdir="$cdir" -v subchunk="$SUBCHUNK" -v recmap="$EFFECTIVE_RECMAP" \
                  -v nest="$NEST_MAP" -v ws_sentinel="$_ws_sentinel" \
                  -v chunkmap="$cdir/chunkmap.tsv" -v counts="$cdir/counts.tsv" -v rules="$_rules" \
                  -f "$KATANA_COMMON_AWK" -f "$TURBO_FUSE_AWK" < "$UTF8" 2>>"$out")
    [ -n "$_t5_on" ] && echo "@T5 ${idx} fuse_end $(now_epoch)" >>"$out"
    if [ -z "$NCHUNKS" ] || [ ! -f "$cdir/chunk_000_main.xml" ]; then
        echo "  ERROR: XML split failed" >>"$out"; $_UTF8_IS_SRC || rm -f "$UTF8"; return 3
    fi
    $_UTF8_IS_SRC || rm -f "$UTF8"   # release the iconv intermediate file (chunks are written)

    # Report counters from the counts sidecar (in_size, out_size, pre_cr, pre_del, stripped)
    local PRE_CR_COUNT=0 PRE_DEL_GUARD_COUNT=0 PRE_STRIPPED=0
    if [ -f "$cdir/counts.tsv" ]; then
        IFS=$'\t' read -r _ _ PRE_CR_COUNT PRE_DEL_GUARD_COUNT PRE_STRIPPED < "$cdir/counts.tsv"
    fi
    echo "  Preprocessed (enc=$PRE_ENCODING): replaced_cr=$PRE_CR_COUNT del_guard=$PRE_DEL_GUARD_COUNT stripped_invalid=$PRE_STRIPPED" >>"$out"
    $STREAMIFY_MODE && echo "  Streamify renaming applied (rules: $STREAMIFY_RULES)" >>"$out"
    echo "  Phase S: $NCHUNKS chunk(s) planned" >>"$out"

    # est_bytes per chunk (UTF-8 size) for heaviest-first dispatch (LPT).
    # content_hash per chunk (sha256 of the PREPROCESSED chunk bytes):
    # the basis of the catalog-granular manifest comparison. Same loop as sizes, so no
    # extra pass. Note: on the --streamify path the bytes are already renamed → the hash
    # is policy-stable only as long as the policy stays constant (holds between seed and
    # incremental run). In the DOM default no renaming → policy-independent.
    local sizes="$cdir/sizes.tsv"; : > "$sizes"
    local hashes="$cdir/hashes.tsv"; : > "$hashes"
    local cf
    for cf in "$cdir"/chunk_*.xml; do
        printf '%s\t%s\n' "$cf" "$(stat -c%s "$cf" 2>/dev/null || stat -f%z "$cf" 2>/dev/null || echo 0)" >> "$sizes"
        printf '%s\t%s\n' "$cf" "$(_turbo_sha256 "$cf")" >> "$hashes"
    done
    # (P2.3) NO chunkmap INSERT here anymore — that is single-writer/serialization-
    # bound (global chunk_id) and happens AFTER the parallel split in the main process
    # via _turbo_load_chunkmap_one (strict file order). The worker only writes the
    # per-file sidecars chunkmap.tsv + sizes.tsv (above).
    return 0
}

# (P2.3) Serial chunkmap load of ONE file in the main process (AFTER the parallel
# split pool). MUST be called in strict file order so the global chunk_id
# (MAX+ROW_NUMBER) is assigned deterministically as on the serial path — that is the
# identity gate. Pure metadata (tiny), no XML volume.
# Returns: 0 ok | 3 load error.
_turbo_load_chunkmap_one() {
    local idx="$1" FILENAME="$2"
    local out="$PARTDB_DIR/${idx}.out"
    local cdir="$STREAMING_DIR/chunks/$idx"
    local BASENAME="${FILENAME%.xml}"
    local _fn="${BASENAME//\'/\'\'}"
    local _pol; _pol=$($STREAMIFY_MODE && echo sax || echo dom)
    if ! "$DUCKDB_BIN" "$CHUNKMAP_DB" -c "
        INSERT INTO chunkmap
        SELECT
            (SELECT COALESCE(MAX(chunk_id),0) FROM chunkmap) + ROW_NUMBER() OVER () AS chunk_id,
            '$_fn', catalog, '$_fn' || '::' || catalog, split_number,
            '$cdir' || '/' || chunk_file, record_count,
            CAST(split_number AS BIGINT) * CAST(sub_m AS BIGINT),
            NULL, '$_pol', NULL, 'pending', 1
        FROM read_csv('$cdir/chunkmap.tsv', delim='\t', header=false,
             columns={'catalog':'VARCHAR','split_number':'INTEGER','record_count':'INTEGER','sub_m':'INTEGER','chunk_file':'VARCHAR'});
        UPDATE chunkmap SET est_bytes = s.b
        FROM (SELECT p, b FROM read_csv('$cdir/sizes.tsv', delim='\t', header=false, columns={'p':'VARCHAR','b':'BIGINT'})) s
        WHERE chunkmap.chunk_path = s.p AND chunkmap.est_bytes IS NULL;
        UPDATE chunkmap SET content_hash = h.h
        FROM (SELECT p, h FROM read_csv('$cdir/hashes.tsv', delim='\t', header=false, columns={'p':'VARCHAR','h':'VARCHAR'})) h
        WHERE chunkmap.chunk_path = h.p AND chunkmap.content_hash IS NULL;
        " >>"$out" 2>&1; then
        echo "  ERROR: Chunk-map load failed" >>"$out"; return 3
    fi
    return 0
}

# (P2.3) Phase-S worker (slot pool, sentinel pattern like _p1_worker): splits ONE
# file and persists rc/dur as sidecars (arrays can't be filled from subshells).
# Writes NO chunkmap (serial load afterwards). Last action = .done sentinel.
_turbo_split_worker() {
    local idx="$1"
    local fname; fname=$(basename "${XML_FILES[$idx]}")
    local t0 t1 rc
    t0=$(now_epoch)
    _turbo_split_one_file "$idx" "$fname"; rc=$?
    t1=$(now_epoch)
    echo "$rc" > "$PARTDB_DIR/${idx}.splitrc"
    awk -v a="$t1" -v b="$t0" 'BEGIN { printf "%.3f", a - b }' > "$PARTDB_DIR/${idx}.dur"
    : > "$PARTDB_DIR/${idx}.done"
    return 0
}

# One chunk worker (Phase D): parses exactly one chunk into its own chunk_<id>.duckdb.
# Single-writer is preserved (separate DBs). Writes rc/out sidecar + .done sentinel.
# rc=137 (OOM SIGKILL) triggers the backoff under --auto. Test hook FM_AUTO_TEST_OOM=
# "Catalog[:N]" simulates an OOM for chunks of this catalog in the first N attempts —
# but ONLY for still-divisible chunks (record_count>1), like a real size OOM (a
# 1-record chunk would be tiny and would never OOM).
_turbo_chunk_worker() {
    local cid="$1" cpath="$2" coff="$3" ccat="$4" catt="$5" crc="$6"
    local pdb="$STREAMING_DIR/chunk_${cid}.duckdb"
    local clog="$STREAMING_DIR/chunk_${cid}.out"
    rm -f "$pdb"; : > "$clog"
    if [ -n "${FM_AUTO_TEST_OOM:-}" ]; then
        local _fc="${FM_AUTO_TEST_OOM%%:*}" _fn="${FM_AUTO_TEST_OOM##*:}"
        [ "$_fn" = "$FM_AUTO_TEST_OOM" ] && _fn=1
        if [ "$ccat" = "$_fc" ] && [ "${catt:-1}" -le "$_fn" ] && [ "${crc:-0}" -gt 1 ]; then
            echo "[FM_AUTO_TEST_OOM] simulated OOM: catalog=$ccat attempt=$catt rc=$crc" > "$clog"
            echo 137 > "$STREAMING_DIR/chunk_${cid}.rc"; : > "$STREAMING_DIR/chunk_${cid}.done"; return 0
        fi
    fi
    # Per-worker thread budget. local + dynamic scoping → memory_limit_prefix
    # (in run_p1_on) sees this value; background subshell + local → P2–P6 untouched.
    local DUCKDB_THREADS="${TURBO_WORKER_THREADS:-${DUCKDB_THREADS:-}}"
    # Env-guarded per-chunk duration for the LPT-floor measurement. Default-off
    # (no .dur, no behavior change → byte identity untouched).
    local _t4t0=""; [ -n "${FM_T4_TRACE:-}" ] && _t4t0=$(now_epoch)
    # FM_P1_CATALOG activates the section dispatch in run_p1_on : the
    # chunk contains exactly the catalog $ccat → only its sections (+ untagged
    # mandatory parts) run. Opt-out globally via FM_P1_DISPATCH=0.
    P1_TARGET_DB="$pdb" P1_SEQ_OFFSET="$coff" FM_P1_CATALOG="$ccat" run_p1_on "$(dirname "$cpath")" "$(basename "$cpath")" "$clog"
    local rc=$?
    [ -n "$_t4t0" ] && awk -v a="$(now_epoch)" -v b="$_t4t0" 'BEGIN{printf "%.3f", a-b}' > "$STREAMING_DIR/chunk_${cid}.dur"
    echo "$rc" > "$STREAMING_DIR/chunk_${cid}.rc"
    [ "$rc" -ne 0 ] && rm -f "$pdb"     # only successful chunk DBs go into consolidation
    : > "$STREAMING_DIR/chunk_${cid}.done"
}

# Auto-backoff: cut an OOM chunk finer. Re-splits the chunk XML with
# M' = ⌊M/2⌋ (same record anchor from SUBCHUNK_RECMAP), inserts the finer pieces as
# new 'pending' rows (seq_offset = orig_offset + local_split_number×M', attempt+1)
# and removes the OOM row + its sidecars. Returns 0 = resplit done, 1 = not
# divisible (main/DDR_INFO, M≤1) or attempts (K) exhausted → the caller escalates.
_turbo_resplit_chunk() {
    local cid="$1"
    local K="${FM_AUTO_MAX_ATTEMPT:-4}"
    # sub_m is NOT held in the chunkmap (only in the sidecar) — the finer granularity
    # derives from record_count (chunkmap column): mp = ⌈record_count/2⌉ halves the chunk.
    local row; row=$("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c \
        "SELECT file_name||chr(9)||catalog||chr(9)||chunk_path||chr(9)||seq_offset||chr(9)||COALESCE(record_count,0)||chr(9)||attempt||chr(9)||COALESCE(parser_policy,'dom') FROM chunkmap WHERE chunk_id=$cid;")
    [ -z "$row" ] && return 1
    local fn cat cpath off rc att pol
    IFS=$'\t' read -r fn cat cpath off rc att pol <<< "$row"
    [ "${att:-1}" -ge "$K" ] && return 1            # convergence limit (K attempts)
    [ "${rc:-0}" -le 1 ] && return 1                # only ≤1 record left → not divisible further
    local recelem="" e
    for e in $SUBCHUNK_RECMAP; do
        if [ "${e%%:*}" = "$cat" ]; then recelem="${e#*:}"; recelem="${recelem%%:*}"; break; fi
    done
    [ -z "$recelem" ] && return 1                   # main/DDR_INFO etc. → not sub-chunkable
    # The chunk on disk was already streamify-renamed at the initial split
    # (Layout→LC_Layout, Script→SFS_Script, …). Translate the record anchor through
    # STREAMIFY_RULES so the splitter matches the RENAMED element — otherwise it finds no
    # anchor, emits no branch row, and the OOM backoff ESCALATES instead of refining.
    # Mirror of the EFFECTIVE_RECMAP mapping in the initial split (SPLITTER_AWK does not
    # rename, so only the recmap anchor needs translating; the catalog stays unchanged).
    if $STREAMIFY_MODE && [ -n "$STREAMIFY_RULES" ]; then
        local _new
        _new=$(printf '%s' "$STREAMIFY_RULES" | tr ',' '\n' \
               | awk -F: -v b="$cat" -v r="$recelem" '$1==b && $2==r {print $3; exit}')
        [ -n "$_new" ] && recelem="$_new"
    fi
    local mp=$(( (rc + 1) / 2 )); [ "$mp" -lt 1 ] && mp=1   # ⌈rc/2⌉
    local rdir; rdir="$(dirname "$cpath")/resplit_${cid}"
    rm -rf "$rdir"; mkdir -p "$rdir"
    local sc="$rdir/chunkmap.tsv"
    # LC_ALL=C "$AWK_BIN" (mirror of the initial split) — byte transparency + the
    # configured awk (mawk/gawk), not the shell default awk.
    LC_ALL=C "$AWK_BIN" -v outdir="$rdir" -v subchunk="$mp" -v recmap="${cat}:${recelem}:${mp}" -v chunkmap="$sc" \
        -f "$KATANA_COMMON_AWK" -f "$SPLITTER_AWK" < "$cpath" >"$rdir/split.log" 2>&1 || return 1
    [ -f "$sc" ] || return 1
    # Only rows of the target catalog: the splitter ALWAYS emits a 'main' row (the
    # thinned-out wrapper remainder), which does NOT count as a branch chunk here. At
    # least one branch row must be present (otherwise the DELETE would lose the records).
    awk -F'\t' -v c="$cat" '$1==c{f=1} END{exit !f}' "$sc" || return 1
    local szf="$rdir/sizes.tsv"; : > "$szf"
    local cf; for cf in "$rdir"/chunk_*.xml; do printf '%s\t%s\n' "$cf" "$(stat -c%s "$cf" 2>/dev/null || echo 0)" >> "$szf"; done
    local fnq="${fn//\'/\'\'}" catq="${cat//\'/\'\'}" polq="${pol//\'/\'\'}"
    # Atomic (transaction): if INSERT/UPDATE fails, the OOM row is kept
    # (the caller escalates), rather than deleting it without inserting a replacement.
    "$DUCKDB_BIN" "$CHUNKMAP_DB" -c "
        BEGIN TRANSACTION;
        INSERT INTO chunkmap
        SELECT (SELECT COALESCE(MAX(chunk_id),0) FROM chunkmap) + ROW_NUMBER() OVER (),
               '$fnq', '$catq', '$fnq'||'::'||'$catq', split_number,
               '$rdir'||'/'||chunk_file, record_count,
               CAST($off AS BIGINT) + CAST(split_number AS BIGINT)*CAST(sub_m AS BIGINT),
               NULL, '$polq', NULL, 'pending', $((att + 1))
        FROM read_csv('$sc', delim='\t', header=false,
             columns={'catalog':'VARCHAR','split_number':'INTEGER','record_count':'INTEGER','sub_m':'INTEGER','chunk_file':'VARCHAR'})
        WHERE catalog='$catq';
        UPDATE chunkmap SET est_bytes=s.b FROM (SELECT p,b FROM read_csv('$szf',delim='\t',header=false,columns={'p':'VARCHAR','b':'BIGINT'})) s
          WHERE chunkmap.chunk_path=s.p AND chunkmap.est_bytes IS NULL;
        DELETE FROM chunkmap WHERE chunk_id=$cid;
        COMMIT;" >"$rdir/insert.log" 2>&1 || return 1
    rm -f "$STREAMING_DIR/chunk_${cid}.rc" "$STREAMING_DIR/chunk_${cid}.out" \
          "$STREAMING_DIR/chunk_${cid}.done" "$STREAMING_DIR/chunk_${cid}.duckdb"
    return 0
}

# Phase D: rolling worker pool over ALL open chunks (cross-file), heaviest-first.
# Generalizes run_p1_parallel from file to chunk level (sentinel-based, bash-3.2).
# Under --auto as a round loop: after each wave rc→status is written back;
# OOM chunks (rc=137) are cut finer (_turbo_resplit_chunk) and re-dispatched in the
# next round, until no OOMs occur anymore or nothing is divisible further.
_turbo_dispatch() {
    local round=0

    # ---- Phase-D per-file chunk bookkeeping (quiet/web only) ----------------
    # Drives the import_start / import_progress / import_done lifecycle so the
    # file-status table shows ✴️ + a live "k of N" chunk counter and flips to ✅
    # once a file's last chunk lands. Built ONCE up front (survives --auto backoff
    # rounds): totals come from the chunkmap (skipped_unchanged chunks excluded),
    # the done counter accumulates. bash-3-safe: parallel indexed arrays + a linear
    # file scan (a handful of files). Re-split chunks from an OOM backoff carry new
    # chunk_ids not in this map → their progress is simply not shown live; the
    # authoritative per-file `file` event (report loop) still sets the final state.
    # _D_chunkslot is keyed by chunk_id (integer); _D_slot_* are per distinct file.
    local _d_cid _d_fn _d_slot _d_k _d_xi _d_bn
    local -a _D_slot_key _D_slot_disp _D_total _D_done _D_started _D_finished _D_chunkslot
    _D_slot_key=(); _D_slot_disp=(); _D_total=(); _D_done=(); _D_started=(); _D_finished=(); _D_chunkslot=()
    if $QUIET_MODE; then
        while IFS=$'\t' read -r _d_cid _d_fn; do
            [ -z "$_d_cid" ] && continue
            _d_slot=-1
            for ((_d_k = 0; _d_k < ${#_D_slot_key[@]}; _d_k++)); do
                [ "${_D_slot_key[$_d_k]}" = "$_d_fn" ] && { _d_slot=$_d_k; break; }
            done
            if [ "$_d_slot" -lt 0 ]; then
                _d_slot=${#_D_slot_key[@]}
                _D_slot_key[$_d_slot]="$_d_fn"
                # Exact display filename (matches directory_status.filename): map the
                # chunkmap file_name (basename without .xml) back to the real XML file.
                _D_slot_disp[$_d_slot]="${_d_fn}.xml"
                for _d_xi in "${!XML_FILES[@]}"; do
                    _d_bn=$(basename "${XML_FILES[$_d_xi]}")
                    [ "${_d_bn%.xml}" = "$_d_fn" ] && { _D_slot_disp[$_d_slot]="$_d_bn"; break; }
                done
                _D_total[$_d_slot]=0; _D_done[$_d_slot]=0
                _D_started[$_d_slot]=0; _D_finished[$_d_slot]=0
            fi
            _D_total[$_d_slot]=$(( _D_total[$_d_slot] + 1 ))
            _D_chunkslot[$_d_cid]=$_d_slot
        done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c \
            "SELECT chunk_id::VARCHAR || chr(9) || file_name FROM chunkmap WHERE status<>'skipped_unchanged' ORDER BY chunk_id;")
    fi

    while :; do
        round=$((round + 1))
        local -a CID CPATH COFF CCAT CATT CRC
        CID=(); CPATH=(); COFF=(); CCAT=(); CATT=(); CRC=()
        local cid cpath coff ccat catt crc
        while IFS=$'\t' read -r cid cpath coff ccat catt crc; do
            [ -z "$cid" ] && continue
            CID+=("$cid"); CPATH+=("$cpath"); COFF+=("$coff"); CCAT+=("$ccat"); CATT+=("$catt"); CRC+=("$crc")
        done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c \
            "SELECT chunk_id::VARCHAR || chr(9) || chunk_path || chr(9) || seq_offset::VARCHAR || chr(9) || catalog || chr(9) || attempt::VARCHAR || chr(9) || COALESCE(record_count,0)::VARCHAR
             FROM chunkmap WHERE status='pending' ORDER BY est_bytes DESC NULLS LAST, chunk_id;")
        local n=${#CID[@]}
        [ "$n" -eq 0 ] && break
        # Per-round disk guard: each chunk writes its own chunk_<id>.duckdb (+ .out/.rc/
        # .done sidecars). If the volume is already tight, dispatching only deepens the
        # "No space left on device" cascade — stop now with a logged root cause.
        if ! check_disk_space "Phase D (round $round, $n chunks pending)"; then
            echo "  ✗ Phase D aborted: no disk space left (details in the error log)." >&2
            break
        fi
        local W="${TURBO_W:-1}"; [ "$W" -lt 1 ] && W=1
        if $QUIET_MODE; then emit_log "Phase D (round $round): $n chunks on $W worker"
        else echo "  Phase D (round $round): $n chunks on $W worker → chunk_<id>.duckdb"; fi

        local i=0 done_count=0 s pid any
        local -a slot_pid slot_k
        for ((s = 0; s < W; s++)); do slot_pid[$s]=0; done
        while [ "$done_count" -lt "$n" ]; do
            for ((s = 0; s < W && i < n; s++)); do
                [ "${slot_pid[$s]}" -ne 0 ] && continue
                rm -f "$STREAMING_DIR/chunk_${CID[$i]}.done"
                # Lifecycle: first dispatched chunk of a file → import_start (✴️).
                if $QUIET_MODE; then
                    _d_slot=${_D_chunkslot[${CID[$i]}]:-}
                    if [ -n "$_d_slot" ] && [ "${_D_started[$_d_slot]:-0}" -eq 0 ]; then
                        _D_started[$_d_slot]=1
                        # Send done/total so the file progress bar in the
                        # frontend starts at 0 % immediately (instead of pulsing
                        # indeterminately until the first reaped chunk — the first/heaviest
                        # chunk can run several seconds). total is already fixed here (planning).
                        _emit_json import_start filename "${_D_slot_disp[$_d_slot]}" done "int=0" total "int=${_D_total[$_d_slot]}"
                    fi
                fi
                _turbo_chunk_worker "${CID[$i]}" "${CPATH[$i]}" "${COFF[$i]}" "${CCAT[$i]}" "${CATT[$i]}" "${CRC[$i]}" &
                slot_pid[$s]=$!; slot_k[$s]=$i; i=$((i + 1))
            done
            any=false
            for ((s = 0; s < W; s++)); do
                pid=${slot_pid[$s]}; [ "$pid" -eq 0 ] && continue
                # Normal completion = the worker wrote its .done sentinel. Fallback: the
                # process is no longer alive but left NO sentinel — this happens when the
                # worker died before its last line could run (e.g. disk full prevented the
                # .rc/.done writes). Without this guard the loop would poll forever. The
                # missing .rc then defaults to rc=3 → status=error → captured in the log.
                if [ -f "$STREAMING_DIR/chunk_${CID[${slot_k[$s]}]}.done" ] || ! kill -0 "$pid" 2>/dev/null; then
                    wait "$pid" 2>/dev/null
                    # Lifecycle: chunk reaped → bump the file's done counter, emit
                    # import_progress (✴️ "k of N"); last chunk → import_done (✅).
                    if $QUIET_MODE; then
                        _d_slot=${_D_chunkslot[${CID[${slot_k[$s]}]}]:-}
                        if [ -n "$_d_slot" ]; then
                            _D_done[$_d_slot]=$(( _D_done[$_d_slot] + 1 ))
                            _emit_json import_progress filename "${_D_slot_disp[$_d_slot]}" done "int=${_D_done[$_d_slot]}" total "int=${_D_total[$_d_slot]}"
                            if [ "${_D_done[$_d_slot]}" -ge "${_D_total[$_d_slot]}" ] && [ "${_D_finished[$_d_slot]:-0}" -eq 0 ]; then
                                _D_finished[$_d_slot]=1
                                _emit_json import_done filename "${_D_slot_disp[$_d_slot]}"
                            fi
                        fi
                    fi
                    slot_pid[$s]=0; done_count=$((done_count + 1)); any=true
                fi
            done
            if $QUIET_MODE && $any; then phase_progress import $(( (done_count * 100) / n )) "Phase D: $done_count/$n chunks"; fi
            $any || sleep 0.1
        done

        # rc → chunkmap status (main process = the only chunkmap writer).
        local upd="" r st
        for ((s = 0; s < n; s++)); do
            cid="${CID[$s]}"; r=$(cat "$STREAMING_DIR/chunk_${cid}.rc" 2>/dev/null); r=${r:-3}
            # 137 = SIGKILL (Linux cgroup OOM-killer), 143 = SIGTERM. A chunk worker is
            # killed by a signal almost only under memory pressure (nobody else TERMs a
            # single worker); some environments (macOS/Docker-Desktop VM) deliver the OOM
            # as SIGTERM(143) instead of SIGKILL(137). Treat both as OOM → --auto backoff.
            if [ "$r" = "0" ]; then st=done; elif [ "$r" = "137" ] || [ "$r" = "143" ]; then st=oom; else st=error; fi
            upd="$upd UPDATE chunkmap SET status='$st' WHERE chunk_id=$cid;"
            # Persist the failure for post-mortem: a hard error (st=error) is captured
            # immediately (no backoff will retry it); an OOM is captured only once the
            # backoff has actually exhausted it (handled below) to avoid noise on chunks
            # that succeed after a finer re-split. The chunk's .out holds the DuckDB/parse
            # stderr; an empty/missing .out itself is a signal (e.g. the worker could not
            # even create its log → disk full).
            if [ "$st" = "error" ]; then
                {
                    echo "chunk_id=$cid  rc=$r  catalog=${CCAT[$s]:-?}  attempt=${CATT[$s]:-?}"
                    echo "chunk_path=${CPATH[$s]:-?}"
                    echo "--- chunk_${cid}.out ---"
                    if [ -s "$STREAMING_DIR/chunk_${cid}.out" ]; then cat "$STREAMING_DIR/chunk_${cid}.out"
                    else echo "(empty or missing — the worker may not have been able to write its log, e.g. disk full)"; fi
                } | log_error_section "Phase D chunk $cid failed (rc=$r, catalog=${CCAT[$s]:-?})"
            fi
        done
        # A-B8: check rc — a silently swallowed status UPDATE would let --auto
        # re-dispatch the same 'oom' chunks forever (the chunk map stays stale).
        if [ -n "$upd" ] && ! "$DUCKDB_BIN" "$CHUNKMAP_DB" -c "$upd" >/dev/null 2>&1; then
            echo "  ✗ Chunk status UPDATE failed (chunk map not writable?) — dispatch round aborted." >&2
            echo "chunk-map UPDATE failed: $CHUNKMAP_DB" | log_error_section "Phase D chunk-status UPDATE failed"
            break
        fi

        $AUTO_MODE || break    # without backoff: one round

        local -a ooms; ooms=()
        while IFS= read -r cid; do [ -n "$cid" ] && ooms+=("$cid"); done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT chunk_id FROM chunkmap WHERE status='oom';")
        [ ${#ooms[@]} -eq 0 ] && break
        local progress=false diag
        for cid in "${ooms[@]}"; do
            if _turbo_resplit_chunk "$cid"; then
                progress=true
                if $QUIET_MODE; then emit_log "Auto-backoff: chunk $cid OOM → split finer"
                else echo "  ↯ Auto-backoff: chunk $cid OOM → split-group finer (M halved), re-dispatch"; fi
            else
                diag=$("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT file_name||' / '||catalog||' (records='||COALESCE(record_count,0)||', attempt='||attempt||', est_bytes='||COALESCE(est_bytes,0)||')' FROM chunkmap WHERE chunk_id=$cid;")
                # Terminal OOM status (distinct from a plain 'error'): the resplit list
                # only re-picks status='oom', so this both stops the re-dispatch loop AND
                # keeps the cause visible to _turbo_file_has_oom (→ oom, not sql_error).
                "$DUCKDB_BIN" "$CHUNKMAP_DB" -c "UPDATE chunkmap SET status='oom_error' WHERE chunk_id=$cid;" >/dev/null 2>&1
                echo "  ✗ Auto-backoff exhausted: $diag — does not fit into the memory band (not further divisible or K reached)." >&2
                {
                    echo "Auto-backoff exhausted (not further divisible or K=${FM_AUTO_MAX_ATTEMPT:-4} attempts reached)."
                    echo "$diag"
                    echo "--- chunk_${cid}.out ---"
                    if [ -s "$STREAMING_DIR/chunk_${cid}.out" ]; then cat "$STREAMING_DIR/chunk_${cid}.out"
                    else echo "(empty or missing)"; fi
                } | log_error_section "Phase D chunk $cid OOM — Backoff exhausted"
            fi
        done
        $progress || break     # no divisible OOM left → stop (the rest stays an error)
    done
}

# Phase C, stage 1: merge the chunk DBs of ONE file into its part_<idx>.duckdb.
# seed = main chunk (lowest chunk_id, carries base catalogs + per-document tables);
# the remaining chunks contribute ONLY their (record-disjoint) branch tables. For
# non-seed chunks the PER-DOCUMENT tables FilesCatalog/XMLMetadata are skipped — they
# are identical in EVERY chunk (each chunk is a full <FMSaveAsXML>) and would
# otherwise be duplicated per chunk; all other tables are disjoint across the chunks
# (unique UUIDs) → additive INSERT. Result = exactly the part_<idx>.duckdb that a
# classic --jobs+--split worker would have produced via UPSERT. Returns: 0 ok | 3 error.
# Reads the file's chunk list from the chunkmap (chunk_id order = XML order).
TURBO_PERDOC_SKIP="FilesCatalog XMLMetadata"
_turbo_build_part() {
    local idx="$1"
    local fn; fn="$(basename "${XML_FILES[$idx]}")"; fn="${fn%.xml}"
    local part="$PARTDB_DIR/part_${idx}.duckdb"
    rm -f "$part"
    local -a cdbs; local cid bad=0
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        if [ "$(cat "$STREAMING_DIR/chunk_${cid}.rc" 2>/dev/null)" != "0" ] || [ ! -f "$STREAMING_DIR/chunk_${cid}.duckdb" ]; then
            bad=1; cat "$STREAMING_DIR/chunk_${cid}.out" >> "$PARTDB_DIR/${idx}.out" 2>/dev/null
            continue
        fi
        cdbs+=("$STREAMING_DIR/chunk_${cid}.duckdb")
    done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c \
        "SELECT chunk_id FROM chunkmap WHERE file_name = '${fn//\'/\'\'}' ORDER BY chunk_id;")
    [ "$bad" -ne 0 ] && return 3
    [ ${#cdbs[@]} -eq 0 ] && return 3

    cp "${cdbs[0]}" "$part" || return 3
    [ ${#cdbs[@]} -eq 1 ] && return 0   # only main → done
    local tables; tables=$("$DUCKDB_BIN" -readonly "$part" -noheader -list -c \
        "SELECT table_name FROM information_schema.tables WHERE table_schema='main' AND table_type='BASE TABLE' AND table_name <> 'SchemaInfo' ORDER BY table_name;")
    # a1: same record-disjoint assumption as the catmerge — a record present in >1 chunk of
    # this file would crash the plain INSERT. Guard PK/UNIQUE tables with ON CONFLICT DO NOTHING.
    local pk_tables; pk_tables=$(_pk_constrained_tables "$part")
    local msql; msql="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX")"
    local k=1 cdb tbl
    while [ "$k" -lt "${#cdbs[@]}" ]; do
        cdb="${cdbs[$k]}"
        echo "ATTACH '$cdb' AS c (READ_ONLY);" >> "$msql"
        while IFS= read -r tbl; do
            [ -z "$tbl" ] && continue
            case " $TURBO_PERDOC_SKIP " in *" $tbl "*) continue ;; esac
            echo "INSERT INTO \"$tbl\" BY NAME SELECT * FROM c.\"$tbl\"$(_oc_clause "$tbl" "$pk_tables");" >> "$msql"
        done <<< "$tables"
        echo "DETACH c;" >> "$msql"
        k=$((k + 1))
    done
    local prc=0
    [ -s "$msql" ] && { "$DUCKDB_BIN" "$part" < "$msql" >> "$PARTDB_DIR/${idx}.out" 2>&1 || prc=3; }
    rm -f "$msql"
    return $prc
}

# Portable sha256 of one file — first field only (the hash). Candidates in order:
# GNU coreutils `sha256sum` (Linux, Homebrew gnubin) → `shasum -a 256` (stock
# macOS, perl on Linux) → `openssl dgst -sha256`. OUTPUT-driven fallback: the next
# candidate is tried as soon as the previous one yields nothing, so a missing tool
# and a broken one behave the same. Empty result = no tool at all (see the Phase-S
# preflight: the run stays correct, but --changed-only can never skip, because
# every chunk carries a NULL content_hash and every manifest row is dropped).
# Before this helper the engine called sha256sum bare with 2>/dev/null — on a
# stock macOS that silently produced NULL hashes for EVERY chunk, which the
# manifest writer reported as an OOM "backoff" and Phase R as a version drift.
_turbo_sha256() {
    local h
    h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    [ -n "$h" ] || h=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
    [ -n "$h" ] || h=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}')
    printf '%s' "$h"
}
# sha256 of the RAW XML (authoritative content hash).
_turbo_file_hash() { _turbo_sha256 "$1"; }

# ── Phase R (Reconciliation) — ONLY under --changed-only ─────────────────────
# Determines the file indices to SKIP (INCR_SKIP[idx]=1): unchanged per the
# (mtime,size) prefilter, otherwise the content hash; plus a converter/schema version
# gate (drift ⇒ full build, no skips) and master existence (missing ⇒ full build).
# Collision group: if multiple XML share the same internal File_Name and ONE of them
# changes, ALL must be redone (otherwise "last wins" breaks at merge time).
# INCR_SKIP[idx]=1 — keys are integer file indices → a plain (sparse) indexed array
# (bash-3.2-safe; was `declare -gA`, which needs bash 4.2+ for both -g and -A).
INCR_SKIP=()
_turbo_phase_r() {
    INCR_SKIP=()
    $CHANGED_ONLY || return 0
    $FORCE_REBUILD && { echo "  --changed-only + --force-rebuild → full build (manifest ignored)"; return 0; }
    [ -f "$DB_FILE" ] || { echo "  --changed-only: master missing → full build (no skip)"; return 0; }
    local mcount; mcount=$("$DUCKDB_BIN" -readonly "$MANIFEST_DB" -noheader -list -c "SELECT COUNT(*) FROM manifest_file;" 2>/dev/null)
    [ "${mcount:-0}" -eq 0 ] && { echo "  --changed-only: empty manifest → full build"; return 0; }

    local i fn mt sz rec m_mt m_sz m_hash m_conv m_schema m_internal h
    local -a cand_internal     # idx → internal_file_name (skip candidates); integer keys → indexed
    # changed_internal: SET of internal_file_names that have at least one changed XML.
    # bash-3.2-safe set = newline-delimited string (keys may contain spaces, e.g.
    # "Aufträge Verkauf"); membership via a native case-glob (no subprocess).
    local changed_internal=$'\n'
    for i in "${!XML_FILES[@]}"; do
        fn="$(basename "${XML_FILES[$i]}")"; fn="${fn%.xml}"
        mt=$(stat -c%Y "${XML_FILES[$i]}" 2>/dev/null || stat -f%m "${XML_FILES[$i]}" 2>/dev/null)
        sz=$(stat -c%s "${XML_FILES[$i]}" 2>/dev/null || stat -f%z "${XML_FILES[$i]}" 2>/dev/null)
        rec=$("$DUCKDB_BIN" -readonly "$MANIFEST_DB" -noheader -list -c \
            "SELECT file_mtime||chr(31)||file_size||chr(31)||COALESCE(file_hash,'')||chr(31)||COALESCE(converter_version,'')||chr(31)||COALESCE(schema_version,'')||chr(31)||COALESCE(internal_file_name,'') FROM manifest_file WHERE file_name='${fn//\'/\'\'}';")
        [ -z "$rec" ] && continue   # new file → treat as changed (no skip)
        # Separator is chr(31) (unit separator), NOT tab: tab is IFS whitespace, so
        # `read` collapses adjacent tabs — an EMPTY file_hash (no sha256 tool) shifted
        # every following field by one and the version gate compared the schema
        # version against the file name → a phantom "converter/schema drift".
        IFS=$'\x1f' read -r m_mt m_sz m_hash m_conv m_schema m_internal <<< "$rec"
        if [ "$m_conv" != "$CONVERTER_VERSION" ] || [ "$m_schema" != "$SCHEMA_VERSION_EXPECTED" ]; then
            echo "  --changed-only: converter/schema drift → full build (everything new)"
            INCR_SKIP=(); return 0
        fi
        if [ "$mt" = "$m_mt" ] && [ "$sz" = "$m_sz" ]; then
            cand_internal[$i]="$m_internal"
        else
            h=$(_turbo_file_hash "${XML_FILES[$i]}")
            if [ -n "$h" ] && [ "$h" = "$m_hash" ]; then cand_internal[$i]="$m_internal"
            else changed_internal="${changed_internal}${m_internal}"$'\n'; fi
        fi
    done
    for i in "${!cand_internal[@]}"; do
        # group (internal_file_name) has a change → do not skip
        case "$changed_internal" in *$'\n'"${cand_internal[$i]}"$'\n'*) continue ;; esac
        INCR_SKIP[$i]=1
    done
}

# ── Phase S (catalog level): catalog gate ────────────────────────
# Marks unchanged NON-main catalogs of changed files as skipped_unchanged, provided
# (a) --changed-only without --force-rebuild, (b) the batch is COLLISION-FREE
# (otherwise the part-path fallback kicks in at Phase C, which does not respect
# catalog skips), (c) the current catalog_hash == manifest_catalog.catalog_hash.
# Effect: the dispatcher (status='pending') skips them, and _turbo_merge_catalog
# produces no parquet for them → their master rows stay untouched (the scoped DELETE
# is by construction, since DELETE is limited to the File_Names present in the parquet).
# 'main' is NEVER skipped (carries FilesCatalog/XMLMetadata + feeds _turbo_write_manifest).
_turbo_catalog_gate() {
    $CHANGED_ONLY || return 0
    $FORCE_REBUILD && return 0
    [ -f "$MANIFEST_DB" ] || return 0
    # Non-skippable catalogs: 'main' (metadata/manifest) + feeders of multi-fed tables.
    local c _excl=""
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        _turbo_catalog_feeds_multifed "$c" && _excl="$_excl${_excl:+,}'${c//\'/\'\'}'"
    done < <("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT DISTINCT catalog FROM chunkmap;" 2>/dev/null)
    [ -z "$_excl" ] && _excl="''"
    "$DUCKDB_BIN" "$CHUNKMAP_DB" -c "
        ATTACH '$MANIFEST_DB' AS mf (READ_ONLY);
        UPDATE chunkmap SET status='skipped_unchanged'
        FROM (
            SELECT cur.file_name AS fn, cur.catalog AS cat
            FROM (
                -- ORDER BY seq_offset, split_number: canonical global order.
                -- split_number alone is ambiguous after an OOM resplit (its numbers
                -- restart at 0 per resplit group); seq_offset is globally monotonic.
                -- MUST stay identical to the aggregation in _turbo_write_manifest —
                -- a divergent order would mismatch every gate comparison.
                SELECT file_name, catalog,
                       md5(string_agg(content_hash, '|' ORDER BY seq_offset, split_number)) AS h
                FROM chunkmap
                WHERE catalog <> 'main' AND catalog NOT IN ($_excl)
                GROUP BY file_name, catalog
            ) cur
            JOIN mf.manifest_catalog mc
              ON mc.file_name = cur.file_name AND mc.catalog = cur.catalog
             AND mc.catalog_hash = cur.h
            -- Only if there is NO internal File_Name collision among the batch files:
            WHERE NOT EXISTS (
                SELECT 1 FROM mf.manifest_file f1
                JOIN mf.manifest_file f2
                  ON f1.internal_file_name = f2.internal_file_name
                 AND f1.file_name <> f2.file_name
                WHERE f1.file_name IN (SELECT DISTINCT file_name FROM chunkmap)
                  AND f2.file_name IN (SELECT DISTINCT file_name FROM chunkmap)
            )
        ) skip
        WHERE chunkmap.file_name = skip.fn AND chunkmap.catalog = skip.cat
          AND chunkmap.status = 'pending';
        DETACH mf;
    " >/dev/null 2>&1 || true
}

# ── manifest_run writer (policy-lock B1) ───────────────────────────────
# Stamps the one-row policy fingerprint of THIS run into the manifest —
# called only next to actual manifest/hash writes (successful runs), so the
# fingerprint always describes the run that produced the stored hashes.
# The inline CREATE covers manifests touched before init_manifest_db learned
# the table (additive, idempotent). Never fatal.
_manifest_write_run() {
    [ -f "$MANIFEST_DB" ] || return 0
    local _pol _wv _cv
    _pol=$($STREAMIFY_MODE && echo sax || echo dom)
    _wv=$(printf '%s' "${WEBBED_VERSION_DETECTED:-unknown}" | sed "s/'/''/g")
    _cv=$(printf '%s' "${CONVERTER_VERSION:-unknown}" | sed "s/'/''/g")
    "$DUCKDB_BIN" "$MANIFEST_DB" -c "
        CREATE TABLE IF NOT EXISTS manifest_run (
            id INTEGER PRIMARY KEY, parser_policy VARCHAR, ws_sentinel VARCHAR,
            webbed_version VARCHAR, converter_version VARCHAR, ts TIMESTAMP);
        INSERT INTO manifest_run VALUES
          (1, '$_pol', '${WS_SENTINEL_ON:-true}', '$_wv', '$_cv', (now() AT TIME ZONE 'UTC'))
        ON CONFLICT (id) DO UPDATE SET
           parser_policy=excluded.parser_policy, ws_sentinel=excluded.ws_sentinel,
           webbed_version=excluded.webbed_version, converter_version=excluded.converter_version,
           ts=excluded.ts;" >/dev/null 2>&1 || true
}

# ── Update the manifest — ALWAYS after a successful consolidation ──────
# For the files actually processed (not skipped, rc 0): signature +
# internal File_Name (from the part_<idx>.duckdb, before it is cleaned up) + versions.
_turbo_write_manifest() {
    local i fn part mcid internal fmver ddr h mt sz esc _wrote_any=false _boff _bc _excl_sql
    for i in "${!XML_FILES[@]}"; do
        [ -f "$PARTDB_DIR/${i}.unchanged" ] && continue          # skipped → manifest row stays valid
        [ "$(cat "$PARTDB_DIR/${i}.rc" 2>/dev/null)" = "0" ] || continue   # successes only
        fn="$(basename "${XML_FILES[$i]}")"; fn="${fn%.xml}"
        # Metadata source: part_<i> (part path) OR the file's main chunk (the catalog-
        # granular path builds no parts). Both carry the file's FilesCatalog/XMLMetadata.
        part="$PARTDB_DIR/part_${i}.duckdb"
        if [ ! -f "$part" ]; then
            mcid=$("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT chunk_id FROM chunkmap WHERE file_name='${fn//\'/\'\'}' AND catalog='main' ORDER BY chunk_id LIMIT 1;" 2>/dev/null)
            [ -n "$mcid" ] && part="$STREAMING_DIR/chunk_${mcid}.duckdb"
        fi
        [ -f "$part" ] || continue                                # neither part nor main chunk → skip
        internal=$("$DUCKDB_BIN" -readonly "$part" -noheader -list -c "SELECT File_Name FROM FilesCatalog LIMIT 1;" 2>/dev/null)
        fmver=$("$DUCKDB_BIN" -readonly "$part" -noheader -list -c "SELECT FileMaker_Version FROM FilesCatalog LIMIT 1;" 2>/dev/null)
        ddr=$("$DUCKDB_BIN" -readonly "$part" -noheader -list -c "SELECT Has_DDR_INFO FROM FilesCatalog LIMIT 1;" 2>/dev/null)
        mt=$(stat -c%Y "${XML_FILES[$i]}" 2>/dev/null || stat -f%m "${XML_FILES[$i]}" 2>/dev/null)
        sz=$(stat -c%s "${XML_FILES[$i]}" 2>/dev/null || stat -f%z "${XML_FILES[$i]}" 2>/dev/null)
        h=$(_turbo_file_hash "${XML_FILES[$i]}")
        esc() { printf '%s' "$1" | sed "s/'/''/g"; }
        "$DUCKDB_BIN" "$MANIFEST_DB" -c "
            INSERT INTO manifest_file
              (file_name, internal_file_name, file_mtime, file_size, file_hash,
               fm_version, has_ddr_info, converter_version, schema_version, last_ingest_ts)
            VALUES ('$(esc "$fn")', '$(esc "$internal")', ${mt:-0}, ${sz:-0}, '$(esc "$h")',
               '$(esc "$fmver")', '$(esc "$ddr")', '$(esc "$CONVERTER_VERSION")', '$(esc "$SCHEMA_VERSION_EXPECTED")', (now() AT TIME ZONE 'UTC'))
            ON CONFLICT (file_name) DO UPDATE SET
               internal_file_name=excluded.internal_file_name, file_mtime=excluded.file_mtime,
               file_size=excluded.file_size, file_hash=excluded.file_hash,
               fm_version=excluded.fm_version, has_ddr_info=excluded.has_ddr_info,
               converter_version=excluded.converter_version, schema_version=excluded.schema_version,
               last_ingest_ts=excluded.last_ingest_ts;" >/dev/null 2>&1
        # manifest_catalog: catalog_hash per (file × catalog) from the content_hashes of
        # the split-group (canonical order: seq_offset, split_number — identical to the
        # gate aggregation in _turbo_catalog_gate). The chunkmap contains ALL
        # catalogs of this file (skipped_unchanged ones also carry their content_hash
        # from Phase S), so the hash reflects the full current state. UPSERT only →
        # file-level skipped files (not in the chunkmap) keep their rows.
        #
        # Catalogs hit by the OOM backoff carry resplit rows WITHOUT a
        # content_hash (attempt > 1; the resplit has no hashes.tsv pendant) —
        # string_agg would silently skip the NULLs and stamp a subset hash whose
        # chunk boundaries depend on WHERE the backoff struck (RAM-dependent →
        # inherently run-unstable; refilling the hashes would NOT help, the
        # boundaries still differ from any fresh split). Such catalogs are
        # EXCLUDED: their manifest row is deleted, so the next run that processes
        # this file re-parses exactly this catalog once and stamps a canonical
        # hash again. Fail direction stays false-changed — a missing row can
        # never cause a false skip.
        #
        # Two causes share the exclusion, but NOT the log line: attempt > 1 is a real
        # OOM backoff (resplit); a NULL content_hash at attempt = 1 means the hash
        # was never computed (no sha256 tool — see the Phase-S preflight) and is
        # reported as such, so it can never be mistaken for a memory problem. The
        # "backoff: catalog … excluded from manifest" wording is parsed by the
        # regression gate backoff_manifest_exclusion.sh — keep it verbatim.
        _boff=$("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c \
            "SELECT catalog || chr(31) || CASE WHEN max(attempt) > 1 THEN 'backoff' ELSE 'nohash' END
               FROM chunkmap WHERE file_name='$(esc "$fn")' AND (content_hash IS NULL OR attempt > 1)
              GROUP BY catalog ORDER BY catalog;" 2>/dev/null)
        _excl_sql=""
        if [ -n "$_boff" ]; then
            while IFS=$'\x1f' read -r _bc _bwhy; do
                [ -z "$_bc" ] && continue
                _excl_sql="$_excl_sql${_excl_sql:+,}'${_bc//\'/\'\'}'"
                if [ "$_bwhy" = "backoff" ]; then
                    emit_log "backoff: catalog $_bc ($fn) excluded from manifest — next run re-parses it once"
                else
                    emit_warn "manifest: catalog $_bc ($fn) has no content hash (sha256 tool missing?) — excluded from manifest, next run re-parses it"
                fi
            done <<< "$_boff"
        fi
        [ -z "$_excl_sql" ] && _excl_sql="''"
        "$DUCKDB_BIN" "$MANIFEST_DB" -c "
            ATTACH '$CHUNKMAP_DB' AS cm (READ_ONLY);
            DELETE FROM manifest_catalog
             WHERE file_name='$(esc "$fn")' AND catalog IN ($_excl_sql);
            INSERT INTO manifest_catalog (file_name, catalog, catalog_hash, record_count, last_ingest_ts)
            SELECT file_name, catalog,
                   md5(string_agg(content_hash, '|' ORDER BY seq_offset, split_number)),
                   SUM(record_count), (now() AT TIME ZONE 'UTC')
            FROM cm.chunkmap WHERE file_name='$(esc "$fn")'
              AND catalog NOT IN ($_excl_sql)
            GROUP BY file_name, catalog
            ON CONFLICT (file_name, catalog) DO UPDATE SET
               catalog_hash=excluded.catalog_hash, record_count=excluded.record_count,
               last_ingest_ts=excluded.last_ingest_ts;
            DETACH cm;" >/dev/null 2>&1
        _wrote_any=true
    done
    # Fingerprint only when hashes were actually (re)written this run — an
    # all-unchanged/all-failed batch keeps the previous run's fingerprint,
    # which still correctly describes the stored hashes (policy-lock B1).
    $_wrote_any && _manifest_write_run
}

# ── Manifest row for a completed SINGLE-FILE run ───────────────────────
# _manifest_write_single <xml-abs-path> — called from single mode after a fully
# successful P1–P6 chain (both engines: classic and turbo-single). Writes the same
# manifest_file signature as _turbo_write_manifest so a later --batch --changed-only
# skips the file instead of re-parsing it. Differences to the batch writer:
#   - internal_file_name/fm_version/has_ddr_info come from the master's FilesCatalog
#     (newest Import_Timestamp = the row this run just wrote); there is no part DB.
#   - manifest_catalog rows for the file are DELETED, not written: single runs have no
#     per-chunk content hashes, and stale hashes from an older batch could let the
#     catalog gate skip a catalog whose master rows this run has since replaced.
#     Missing rows only cost the catalog-granular skip (whole-file re-parse on change).
_manifest_write_single() {
    local xml="$1"
    local fn mt sz h internal fmver ddr
    fn="$(basename "$xml")"; fn="${fn%.xml}"
    mt=$(stat -c%Y "$xml" 2>/dev/null || stat -f%m "$xml" 2>/dev/null)
    sz=$(stat -c%s "$xml" 2>/dev/null || stat -f%z "$xml" 2>/dev/null)
    h=$(_turbo_file_hash "$xml")
    IFS=$'\t' read -r internal fmver ddr < <("$DUCKDB_BIN" -readonly "$DB_FILE" -noheader -list -c \
        "SELECT File_Name || chr(9) || COALESCE(FileMaker_Version,'') || chr(9) || COALESCE(Has_DDR_INFO::VARCHAR,'')
         FROM FilesCatalog ORDER BY Import_Timestamp DESC LIMIT 1;" 2>/dev/null)
    esc() { printf '%s' "$1" | sed "s/'/''/g"; }
    "$DUCKDB_BIN" "$MANIFEST_DB" -c "
        INSERT INTO manifest_file
          (file_name, internal_file_name, file_mtime, file_size, file_hash,
           fm_version, has_ddr_info, converter_version, schema_version, last_ingest_ts)
        VALUES ('$(esc "$fn")', '$(esc "$internal")', ${mt:-0}, ${sz:-0}, '$(esc "$h")',
           '$(esc "$fmver")', '$(esc "$ddr")', '$(esc "$CONVERTER_VERSION")', '$(esc "$SCHEMA_VERSION_EXPECTED")', (now() AT TIME ZONE 'UTC'))
        ON CONFLICT (file_name) DO UPDATE SET
           internal_file_name=excluded.internal_file_name, file_mtime=excluded.file_mtime,
           file_size=excluded.file_size, file_hash=excluded.file_hash,
           fm_version=excluded.fm_version, has_ddr_info=excluded.has_ddr_info,
           converter_version=excluded.converter_version, schema_version=excluded.schema_version,
           last_ingest_ts=excluded.last_ingest_ts;
        DELETE FROM manifest_catalog WHERE file_name='$(esc "$fn")';" >/dev/null 2>&1
    # Policy fingerprint (B1): the single run rewrote this file's master rows
    # under the current policy — stamp it even though the per-catalog hashes
    # are deleted by design (the next batch re-hashes under its own policy).
    _manifest_write_run
}

# Read/write the catalogs_built marker (pipeline_state in the manifest DB).
# 'ok' ⇔ P2–P6 were last built completely for the current manifest state.
# Read echoes the value (empty if the DB/table/row is missing → conservatively "not ok").
_catalogs_state() {
    [ -f "$MANIFEST_DB" ] || { echo ""; return 0; }
    "$DUCKDB_BIN" -readonly "$MANIFEST_DB" -noheader -list -c \
        "SELECT value FROM pipeline_state WHERE key='catalogs_built';" 2>/dev/null
}
# _catalogs_state_set <ok|building> — idempotent upsert (errors not fatal).
_catalogs_state_set() {
    [ -f "$MANIFEST_DB" ] || return 0
    "$DUCKDB_BIN" "$MANIFEST_DB" -c \
        "INSERT INTO pipeline_state VALUES ('catalogs_built', '$1') ON CONFLICT (key) DO UPDATE SET value=excluded.value;" \
        >/dev/null 2>&1 || true
}

# Orchestrates S→D→C and writes the per-file sidecars for the telemetry loop.
# Phase C uses the proven merge_part_dbs (file-parallel path): stage 1 builds a
# part_<idx>.duckdb per file from its chunks, stage 2 merges the parts (DELETE-by-internal-
# File_Name) into the master — so the multiple-XML-per-File_Name collision (two XML
# exports of the same FileMaker file) is resolved identically to the classic path (last wins).
# Sets $TURBO_RC (= MERGE_RC; per-file errors appear as an rc sidecar as on the classic path).
run_turbo_pipeline() {
    TURBO_RC=0
    # T-3 trace (opt-in via FM_T3_TRACE): timestamp the phase boundaries S/D/C1/C2 to
    # separate the serial consolidation (stage 1 _turbo_build_part) from the parallel
    # dispatch. Default-off → byte-identical behavior (pure stdout echo).
    _t3() { [ -n "${FM_T3_TRACE:-}" ] && echo "@T3 $1 $(now_epoch)"; return 0; }
    local CHUNKS_ROOT="$STREAMING_DIR/chunks"
    rm -rf "$CHUNKS_ROOT"; mkdir -p "$CHUNKS_ROOT"
    rm -f "$STREAMING_DIR"/chunk_*.duckdb "$STREAMING_DIR"/chunk_*.rc "$STREAMING_DIR"/chunk_*.out "$STREAMING_DIR"/chunk_*.done "$STREAMING_DIR"/chunk_*.dur

    # Preflight: the turbo pipeline materializes one chunk_<id>.duckdb per chunk plus
    # split XML — a disk-full mid-run corrupts sidecars (.rc/.done) and stalls the
    # dispatcher. Fail fast with a logged, actionable error instead.
    if ! check_disk_space "Turbo-Preflight (Phase S)"; then TURBO_RC=8; return 8; fi

    # ---- Phase R (Reconciliation, --changed-only only): determine the skip set ----
    _turbo_phase_r
    local _nskip=${#INCR_SKIP[@]}
    if $CHANGED_ONLY && [ "$_nskip" -gt 0 ]; then
        if $QUIET_MODE; then emit_log "Phase R: $_nskip/$TOTAL file(s) unchanged → skipped"
        else echo "Phase R: $_nskip/$TOTAL file(s) unchanged → skipped (manifest)"; fi
    fi

    # ---- Phase S (P2.3: parallel split pool + serial chunkmap load) ----
    # The split part is independent per file (its own chunks/<idx>/) → slot pool over
    # W_S workers (sentinel pattern like run_p1_parallel). The chunkmap INSERT is
    # single-writer + serialization-bound (global chunk_id) and runs AFTERWARDS serially
    # in the main process in strict file order → identity W_S-invariant.
    # W_S = FM_PHASE_S_JOBS (default JOBS); the I/O-saturation / S→C question is decided
    # by the bench matrix, NOT the identity (which is by construction).
    if $QUIET_MODE; then emit_log "Phase S: split $TOTAL file(s) + plan chunk map"
    else echo "Phase S: split $TOTAL file(s) + plan chunk map"; fi
    # sha256 preflight: probe the helper once (on this very file — small, always
    # present). Without any hash tool the run stays correct, but every chunk gets a
    # NULL content_hash → the manifest writer drops every catalog row → --changed-only
    # never skips. Say so ONCE here instead of letting it surface as N misleading
    # per-catalog lines later.
    if [ -z "$(_turbo_sha256 "${BASH_SOURCE[0]}")" ]; then
        emit_warn "no sha256 tool found (sha256sum / shasum / openssl) — chunk hashes stay empty, so --changed-only cannot skip anything and every manifest row is dropped after the run. Install coreutils (macOS: brew install coreutils) or ensure 'shasum' is on PATH."
    fi
    local i
    local -a FILE_SPLIT_RC
    local SJOBS="${FM_PHASE_S_JOBS:-$JOBS}"; [ "$SJOBS" -ge 1 ] 2>/dev/null || SJOBS=1
    _t3 S_start

    # Mark skip files (manifest) up front — no worker needed.
    # Lifecycle event (quiet/web only): file_skip → ⏭️ in the file-status table.
    for i in "${!XML_FILES[@]}"; do
        if [ -n "${INCR_SKIP[$i]}" ]; then
            echo "  unchanged (manifest skip)" > "$PARTDB_DIR/${i}.out"
            : > "$PARTDB_DIR/${i}.unchanged"
            echo "0" > "$PARTDB_DIR/${i}.splitrc"
            echo "0.000" > "$PARTDB_DIR/${i}.dur"
            $QUIET_MODE && _emit_json file_skip filename "$(basename "${XML_FILES[$i]}")"
        fi
    done

    # Slot pool: split only non-skip files (in parallel, without the chunkmap INSERT).
    # Lifecycle event: file_plan → 🟡 (planned) for every file that will be processed.
    local -a _sq=()
    for i in "${!XML_FILES[@]}"; do
        if [ -z "${INCR_SKIP[$i]}" ]; then
            _sq+=("$i")
            $QUIET_MODE && _emit_json file_plan filename "$(basename "${XML_FILES[$i]}")"
        fi
    done
    local _sn=${#_sq[@]} _si=0 _sdone=0 _ss _spid _sany
    local -a _sslot_pid _sslot_idx
    for ((_ss = 0; _ss < SJOBS; _ss++)); do _sslot_pid[$_ss]=0; done
    while [ "$_sdone" -lt "$_sn" ]; do
        for ((_ss = 0; _ss < SJOBS && _si < _sn; _ss++)); do
            [ "${_sslot_pid[$_ss]}" -ne 0 ] && continue
            i=${_sq[$_si]}
            rm -f "$PARTDB_DIR/${i}.done"
            _turbo_split_worker "$i" &
            # Lifecycle event: chunk_start → 🔥 (currently being chunked).
            $QUIET_MODE && _emit_json chunk_start filename "$(basename "${XML_FILES[$i]}")"
            _sslot_pid[$_ss]=$!; _sslot_idx[$_ss]=$i; _si=$((_si + 1))
        done
        _sany=false
        for ((_ss = 0; _ss < SJOBS; _ss++)); do
            _spid=${_sslot_pid[$_ss]}; [ "$_spid" -eq 0 ] && continue
            # Zombie fallback (A-B5, pattern _turbo_dispatch): OOM-killed workers
            # leave no sentinel → without the kill-0 fallback the pool polls forever.
            # A missing .splitrc is treated below as rc=3 (error).
            if [ -f "$PARTDB_DIR/${_sslot_idx[$_ss]}.done" ] || ! kill -0 "$_spid" 2>/dev/null; then
                wait "$_spid" 2>/dev/null
                # Lifecycle event: chunk_done → 🟢 (split done, waiting for import).
                $QUIET_MODE && _emit_json chunk_done filename "$(basename "${XML_FILES[${_sslot_idx[$_ss]}]}")"
                _sslot_pid[$_ss]=0; _sdone=$((_sdone + 1)); _sany=true
            fi
        done
        # Opt 1: Phase S fills the `chunk` bar segment (0-25) live with the
        # split-pool progress — otherwise the bar would sit at ~5 % for the whole
        # split phase and only jump to the import segment at the first Phase-D worker.
        if $QUIET_MODE && $_sany && [ "$_sn" -gt 0 ]; then
            phase_progress chunk $(( (_sdone * 100) / _sn )) "Phase S: $_sdone/$_sn files split"
        fi
        $_sany || sleep 0.1
    done

    # Serial chunkmap load in strict file order (global chunk_id = identical to the
    # serial path). FILE_SPLIT_RC from the splitrc sidecars; load error → rc 3.
    for i in "${!XML_FILES[@]}"; do
        FILE_SPLIT_RC[$i]=$(cat "$PARTDB_DIR/${i}.splitrc" 2>/dev/null || echo 3)
        if [ "${FILE_SPLIT_RC[$i]}" -eq 0 ] && [ ! -f "$PARTDB_DIR/${i}.unchanged" ]; then
            _turbo_load_chunkmap_one "$i" "$(basename "${XML_FILES[$i]}")" || FILE_SPLIT_RC[$i]=3
        fi
    done

    # ---- Phase S (catalog gate): unchanged catalogs → skipped_unchanged ----
    _turbo_catalog_gate
    if $CHANGED_ONLY && ! $FORCE_REBUILD; then
        local _nskipcat
        _nskipcat=$("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT COUNT(*) FROM chunkmap WHERE status='skipped_unchanged';" 2>/dev/null)
        if [ "${_nskipcat:-0}" -gt 0 ]; then
            if $QUIET_MODE; then emit_log "Phase S: $_nskipcat catalog chunk(s) unchanged → skipped (manifest_catalog)"
            else echo "  Phase S: $_nskipcat catalog chunk(s) unchanged → skipped (manifest_catalog)"; fi
        fi
    fi

    # ---- Phase S → "no changes" short-circuit decision ----
    # 'main' is NEVER gated → every non-manifest-skipped file produces ≥1
    # 'pending' chunk. So pending==0 means exactly "not a single file changed".
    # Then the master DB is byte-identical to the previous run → P2–P6 + sync are pure
    # repetitions. Only skip if the catalogs_built marker confirms that the
    # catalogs were last built COMPLETELY (through P6) (safeguard against an abort
    # between Phase C and P6). --force-rebuild deliberately overrides this.
    if $CHANGED_ONLY && ! $FORCE_REBUILD; then
        local _pending
        _pending=$("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT COUNT(*) FROM chunkmap WHERE status='pending';" 2>/dev/null)
        [[ "$_pending" =~ ^[0-9]+$ ]] || _pending=1   # query error → do NOT skip, to be safe
        if [ "$_pending" -eq 0 ] && [ "$(_catalogs_state)" = "ok" ]; then
            TURBO_NO_CHANGES=true
            if $QUIET_MODE; then emit_log "Phase S: no changes detected → catalog rebuild (P2–P6) + sync skipped (DB already up to date)"
            else echo "Phase S: no changes detected → catalog rebuild (P2–P6) + sync skipped (DB already up to date)"; fi
        fi
    fi
    # This run changes P1/catalogs (or the catalogs are not yet 'ok') →
    # invalidate the marker so an abort between Phase C and P6 does NOT wrongly
    # skip on the next run. Set back to 'ok' only after a successful P6.
    $TURBO_NO_CHANGES || _catalogs_state_set building

    # ---- Phase S (explosion guard): hard ceiling on the total planned chunk count ----
    # Defense-in-depth backstop (the 119k-chunk crash lesson): even with the per-file DDR
    # cap + record gate, a pathological config (e.g. FM_DDR_MIN_RECORDS lowered to engage
    # the whole corpus at a small M) could multiply chunks corpus-wide. Phase D spawns ~1
    # DuckDB process per chunk → abort BEFORE dispatch rather than exhaust the host. Raise
    # / disable via FM_MAX_TOTAL_CHUNKS (default 10000; 0 = off). Legitimate runs sit well
    # below: ~880 base, ~1650 with DDR-auto, ~3800 with explicit DDR M=2.
    local _max_chunks="${FM_MAX_TOTAL_CHUNKS:-10000}"
    if [ "${_max_chunks:-0}" -gt 0 ]; then
        local _tot_chunks
        _tot_chunks=$("$DUCKDB_BIN" -readonly "$CHUNKMAP_DB" -noheader -list -c "SELECT COUNT(*) FROM chunkmap;" 2>/dev/null)
        [[ "$_tot_chunks" =~ ^[0-9]+$ ]] || _tot_chunks=0
        if [ "$_tot_chunks" -gt "$_max_chunks" ]; then
            { echo "✗ Phase S abort: $_tot_chunks planned chunks exceed the safety cap FM_MAX_TOTAL_CHUNKS=$_max_chunks."
              echo "  Protection against chunk explosion (1 chunk ≈ 1 DuckDB process + merge in Phase D — the 119k crash)."
              echo "  Most common cause: DDR sub-chunk. Remedy: raise M (FM_DDR_AUTO_M / FM_DDR_SUBCHUNK)"
              echo "  or raise the record threshold (FM_DDR_MIN_RECORDS)."
              echo "  Deliberately intended? Raise the cap: FM_MAX_TOTAL_CHUNKS=$((_tot_chunks + 1))  (or 0 = off)."
            } | log_error_section "Phase S chunk-count guard ($_tot_chunks > $_max_chunks)"
            echo "  ✗ Phase S aborted: too many chunks ($_tot_chunks > $_max_chunks). Details in the error log." >&2
            TURBO_RC=9; return 9
        fi
        if $QUIET_MODE; then emit_log "Phase S: $_tot_chunks chunk(s) planned (cap $_max_chunks)"
        else echo "  Phase S: $_tot_chunks chunk(s) planned (cap $_max_chunks)"; fi
    fi

    # ---- Phase D (worker pool over all chunks) ----
    _t3 D_start
    _turbo_dispatch
    _t3 C1_start

    local rc USE_CATMERGE=false
    # The catalog-granular merge is DEFAULT (collapses C1+C2: faster + identity-preserving).
    # Opt-out: FM_TURBO_NO_CATMERGE=1 → part path (merge_part_dbs, optionally with
    # FM_TURBO_PARQUET). Auto-fallback to the part path when the chunkmap contains a catalog
    # without an owner map (e.g. FM_SUBCHUNK_RECMAP override / splitter mode=fine) OR
    # multiple XML share the same internal File_Name (collision → catmerge PK violation).
    if [ -z "${FM_TURBO_NO_CATMERGE:-}" ] && _turbo_catmerge_ok; then
        USE_CATMERGE=true
    elif [ -z "${FM_TURBO_NO_CATMERGE:-}" ]; then
        if $QUIET_MODE; then emit_log "Note: catalog-granular merge not applicable (unknown catalog OR File_Name collision) → part path"
        else echo "  Note: catalog-granular merge not applicable (unknown catalog OR File_Name collision) → part path"; fi
    fi
    if $USE_CATMERGE; then
        # ---- Phase C CATALOG-GRANULAR (collapses stages 1+2): no part DBs ----
        # rc per file from chunk validity (replaces the build_part rc setting); _turbo_merge_catalog
        # reads the chunks directly. Skipped files (manifest) stay rc 0 with no merge contribution.
        for i in "${!XML_FILES[@]}"; do
            if [ -f "$PARTDB_DIR/${i}.unchanged" ]; then echo 0 > "$PARTDB_DIR/${i}.rc"; continue; fi
            rc=${FILE_SPLIT_RC[$i]:-3}
            [ "$rc" -eq 0 ] && { _turbo_file_chunks_ok "$i" || { _turbo_append_chunk_errs "$i"; rc=3; }; }
            # Preserve an OOM cause as rc 137 so the file is classified as oom, not sql_error.
            [ "$rc" -ne 0 ] && _turbo_file_has_oom "$i" && rc=137
            echo "$rc" > "$PARTDB_DIR/${i}.rc"
        done
        _t3 C2_start
        if $QUIET_MODE; then phase_progress import 100 "Phase C: chunks → master (catalog-granular)…"
        else echo "  Phase C: merge chunks → master (catalog-granular, DELETE-by-File + wildcard INSERT)…"; fi
        _turbo_merge_catalog
        _t3 C2_end
        TURBO_RC=${MERGE_RC:-0}
    else
        # ---- Phase C, stage 1: per file chunk DBs → part_<idx>.duckdb + rc sidecar ----
        # Skipped files build NO part_<idx> → merge_part_dbs leaves their master rows
        # untouched (rc 0, no part). Changed files: DELETE-by-File + INSERT.
        for i in "${!XML_FILES[@]}"; do
            rc=${FILE_SPLIT_RC[$i]:-3}
            if [ "$rc" -eq 0 ] && [ ! -f "$PARTDB_DIR/${i}.unchanged" ]; then
                _turbo_build_part "$i"; rc=$?
            fi
            # Preserve an OOM cause as rc 137 so the file is classified as oom, not sql_error.
            [ "$rc" -ne 0 ] && _turbo_file_has_oom "$i" && rc=137
            echo "$rc" > "$PARTDB_DIR/${i}.rc"
        done

        # ---- Phase C, stage 2: parts → master (proven merge_part_dbs) ----
        _t3 C2_start
        if $QUIET_MODE; then phase_progress import 100 "Phase C: merge parts → master…"
        else echo "  Phase C: merge parts into the master… $([ -n "${FM_TURBO_PARQUET:-}" ] && echo '(parquet wildcard)')"; fi
        if [ -n "${FM_TURBO_PARQUET:-}" ]; then _turbo_merge_parquet; else merge_part_dbs; fi
        _t3 C2_end
        TURBO_RC=${MERGE_RC:-0}
    fi

    # ---- Update the manifest (ALWAYS) — only on a successful consolidation ----
    [ "${TURBO_RC:-0}" -eq 0 ] && _turbo_write_manifest
}
