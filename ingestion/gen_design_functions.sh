#!/bin/bash
# gen_design_functions.sh — generates the design-function name seed for the
# Phase-1c chunk retype from the bundled FileMaker reference database.
#
# Why this exists: FileMaker's SaXML export writes the design functions
# (DatabaseNames, WindowNames, LayoutIDs, ValueListItems, …) into the DDR chunk
# stream as <Chunk type="PluginFunctionRef"> — the chunk type otherwise used for
# plug-in calls — and keeps their names in the language of the authoring client
# (`Fensternamen`, `WindowNames`, `Nomsfenêtres`, …). Every other built-in
# function arrives as FunctionRef with its canonical English name. The retype
# step sql/convert_xml_01c_design_function_retype.sql re-classifies those chunks
# by a POSITIVE name match; this generator derives that name list from the
# reference DB (all reference languages) so fm_spec stays the single source and
# the seed carries its provenance.
#
# Output: sql/generated/design_functions_seed.sql — a committed generate
# (like the streamify SQL): CREATE OR REPLACE TABLE DesignFunctionNames + VALUES.
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
trap 'rm -f "$tmp" "$tmp.rows"' EXIT

# --- genuine "not ready" (rc 2): no reference DB ----------------------------
if [ ! -f "$SPEC" ]; then
    echo "ERROR: reference DB missing: $SPEC (deploy it with tools/fm-reference/pull-reference.sh)" >&2
    exit 2
fi

q() { "$DUCKDB_BIN" -readonly -noheader -list "$SPEC" -c "$1"; }

