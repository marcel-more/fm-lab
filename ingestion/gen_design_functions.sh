#!/bin/bash
# gen_design_functions.sh — generates the built-in function name seed for the
# Phase-1c chunk retype from the bundled FileMaker reference database.
#
# Why this exists: FileMaker's SaXML export writes some built-in functions into
# the DDR chunk stream as <Chunk type="PluginFunctionRef"> — the chunk type
# otherwise used for plug-in calls — and keeps their names in the language of
# the authoring client: the design functions (DatabaseNames, WindowNames,
# LayoutIDs, ValueListItems, …: `Fensternamen`, `Nomsfenêtres`) and, as the
# coverage fixtures showed, the mobile functions too (Location, LocationValues,
# RangeBeacons: `Standort`, `Standortwerte`, `ReichweiteBeacons`). Every other
# built-in function arrives as FunctionRef with its canonical English name. The
# retype step sql/convert_xml_01c_design_function_retype.sql re-classifies those
# chunks by a POSITIVE name match; this generator derives that name list from
# the reference DB — since converter 2.24.0 EVERY built-in function of every
# category (all reference languages), not only the design category, so no
# further category can slip through as a synthetic plug-in. Get(…) selector
# tokens are deliberately excluded (they only ever appear inside Get(…) as
# FunctionRef, never as PluginFunctionRef). fm_spec stays the single source and
# the seed carries its provenance.
#
# Second table in the same seed: GetParameterNames — the bare Get(…) parameter
# names (canonical English plus every localized spelling the reference knows).
# They are deliberately NOT part of the retype list above, but P4 needs them as
# the validity gate of the layout-symbol edge: {{X}} is the value of Get(X) at
# display time, and only a symbol that names a real Get parameter may register a
# BuiltinFunction target — an unknown one renders literally and must not invent a
# catalog object. Both tables share this generator because they share one source,
# one freshness gate and one wiring into the pipeline.
#
# Output: sql/generated/design_functions_seed.sql — a committed generate
# (like the streamify SQL): CREATE OR REPLACE TABLE DesignFunctionNames + VALUES
# (table/file names kept for compatibility; the Category column tells the
# reference category of every row), followed by GetParameterNames.
# The pipeline runs it in the same DuckDB session right before the retype SQL
# (run_phase2() in convert_fm_xml.sh); the engine never attaches the reference
# DB at import time.
#
# Usage: ingestion/gen_design_functions.sh            → write the seed
#        ingestion/gen_design_functions.sh --check    → freshness gate: generate
#                                                       to a temp file and cmp
#                                                       against the committed seed
#                                                       (nothing is written)
#
# Exit-code contract (same family as gen_streamify_sql.sh):
#   0 = fresh / written · 2 = seed stale or missing, or reference DB missing
#   (genuine "not ready") · 3 = name-set invariant violated (refuses to write an
#   implausible seed) · 4 = infrastructure (duckdb / mktemp / cmp unusable —
#   NOT a freshness verdict).
#
# env: DUCKDB=/path/to/duckdb  FM_SPEC_DB=/path/to/fm_spec.duckdb
#
# bash-3.2 discipline (macOS system bash): no associative arrays, no bash-4+.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT/.." && pwd)"
SPEC="${FM_SPEC_DB:-$PROJECT_ROOT/reference/fm_spec.duckdb}"
OUT="$ROOT/sql/generated/design_functions_seed.sql"

CHECK_MODE=false
[ "${1:-}" = "--check" ] && CHECK_MODE=true

# --- infrastructure guards (rc 4) -------------------------------------------
DUCKDB_BIN="${DUCKDB:-}"
if [ -z "$DUCKDB_BIN" ]; then
    if command -v duckdb >/dev/null 2>&1; then DUCKDB_BIN="duckdb"
    elif [ -x /usr/local/bin/duckdb ]; then DUCKDB_BIN="/usr/local/bin/duckdb"
    elif [ -x /opt/homebrew/bin/duckdb ]; then DUCKDB_BIN="/opt/homebrew/bin/duckdb"
    elif [ -x "${HOME:-/nonexistent}/.duckdb/cli/latest/duckdb" ]; then DUCKDB_BIN="$HOME/.duckdb/cli/latest/duckdb"
    fi
