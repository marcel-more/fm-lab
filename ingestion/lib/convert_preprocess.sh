#!/bin/bash
# katana-xml/lib/convert_preprocess.sh — stage-1 pre-processor: encoding detection,
# byte clean (UTF-8/BOM/CR-sentinel/C0-strip) + DDR recmap determination.
#
# Module of ingestion/convert_fm_xml.sh (shell split) — pure code movement,
# behaviour unchanged. NOT independently executable: is sourced by the driver
# (existence check there, A-B10) and uses its globals
# (WS_SENTINEL_ON, DDR_* configuration, report counters PRE_*).
# bash-3.2 discipline (macOS system bash): no `case` in $(…), no bash-4+.

# BOM-detect and iconv to UTF-8 first (GNU grep/awk see raw bytes otherwise and silently
# miss everything — the interactive ugrep shim auto-decodes, which once masked this).
# Kept as its OWN function rather than a `case` nested inside the `$(…)` in
# _ddr_count_records: bash 3.2 (the macOS system /bin/bash) has a command-substitution
# parser bug that chokes on a `case` statement inside `$(…)` ("syntax error near
# unexpected token ';;'"). A plain pipeline inside `$(…)` parses everywhere.
_decode_to_utf8() {
    local f="$1" bom
    bom=$(LC_ALL=C head -c 2 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$bom" in
        fffe) LC_ALL=C iconv -f UTF-16LE -t UTF-8 "$f" 2>/dev/null ;;
        feff) LC_ALL=C iconv -f UTF-16BE -t UTF-8 "$f" 2>/dev/null ;;
        *)    LC_ALL=C cat "$f" 2>/dev/null ;;
    esac
}

# Counts the DDR *Calculation* ObjectList records in $1 (depth-4 <_…> under DDR_INFO/
# Calculation) — ONLY Calculation is sub-chunked (it is the ~2.3-GB DOM-peak driver; Script
# is NOT sub-chunked, see _ddr_recmap_for_file). Encoding-robust via _decode_to_utf8.
# awk regex with \t works on the decoded stream (substr=="\t" does not in this awk).
# Echoes a single integer.
_ddr_count_records() {
    local f="$1" n
    [ -f "$f" ] || { echo 0; return; }
    n=$(_decode_to_utf8 "$f" | LC_ALL=C awk '
            /^\t<DDR_INFO>/              { ddr=1 }
            ddr  && /^\t\t<Calculation[ >]/ { inca=1 }
            inca && /^\t\t<\/Calculation>/  { inca=0 }
            inca && /^\t\t\t\t<_/        { c++ }
            END { print c+0 }')
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# Per-file DDR sub-chunk recmap entry, honoring the per-file chunk cap. Echoes
# "Calculation:*:M" (or nothing). $1 = path to the file to scan (any encoding).
# ONLY Calculation is sub-chunked — it is the ~2.3-GB peak driver AND its records carry a
# unique tag-name UUID (regex <(_[^\s>]+)), so each calc record lands in exactly one
# sub-chunk and the catmerge plain-INSERT stays collision-free. Script is deliberately NOT
# sub-chunked: ~some of its records use a bare "<_ hash=…>" tag (no UUID in the name) →
# Step_UUID extraction returns '' → multiple sub-chunks would each emit a ('' ,File) row →
# catmerge PRIMARY-KEY violation (the empty key also silently collapses those steps in the
# unsplit build — a separate, pre-existing DDR_ScriptSteps data-loss bug).
# M = max(M_floor, ceil(R / DDR_MAX_CHUNKS)) so ceil(R/M) ≤ DDR_MAX_CHUNKS per file.
_ddr_recmap_for_file() {
    $DDR_SUBCHUNK_ACTIVE || return 0
    local f="$1" R M m_cap
    R=$(_ddr_count_records "$f")
    [ "$R" -lt 1 ] && return 0
    # "Only very large files" — applies in BOTH modes. Without it, a small explicit M
    # multiplies the corpus-wide chunk count across all files (the 119k-explosion shape).
    # Small files' Calc chunk has no DOM-peak problem, so sub-chunking them is pointless.
    [ "$R" -lt "$DDR_MIN_RECORDS" ] && return 0
    M="$DDR_REQ_M"; [ "$M" -lt 1 ] && M=1
    m_cap=$(( (R + DDR_MAX_CHUNKS - 1) / DDR_MAX_CHUNKS ))           # ceil(R / cap)
    [ "$m_cap" -gt "$M" ] && M="$m_cap"                             # raise M to honor the cap
    printf 'Calculation:*:%s' "$M"
}

# ============================================================================
# Stage 1 — Pre-Processor
# ============================================================================

# detect_encoding <file> — echoes one of: utf-16le | utf-16be | utf-8-bom | utf-8
#
# BOM sniffing as the primary detection: POSIX-compliant and platform-independent.
# FileMaker exports SaXML consistently as UTF-16-LE *with* a BOM (FF FE). The formerly
# used BSD-specific `file -I` (uppercase) failed on GNU/Linux and let UTF-16 files
# pass through unconverted (empty DB). `file -i` (lowercase) remains only a fallback
# if no BOM is found.
detect_encoding() {
    local f="$1"
    local b3
    b3=$(od -An -tx1 -N3 "$f" 2>/dev/null | tr -d ' \n')
    case "$b3" in
        fffe*)  echo "utf-16le"; return 0 ;;
        feff*)  echo "utf-16be"; return 0 ;;
        efbbbf) echo "utf-8-bom"; return 0 ;;
    esac
    # Fallback: file -i (lowercase — valid on macOS AND Linux). GNU file often
    # classifies UTF-16 as 'binary' because of the null bytes; then the utf-8 default
    # below kicks in, which is correct for BOM-less UTF-8 sources.
    local charset
    charset=$(file -i "$f" 2>/dev/null | grep -o 'charset=[^ ;]*' | cut -d= -f2)
    case "$charset" in
        utf-16le) echo "utf-16le" ;;
        utf-16be) echo "utf-16be" ;;
        *)        echo "utf-8" ;;
    esac
}