# Shared name-set definition. Design functions = the reference category
# "Design Functions" (matched by name, not by id). Names = every display name
# of every reference language, plus any extra spelling the function-name
# lookup knows that is not already a display name (kept with its lookup source
# as the "language" label).
NAMES_CTE="
WITH design AS (
    SELECT f.function_id, f.canonical_name
    FROM functions f
    JOIN function_categories c USING (category_id)
    WHERE lower(c.category_name) = 'design functions'
),
names AS (
    SELECT d.function_id, d.canonical_name, fl.language, fl.display_name AS name
    FROM design d
    JOIN functions_lang fl USING (function_id)
    WHERE fl.display_name IS NOT NULL AND fl.display_name <> ''
    UNION
    SELECT d.function_id, d.canonical_name, 'lookup:' || l.match_source, l.lookup_name
    FROM design d
    JOIN function_name_lookup l USING (function_id)
    WHERE l.chunk_role = 'function'
      AND l.lookup_name IS NOT NULL AND l.lookup_name <> ''
      AND NOT EXISTS (
          SELECT 1 FROM functions_lang x
          WHERE x.function_id = d.function_id AND x.display_name = l.lookup_name)
),
other_names AS (
    -- Function-level names of every NON-design function: display names in all
    -- languages plus the lookup's function spellings. Get-parameter /
    -- get-function tokens are deliberately NOT part of this set: they only ever
    -- appear as FunctionRef chunks inside Get(…), never as PluginFunctionRef,
    -- so a shared localized spelling (e.g. Italian 'NomeScript' = both the
    -- design function ScriptNames and the Get parameter ScriptName) cannot be
    -- retyped wrongly.
    SELECT lower(display_name) AS n FROM functions_lang
    WHERE function_id NOT IN (SELECT function_id FROM design)
    UNION
    SELECT lower(lookup_name) FROM function_name_lookup
    WHERE chunk_role = 'function'
      AND function_id NOT IN (SELECT function_id FROM design)
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
# n_functions ≥ 23 (the closed FileMaker set; additions are fine, losses are
# not), ≥ 10 languages, no name mapping to two functions, no collision with
# any non-design function name in any language (a collision would retype a
# genuine plug-in or built-in token).
INV=$(q "$NAMES_CTE
SELECT
    (SELECT COUNT(*) FROM design) || '|' ||
    (SELECT COUNT(DISTINCT language) FROM functions_lang
      WHERE function_id IN (SELECT function_id FROM design)) || '|' ||
    (SELECT COUNT(*) FROM names) || '|' ||
    (SELECT COUNT(*) FROM (SELECT lower(name) FROM names GROUP BY 1
                           HAVING COUNT(DISTINCT function_id) > 1)) || '|' ||
    (SELECT COUNT(*) FROM names WHERE lower(name) IN (SELECT n FROM other_names))")
N_FUNCTIONS=${INV%%|*};  rest=${INV#*|}
N_LANGUAGES=${rest%%|*}; rest=${rest#*|}
N_ROWS=${rest%%|*};      rest=${rest#*|}
N_AMBIGUOUS=${rest%%|*}
N_COLLISIONS=${rest#*|}
if [ "${N_FUNCTIONS:-0}" -lt 23 ] || [ "${N_LANGUAGES:-0}" -lt 10 ] \
   || [ "${N_AMBIGUOUS:-1}" -ne 0 ] || [ "${N_COLLISIONS:-1}" -ne 0 ]; then
    echo "ERROR: design-function name set implausible — functions=$N_FUNCTIONS (≥23) languages=$N_LANGUAGES (≥10) ambiguous=$N_AMBIGUOUS (0) collisions=$N_COLLISIONS (0). Not writing." >&2
    exit 3
fi

# --- rows ----------------------------------------------------------------------
# Name_XML: the name with every non-ASCII character as an XML numeric char ref
# (&#xHH;, upper-case hex, no padding) — the form the DOM fragment path writes
# into DDR_Calculations.Chunk_Content. NULL when identical to Name.
q "$NAMES_CTE,
rows AS (
    SELECT function_id, canonical_name, language, name,
           list_aggregate(list_transform(regexp_extract_all(name, '[\\s\\S]'),
               lambda c: CASE WHEN unicode(c) > 127 THEN '&#x' || hex(unicode(c)) || ';' ELSE c END),
               'string_agg', '') AS name_xml
    FROM names
)
SELECT '    (' || function_id
       || ', ''' || replace(canonical_name, '''', '''''') || ''''
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

{
    echo "-- @GENERATED by ingestion/gen_design_functions.sh from reference/fm_spec.duckdb — do not edit by hand."
    echo "-- @SOURCE fm_spec schema_version=$META_SCHEMA filemaker_coverage=$META_COVERAGE source_commit=$META_COMMIT built_at=$META_BUILT"
    echo "--"
    echo "-- Seed for the Phase-1c design-function chunk retype"
    echo "-- (sql/convert_xml_01c_design_function_retype.sql): the names of FileMaker's"
    echo "-- design functions in every reference language, plus the XML numeric char-ref"
    echo "-- form of non-ASCII names (Name_XML) as the DOM fragment path serializes them"
    echo "-- into DDR_Calculations.Chunk_Content. Positive match list only — the SaXML"
    echo "-- chunk type PluginFunctionRef also covers plug-ins without a namespace and"
    echo "-- unresolvable identifiers, which must stay plug-in references."
    echo "--"
    echo "-- Regenerate after every reference pull: ingestion/gen_design_functions.sh"
    echo "-- (--check = freshness gate, exit 2 when stale). Executed by the pipeline in"
    echo "-- the same DuckDB session as the retype SQL; persists as catalog table"
    echo "-- DesignFunctionNames (solution-independent, rebuilt on every import)."
    echo "CREATE OR REPLACE TABLE DesignFunctionNames ("
    echo "    Function_ID    INTEGER,   -- reference functions.function_id"
    echo "    Canonical_Name VARCHAR,   -- English name (reference functions.canonical_name)"
    echo "    Language       VARCHAR,   -- reference language code, or 'lookup:<source>' for an extra spelling"
    echo "    Name           VARCHAR,   -- name as FileMaker writes it into the calculation"
    echo "    Name_XML       VARCHAR    -- Name with non-ASCII characters as &#xHH; char refs (NULL when identical)"
    echo ");"
    echo "INSERT INTO DesignFunctionNames VALUES"
    sed '$!s/$/,/' "$tmp.rows"
    echo ";"
    echo "-- rows: $N_ROWS · functions: $N_FUNCTIONS · languages: $N_LANGUAGES"
} > "$tmp"

# Syntax/semantic self-check: the seed must load into an empty DB and yield
# exactly the exported row count.
LOADED=$({ cat "$tmp"; echo "SELECT COUNT(*) FROM DesignFunctionNames;"; } \
         | "$DUCKDB_BIN" -noheader -list 2>&1 | tail -1)
if [ "$LOADED" != "$N_ROWS" ]; then
    echo "ERROR: generated seed does not load cleanly (got '$LOADED', expected $N_ROWS rows)." >&2
    exit 3
fi

# --- write / check -------------------------------------------------------------
if $CHECK_MODE; then
    if [ ! -f "$OUT" ]; then
        echo "STALE: seed missing: $OUT — run ingestion/gen_design_functions.sh" >&2
        exit 2
    fi
    if cmp -s "$tmp" "$OUT"; then
        echo "fresh: $OUT (rows=$N_ROWS functions=$N_FUNCTIONS languages=$N_LANGUAGES, fm_spec $META_SCHEMA/$META_COMMIT)"
        exit 0
    fi
    echo "STALE: $OUT differs from the reference DB ($SPEC, fm_spec $META_SCHEMA/$META_COMMIT) — run ingestion/gen_design_functions.sh" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT")"
if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
    echo "unchanged: $OUT (rows=$N_ROWS functions=$N_FUNCTIONS languages=$N_LANGUAGES)"
    exit 0
fi
cp "$tmp" "$OUT"
echo "written: $OUT (rows=$N_ROWS functions=$N_FUNCTIONS languages=$N_LANGUAGES, fm_spec $META_SCHEMA/$META_COMMIT)"
exit 0