fi
if [ -z "$DUCKDB_BIN" ] || ! "$DUCKDB_BIN" --version >/dev/null 2>&1; then
    echo "ERROR: duckdb CLI not found (PATH / /usr/local/bin / /opt/homebrew/bin, or set DUCKDB=/path/to/duckdb) — infrastructure, not a freshness verdict." >&2
    exit 4
fi
if $CHECK_MODE && ! command -v cmp >/dev/null 2>&1; then
    echo "ERROR: cmp not available — freshness gate cannot run (infrastructure)." >&2
    exit 4
fi
if ! tmp="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX" 2>/dev/null)" || [ -z "$tmp" ]; then
    echo "ERROR: mktemp failed (TMPDIR=${TMPDIR:-/tmp} not writable?) — infrastructure, not a freshness verdict." >&2
    exit 4
fi
trap 'rm -f "$tmp" "$tmp.rows" "$tmp.getrows"' EXIT

# --- genuine "not ready" (rc 2): no reference DB ----------------------------
if [ ! -f "$SPEC" ]; then
    echo "ERROR: reference DB missing: $SPEC (deploy it with tools/fm-reference/pull-reference.sh)" >&2
    exit 2
fi

q() { "$DUCKDB_BIN" -readonly -noheader -list "$SPEC" -c "$1"; }

# Shared name-set definition. Set = every built-in function of every reference
# category EXCEPT the Get selectors (category "Get Functions": Get(…) parameter
# tokens only ever appear as FunctionRef inside Get(…), never as PluginFunctionRef —
# a shared localized spelling like Italian 'NomeScript' = design function
# ScriptNames AND Get parameter ScriptName must not enter the set twice).
# Names = every display name of every reference language, plus any extra
# spelling the function-name lookup knows for chunk_role 'function' that is not
# already a display name (kept with its lookup source as the "language" label).
# Functions without a category (reference gap) are kept under category '?'.
NAMES_CTE="
WITH design AS (
    SELECT f.function_id, f.canonical_name, COALESCE(c.category_name, '?') AS category_name
    FROM functions f
    LEFT JOIN function_categories c USING (category_id)
    WHERE lower(COALESCE(c.category_name, '')) <> 'get functions'
),
names AS (
    SELECT d.function_id, d.canonical_name, d.category_name, fl.language, fl.display_name AS name
    FROM design d
    JOIN functions_lang fl USING (function_id)
    WHERE fl.display_name IS NOT NULL AND fl.display_name <> ''
    UNION
    SELECT d.function_id, d.canonical_name, d.category_name, 'lookup:' || l.match_source, l.lookup_name
    FROM design d
    JOIN function_name_lookup l USING (function_id)
    WHERE l.chunk_role = 'function'
      AND l.lookup_name IS NOT NULL AND l.lookup_name <> ''
      AND NOT EXISTS (
          SELECT 1 FROM functions_lang x
          WHERE x.function_id = d.function_id AND x.display_name = l.lookup_name)
)"

# Get-parameter set. The complement of the set above: the "Get Functions"
# category, one reference function per parameter, with every spelling the
# function-name lookup knows for chunk_role 'getparameter' — canonical English
# and the localized names (FileMaker accepts and renders both as a symbol).
# Kept with its lookup source, since the localized coverage is uneven and a
# consumer may need to know which axis a name came from.
GETP_CTE="
WITH getp AS (
    SELECT f.function_id, f.canonical_name
    FROM functions f
    JOIN function_categories c USING (category_id)
    WHERE lower(c.category_name) = 'get functions'
),
getnames AS (
    SELECT g.function_id, g.canonical_name, l.match_source AS source, l.lookup_name AS name
    FROM getp g
    JOIN function_name_lookup l USING (function_id)
    WHERE l.chunk_role = 'getparameter'
      AND l.lookup_name IS NOT NULL AND l.lookup_name <> ''
)"