# preprocess_file <src_path> <out_path>
#
# Pipeline of interchangeable sub-steps (order = pipeline):
#   (a)  Encoding → UTF-8                    — BOM sniffing primary, file -i fallback
#   (d)  BOM stripping (UTF-8 EF BB BF)      — after (a), also covers the iconv residual byte
#   (c2) DEL guard: strip literal 0x7F       — BEFORE (b), prevents a sentinel collision
#                                              with CR→DEL / chr(127)→chr(10) in convert_xml_01_extract.sql
#   (b)  Linebreak sentinel CR (0x0D) → DEL (0x7F)
#   (c)  Strip XML-1.0-invalid C0 bytes (0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F; covers U+001C)
#   (e)  TODO: entity normalization (&#13; etc.) — only if confirmed to be a problem
#   (f)  --split: chunk Phase 1 (implemented in the script via ingestion/engine/split_fm_xml.awk)
#   (h)  Known low-prio gap: U+FFFE/U+FFFF (Unicode non-characters, multibyte) — documented
#
# tr is byte-oriented, but UTF-8-safe here: UTF-8 continuation bytes always lie in the
# range 0x80-0xBF, never 0x0D or any other C0 byte. TAB/LF are preserved.
#
# Returns: 0 ok | 2 encoding error (iconv) | 5 cleanup error (tr)
# Sets global report variables: PRE_ENCODING, PRE_CR_COUNT, PRE_DEL_GUARD_COUNT, PRE_STRIPPED
preprocess_file() {
    local SRC="$1"
    local OUT="$2"
    local TMP_UTF8="${OUT}.utf8.$$"

    # (a) Encoding → UTF-8
    PRE_ENCODING=$(detect_encoding "$SRC")
    case "$PRE_ENCODING" in
        utf-16le)
            iconv -f UTF-16LE -t UTF-8 "$SRC" > "$TMP_UTF8" || { rm -f "$TMP_UTF8"; return 2; } ;;
        utf-16be)
            iconv -f UTF-16BE -t UTF-8 "$SRC" > "$TMP_UTF8" || { rm -f "$TMP_UTF8"; return 2; } ;;
        *)
            # utf-8 / utf-8-bom: copy unchanged; the BOM strip is handled by (d)
            cp "$SRC" "$TMP_UTF8" || { rm -f "$TMP_UTF8"; return 2; } ;;
    esac

    # (d) BOM stripping: remove the UTF-8 BOM. Occurs for utf-8-bom sources AND
    # after `iconv -f UTF-16LE` (the leading FF-FE BOM becomes U+FEFF = EF BB BF there).
    if [ "$(od -An -tx1 -N3 "$TMP_UTF8" 2>/dev/null | tr -d ' \n')" = "efbbbf" ]; then
        tail -c +4 "$TMP_UTF8" > "${TMP_UTF8}.nobom" && mv -f "${TMP_UTF8}.nobom" "$TMP_UTF8"
    fi

    # Report counters before the byte cleanup
    local in_size
    in_size=$(wc -c < "$TMP_UTF8" | tr -d ' ')
    PRE_CR_COUNT=$(tr -dc '\r' < "$TMP_UTF8" | wc -c | tr -d ' ')
    PRE_DEL_GUARD_COUNT=$(tr -dc '\177' < "$TMP_UTF8" | wc -c | tr -d ' ')

    # (c2) DEL guard → (b) CR→DEL [chr(127) sentinel, only when WS_SENTINEL_ON] → (c) strip C0.
    # Sentinel ON (default/old webbed): current behaviour — CR (0x0D) → 0x7F (DEL) so that
    # webbed's earlier #73 whitespace collapse does not eat the linebreak; the SQL brings 0x7F→LF
    # back (ws_restore). Sentinel OFF (probe: webbed preserves whitespace natively): skip CR→DEL
    # — CR is NOT in the C0-strip set, so it survives to the parser, which normalizes it natively
    # to LF; ws_restore then becomes a no-op. Shared source WS_SENTINEL_ON
    # with the SQL injection (wa_ws_sentinel). DEL guard + C0 strip run in both cases.
    if [ "${WS_SENTINEL_ON:-true}" = "false" ]; then
        if ! tr -d '\177' < "$TMP_UTF8" \
                | tr -d '\000-\010\013\014\016-\037' > "$OUT"; then
            rm -f "$TMP_UTF8"
            return 5
        fi
    else
        if ! tr -d '\177' < "$TMP_UTF8" \
                | tr '\r' '\177' \
                | tr -d '\000-\010\013\014\016-\037' > "$OUT"; then
            rm -f "$TMP_UTF8"
            return 5
        fi
    fi

    local out_size
    out_size=$(wc -c < "$OUT" | tr -d ' ')
    PRE_STRIPPED=$((in_size - out_size))
    rm -f "$TMP_UTF8"
    return 0
}