# --- provenance --------------------------------------------------------------
META_SCHEMA=$(q "SELECT value FROM reference_meta WHERE key='schema_version'")
META_COVERAGE=$(q "SELECT value FROM reference_meta WHERE key='filemaker_coverage'")
META_COMMIT=$(q "SELECT value FROM reference_meta WHERE key='source_commit'")
META_BUILT=$(q "SELECT value FROM reference_meta WHERE key='built_at'")
if [ -z "$META_SCHEMA" ]; then
    echo "ERROR: reference DB has no reference_meta.schema_version — refusing to derive a seed from it." >&2
    exit 2
fi

# --- invariants (rc 3): refuse to write an implausible name set --------------
# n_functions ≥ 200 (FileMaker 22 ships ~375 built-in functions, ~138 of them Get
# selectors; additions are fine, losses are not), ≥ 10 languages, no name
# mapping to two different functions (the retype keeps the token text, but an
# ambiguous spelling would signal a reference defect), and the design category
# must still be part of the set (≥ 23 design functions — the historical core).
INV=$(q "$NAMES_CTE
SELECT
    (SELECT COUNT(*) FROM design) || '|' ||
    (SELECT COUNT(DISTINCT language) FROM functions_lang
      WHERE function_id IN (SELECT function_id FROM design)) || '|' ||
    (SELECT COUNT(*) FROM names) || '|' ||
    (SELECT COUNT(*) FROM (SELECT lower(name) FROM names GROUP BY 1
                           HAVING COUNT(DISTINCT function_id) > 1)) || '|' ||
    (SELECT COUNT(*) FROM design WHERE lower(category_name) = 'design functions')")
N_FUNCTIONS=${INV%%|*};  rest=${INV#*|}
N_LANGUAGES=${rest%%|*}; rest=${rest#*|}
N_ROWS=${rest%%|*};      rest=${rest#*|}
N_AMBIGUOUS=${rest%%|*}
N_DESIGN=${rest#*|}
if [ "${N_FUNCTIONS:-0}" -lt 200 ] || [ "${N_LANGUAGES:-0}" -lt 10 ] \
   || [ "${N_AMBIGUOUS:-1}" -ne 0 ] || [ "${N_DESIGN:-0}" -lt 23 ]; then
    echo "ERROR: built-in function name set implausible — functions=$N_FUNCTIONS (≥200) languages=$N_LANGUAGES (≥10) ambiguous=$N_AMBIGUOUS (0) design=$N_DESIGN (≥23). Not writing." >&2
    exit 3
fi

# Same discipline for the Get-parameter set: FileMaker 22 ships 138 Get
# parameters over 11 lookup sources; a name mapping to two different Get
# functions would make the symbol edge ambiguous and signals a reference defect.
GINV=$(q "$GETP_CTE
SELECT
    (SELECT COUNT(*) FROM getp) || '|' ||
    (SELECT COUNT(DISTINCT source) FROM getnames) || '|' ||
    (SELECT COUNT(*) FROM getnames) || '|' ||
    (SELECT COUNT(*) FROM (SELECT lower(name) FROM getnames GROUP BY 1
                           HAVING COUNT(DISTINCT function_id) > 1))")
N_GETPARAMS=${GINV%%|*}; grest=${GINV#*|}
N_GETSOURCES=${grest%%|*}; grest=${grest#*|}
N_GETROWS=${grest%%|*}
N_GETAMBIGUOUS=${grest#*|}
if [ "${N_GETPARAMS:-0}" -lt 130 ] || [ "${N_GETSOURCES:-0}" -lt 5 ] \
   || [ "${N_GETROWS:-0}" -lt 500 ] || [ "${N_GETAMBIGUOUS:-1}" -ne 0 ]; then
    echo "ERROR: Get-parameter name set implausible — parameters=$N_GETPARAMS (≥130) sources=$N_GETSOURCES (≥5) rows=$N_GETROWS (≥500) ambiguous=$N_GETAMBIGUOUS (0). Not writing." >&2
    exit 3
fi

# --- rows ----------------------------------------------------------------------
# Name_XML: the name with every non-ASCII character as an XML numeric char ref
# (&#xHH;, upper-case hex, no padding) — the form the DOM fragment path writes
# into DDR_Calculations.Chunk_Content. NULL when identical to Name.
q "$NAMES_CTE,
rows AS (
    SELECT function_id, canonical_name, category_name, language, name,
           list_aggregate(list_transform(regexp_extract_all(name, '[\\s\\S]'),
               lambda c: CASE WHEN unicode(c) > 127 THEN '&#x' || hex(unicode(c)) || ';' ELSE c END),
               'string_agg', '') AS name_xml
    FROM names
)
SELECT '    (' || function_id
       || ', ''' || replace(canonical_name, '''', '''''') || ''''
       || ', ''' || replace(category_name, '''', '''''') || ''''
       || ', ''' || replace(language, '''', '''''') || ''''
       || ', ''' || replace(name, '''', '''''') || ''''
       || ', ' || CASE WHEN name_xml = name THEN 'NULL'
                       ELSE '''' || replace(name_xml, '''', '''''') || '''' END
       || ')'
FROM rows
ORDER BY function_id, language, name" > "$tmp.rows"

ROWS_WRITTEN=$(wc -l < "$tmp.rows" | tr -d ' ')
if [ "$ROWS_WRITTEN" -ne "$N_ROWS" ]; then
    echo "ERROR: row count drifted between invariant query ($N_ROWS) and export ($ROWS_WRITTEN)." >&2
    exit 3
fi

q "$GETP_CTE
SELECT '    (' || function_id
       || ', ''' || replace(canonical_name, '''', '''''') || ''''
       || ', ''' || replace(source, '''', '''''') || ''''
       || ', ''' || replace(name, '''', '''''') || ''''
       || ')'
FROM getnames
ORDER BY function_id, source, name" > "$tmp.getrows"

GETROWS_WRITTEN=$(wc -l < "$tmp.getrows" | tr -d ' ')
if [ "$GETROWS_WRITTEN" -ne "$N_GETROWS" ]; then
    echo "ERROR: Get-parameter row count drifted between invariant query ($N_GETROWS) and export ($GETROWS_WRITTEN)." >&2
    exit 3
fi

{
    echo "-- @GENERATED by ingestion/gen_design_functions.sh from reference/fm_spec.duckdb — do not edit by hand."
    echo "-- @SOURCE fm_spec schema_version=$META_SCHEMA filemaker_coverage=$META_COVERAGE source_commit=$META_COMMIT built_at=$META_BUILT"
    echo "--"
    echo "-- Seed for the Phase-1c built-in function chunk retype"
    echo "-- (sql/convert_xml_01c_design_function_retype.sql): the names of every"
    echo "-- FileMaker built-in function (all reference categories except the Get"
    echo "-- selectors; converter 2.24.0 — before: design functions only) in every"
    echo "-- reference language, plus the XML numeric char-ref form of non-ASCII names"
    echo "-- (Name_XML) as the DOM fragment path serializes them into"
    echo "-- DDR_Calculations.Chunk_Content. Positive match list only — the SaXML chunk"
    echo "-- type PluginFunctionRef also covers plug-ins without a namespace and"
    echo "-- unresolvable identifiers, which must stay plug-in references."
    echo "--"
    echo "-- Regenerate after every reference pull: ingestion/gen_design_functions.sh"
    echo "-- (--check = freshness gate, exit 2 when stale). Executed by the pipeline in"
    echo "-- the same DuckDB session as the retype SQL; persists as catalog table"
    echo "-- DesignFunctionNames (name kept for compatibility; solution-independent,"
    echo "-- rebuilt on every import)."
    echo "CREATE OR REPLACE TABLE DesignFunctionNames ("
    echo "    Function_ID    INTEGER,   -- reference functions.function_id"
    echo "    Canonical_Name VARCHAR,   -- English name (reference functions.canonical_name)"
    echo "    Category       VARCHAR,   -- reference category (function_categories.category_name; '?' = uncategorized)"
    echo "    Language       VARCHAR,   -- reference language code, or 'lookup:<source>' for an extra spelling"
    echo "    Name           VARCHAR,   -- name as FileMaker writes it into the calculation"
    echo "    Name_XML       VARCHAR    -- Name with non-ASCII characters as &#xHH; char refs (NULL when identical)"
    echo ");"
    echo "INSERT INTO DesignFunctionNames VALUES"
    sed '$!s/$/,/' "$tmp.rows"
    echo ";"
    echo "-- rows: $N_ROWS · functions: $N_FUNCTIONS (design: $N_DESIGN) · languages: $N_LANGUAGES"
    echo ""
    echo "-- Bare Get(…) parameter names — the namespace of the layout symbol {{X}}"
    echo "-- (Claris: the symbol shows the value of Get(X) at display time). P4 uses"
    echo "-- it as the validity gate of the displays_symbol edge: only a symbol that"
    echo "-- names a real Get parameter registers a BuiltinFunction target, so an"
    echo "-- unknown symbol — which renders LITERALLY at runtime — never invents a"
    echo "-- catalog object. Localized spellings are part of the set: FileMaker"
    echo "-- accepts and renders them, and an export may carry either form."
    echo "-- Deliberately NOT part of DesignFunctionNames: Get selectors reach the"
    echo "-- chunk stream only as FunctionRef inside Get(…), never as PluginFunctionRef."
    echo "CREATE OR REPLACE TABLE GetParameterNames ("
    echo "    Function_ID    INTEGER,   -- reference functions.function_id (one row family per parameter)"
    echo "    Canonical_Name VARCHAR,   -- English parameter name (reference functions.canonical_name)"
    echo "    Source         VARCHAR,   -- reference lookup source (function_name_lookup.match_source)"
    echo "    Name           VARCHAR    -- spelling as FileMaker accepts it — canonical English or localized"
    echo ");"
    echo "INSERT INTO GetParameterNames VALUES"
    sed '$!s/$/,/' "$tmp.getrows"
    echo ";"
    echo "-- rows: $N_GETROWS · Get parameters: $N_GETPARAMS · lookup sources: $N_GETSOURCES"
} > "$tmp"

# Syntax/semantic self-check: the seed must load into an empty DB and yield
# exactly the exported row counts of BOTH tables.
LOADED=$({ cat "$tmp"; echo "SELECT (SELECT COUNT(*) FROM DesignFunctionNames) || '|' || (SELECT COUNT(*) FROM GetParameterNames);"; } \
         | "$DUCKDB_BIN" -noheader -list 2>&1 | tail -1)
if [ "$LOADED" != "$N_ROWS|$N_GETROWS" ]; then
    echo "ERROR: generated seed does not load cleanly (got '$LOADED', expected '$N_ROWS|$N_GETROWS')." >&2
    exit 3
fi

# --- write / check -------------------------------------------------------------
if $CHECK_MODE; then
    if [ ! -f "$OUT" ]; then
        echo "STALE: seed missing: $OUT — run ingestion/gen_design_functions.sh" >&2
        exit 2
    fi
    if cmp -s "$tmp" "$OUT"; then
        echo "fresh: $OUT (rows=$N_ROWS functions=$N_FUNCTIONS languages=$N_LANGUAGES · get-rows=$N_GETROWS parameters=$N_GETPARAMS, fm_spec $META_SCHEMA/$META_COMMIT)"
        exit 0
    fi
    echo "STALE: $OUT differs from the reference DB ($SPEC, fm_spec $META_SCHEMA/$META_COMMIT) — run ingestion/gen_design_functions.sh" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT")"
if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
    echo "unchanged: $OUT (rows=$N_ROWS functions=$N_FUNCTIONS languages=$N_LANGUAGES · get-rows=$N_GETROWS parameters=$N_GETPARAMS)"
    exit 0
fi
cp "$tmp" "$OUT"
echo "written: $OUT (rows=$N_ROWS functions=$N_FUNCTIONS languages=$N_LANGUAGES · get-rows=$N_GETROWS parameters=$N_GETPARAMS, fm_spec $META_SCHEMA/$META_COMMIT)"
exit 0
