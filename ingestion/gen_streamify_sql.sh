#!/bin/bash
# gen_streamify_sql.sh — generiert die streamify-Variante der Phase-1-SQL aus der
# Basis (Hybrid-Modell, DRY).
#
# Die streamify-Variante unterscheidet sich von der Basis NUR an den Stellen, die
# auf die vom Renamer (ingestion/engine/streamify_fm_xml.awk) eindeutig gemachten Schwergewicht-
# Anker zugreifen. Zwei Transformationsarten:
#
#   (A) RENAME-Regeln (sed): Reads, die einen umbenannten Anker konsumieren, müssen
#       den neuen Namen verwenden. Transparent (DOM-Extraktion unverändert):
#         - typisierter Layouts-Read:  record_element='Layout'  → 'LC_Layout'
#         - read_xml_objects-xpaths:   //LayoutCatalog/Layout   → //LayoutCatalog/LC_Layout
#       (LayoutParts, LayoutObjects, ScriptTriggers-Layout-Level)
#
#   (B) BLOCK-SWAPS (Sentinel): Reads, die auf SAX-Streaming umgestellt sind
#       (read_xml_objects → read_xml(record_element=…)). Basis markiert den Block mit
#         -- @STREAMIFY_BLOCK:<name>@ … -- @END_STREAMIFY_BLOCK@
#       und ingestion/sql/streamify/<name>.sql liefert die Streaming-Fassung. (Noch keine aktiv;
#       werden inkrementell + je einzeln bit-identisch abgenommen ergänzt.)
#
# Die Sentinels/Marker sind SQL-Kommentare → die Basis läuft im Default-Pfad
# unverändert (DOM). Nur diese Generierung erzeugt die streamify-Datei.
#
# Usage: ingestion/gen_streamify_sql.sh            → Generat schreiben
#        ingestion/gen_streamify_sql.sh --check    → Freshness-Gate: regenerieren nach
#                                                mktemp + cmp gegen das committete
#                                                Generat; Diff → Exit 2 (nichts wird
#                                                geschrieben). Wird vom Treiber
#                                                (convert_fm_xml.sh) vor --streamify
#                                                aufgerufen.
#
# Exit-code contract (policy-lock E4) — the driver's adaptive default reads it:
#   0 = fresh · 2 = generate stale/missing (genuine, incl. missing base SQL) ·
#   3 = base pattern drift (genuine) · 4 = infrastructure (mktemp/cmp unusable —
#   NOT a staleness verdict). Genuine states (2/3) keep the DOM fallback; 4 and
#   any unexpected rc are sticky candidates (the caller may keep the last
#   successfully used policy instead of flipping SAX→DOM on a transient error).
set -euo pipefail

# Engine-Wurzel (ingestion/): alle Pfade engine-intern — das Verzeichnis ist
# self-contained und relozierbar.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$ROOT/sql/convert_xml_01_extract.sql"
OUT="$ROOT/sql/convert_xml_01_extract.streamify.sql"
OVERRIDE_DIR="$ROOT/sql/streamify"

CHECK_MODE=false
[ "${1:-}" = "--check" ] && CHECK_MODE=true

# Erwartete Treffer der Mehrzeilen-Transforms (A2). Die Muster sind zeilenlayout-
# abhängig — ein stiller 0-Treffer-Durchlauf würde ein DOM-Generat unter falschem
# Namen erzeugen. Ändert sich die Basis legitim (CTE kommt dazu/fällt weg), diese
# Werte BEWUSST mitziehen.
EXPECT_PS_CTE=4     # privilege_sets-CTE-Quellen (Pattern A)
EXPECT_PS_GUARD=3   # DELETE-Chunk-Guards (Pattern B, echter Guard)

# Fehlende Basis = 2er-Familie (echt „nicht bereit", kein Infra-Fall): der
# Treiber behandelt 2 wie „Generat stale/fehlt" → DOM-Fallback mit Grund.
[ -f "$BASE" ] || { echo "ERROR: Basis-SQL fehlt: $BASE"; exit 2; }

# Infra-Guards (rc 4): mktemp/cmp-Ausfälle sind KEIN Freshness-Befund. Ohne die
# Guards stürbe das Skript via `set -e` mit dem rc des fehlschlagenden Kommandos
# (mktemp: 1) bzw. cmp-127 fiele in den STALE-Zweig — beides würde beim Treiber
# fälschlich als „echt nicht bereit" ankommen und die Policy still auf DOM kippen.
if $CHECK_MODE && ! command -v cmp >/dev/null 2>&1; then
  echo "ERROR: cmp nicht verfügbar — Freshness-Gate nicht ausführbar (Infrastruktur)." >&2
  exit 4
fi
if ! tmp="$(mktemp "${TMPDIR:-/tmp}/fmlab.XXXXXX" 2>/dev/null)" || [ -z "$tmp" ]; then
  echo "ERROR: mktemp fehlgeschlagen (TMPDIR=${TMPDIR:-/tmp} nicht beschreibbar?) — Infrastruktur, kein Freshness-Befund." >&2
  exit 4
fi
trap 'rm -f "$tmp" "$tmp.2"' EXIT

# Kopf-Kommentar (kennzeichnet generierte Datei; NICHT von Hand editieren)
{
  echo "/* GENERIERT von ingestion/gen_streamify_sql.sh aus ingestion/sql/convert_xml_01_extract.sql"
  echo "   NICHT von Hand editieren — Änderungen in der Basis bzw. ingestion/sql/streamify/ vornehmen."
  echo "   (Hybrid: Renamer + streamify-SQL). */"
} > "$tmp"

# (A) RENAME-Regeln auf die Basis anwenden. Der Renamer benennt LayoutCatalog>Layout
#     → LC_Layout; daher müssen ALLE Reads, die diesen Anker konsumieren, konsistent
#     umbenannt werden — sowohl der Anker-Pfad (`//LayoutCatalog/Layout`) ALS AUCH
#     die fragment-relativen xpaths darauf (`'/Layout/…'`). `'/Layout/`-Anker (Quote)
#     trifft nur xpath-Literale, nicht `//LayoutCatalog/Layout` (endet auf Layout').
sed -e "s|record_element='Layout',|record_element='LC_Layout',|" \
    -e "s|//LayoutCatalog/Layout|//LayoutCatalog/LC_Layout|g" \
    -e "s|'/Layout/|'/LC_Layout/|g" \
    "$BASE" >> "$tmp"

# (A2) PrivilegeSet-Mehrzeilen-Transforms (DRY statt 4 duplizierter Overrides):
#   - die `privilege_sets`-CTE (4×) auf Streaming-Anker PrivilegeSetsCatalog +
#     ObjectList-VARCHAR-Capture umstellen (Downstream-/PrivilegeSet/…-xpaths
#     bleiben unverändert, da ps_xml weiterhin das ganze <PrivilegeSet> ist);
#   - den DELETE-Chunk-Guard (3×) von read_xml_objects auf streaming-EXISTS umstellen.
#   Beide Muster sind PrivilegeSet-spezifisch → globale Ersetzung ist sicher.
awk -v exp_cte="$EXPECT_PS_CTE" -v exp_guard="$EXPECT_PS_GUARD" '
  # Pattern A: privilege_sets-CTE-Quelle
  /unnest\(xml_extract_elements\(xml, '\''\/\/PrivilegeSetsCatalog\/ObjectList\/PrivilegeSet'\''\)\) as ps_xml/ {
    hits_cte++
    print "        unnest(xml_extract_elements('\''<ObjectList>'\'' || ObjectList || '\''</ObjectList>'\'', '\''/ObjectList/PrivilegeSet'\'')) as ps_xml"
    getline   # verwirft die folgende  FROM read_xml_objects(...)  Zeile
    print "    FROM read_xml(getvariable('\''fm_xml'\''), record_element='\''PrivilegeSetsCatalog'\'', maximum_file_size=getvariable('\''dom_threshold'\''), streaming=getvariable('\''use_streaming'\''), columns={'\''ObjectList'\'':'\''VARCHAR'\''})"
    print "    WHERE ObjectList IS NOT NULL"
    next
  }
  # Pattern B: DELETE-Chunk-Guard (5-Zeilen-Subquery → streaming-EXISTS).
  # WICHTIG: nur der ECHTE Guard (l2 = FMSaveAsXML/@File UND l5 = …//PrivilegeSetsCatalog…).
  # Der frühe FilesCatalog-Read nutzt ebenfalls regexp_replace(FMSaveAsXML/@File), hat
  # aber kein PrivilegeSetsCatalog-WHERE → bleibt unverändert.
  /SELECT regexp_replace\(/ {
    a1 = $0
    getline a2; getline a3; getline a4; getline a5
    if (a2 ~ /FMSaveAsXML\/@File/ && a5 ~ /\/\/PrivilegeSetsCatalog/) {
      hits_guard++
      print "    SELECT getvariable('\''fm_file'\'')"
      print "    WHERE EXISTS (SELECT 1 FROM read_xml(getvariable('\''fm_xml'\''), record_element='\''PrivilegeSetsCatalog'\'', maximum_file_size=getvariable('\''dom_threshold'\''), streaming=getvariable('\''use_streaming'\''), columns={'\''ObjectList'\'':'\''VARCHAR'\''}))"
    } else {
      print a1; print a2; print a3; print a4; print a5
    }
    next
  }
  { print }
  # Treffer-Zähler statt stillem Fallback: weicht die Basis vom erwarteten
  # Zeilenlayout ab, bricht die Generierung hart ab (kein DOM-Generat unter
  # streamify-Namen).
  END {
    if (hits_cte + 0 != exp_cte + 0 || hits_guard + 0 != exp_guard + 0) {
      printf "ERROR: PrivilegeSet-Transform-Treffer weichen ab: CTE %d/%d, Guard %d/%d.\n", hits_cte, exp_cte, hits_guard, exp_guard > "/dev/stderr"
      printf "       Basis-Zeilenlayout geändert? EXPECT_* in ingestion/gen_streamify_sql.sh bewusst nachziehen.\n" > "/dev/stderr"
      exit 3
    }
  }
' "$tmp" > "$tmp.2"
# WICHTIG: mv getrennt vom awk (kein `awk … && mv`): in einer &&-Liste würde
# set -e den awk-Exit-3 verschlucken — der harte Abbruch der Treffer-Zähler
# muss aber das ganze Skript beenden.
mv "$tmp.2" "$tmp"

# (B) BLOCK-SWAPS: für jeden Override ingestion/sql/streamify/<name>.sql den markierten
#     Basis-Block ersetzen. (awk: Zeilen zwischen den Markern verwerfen, Override
#     einfügen.) Aktiv, sobald Override-Dateien existieren.
if [ -d "$OVERRIDE_DIR" ]; then
  for ov in "$OVERRIDE_DIR"/*.sql; do
    [ -e "$ov" ] || continue
    name="$(basename "$ov" .sql)"
    awk -v name="$name" -v ovf="$ov" '
      $0 ~ ("@STREAMIFY_BLOCK:" name "@") {
        found = 1
        print "-- [streamify block: " name " — eingefügt von gen_streamify_sql.sh]"
        while ((getline l < ovf) > 0) print l
        close(ovf)
        skip = 1
        next
      }
      skip && $0 ~ /@END_STREAMIFY_BLOCK@/ { skip = 0; next }
      skip { next }
      { print }
      # Ein Override ohne Basis-Marker wäre bisher stillschweigend ignoriert worden
      # (Block fehlt im Generat) → harter Abbruch.
      END {
        if (!found) {
          printf "ERROR: Marker @STREAMIFY_BLOCK:%s@ nicht in der Basis gefunden (Override %s verwaist).\n", name, ovf > "/dev/stderr"
          exit 3
        }
        if (skip) {
          printf "ERROR: @END_STREAMIFY_BLOCK@ fehlt nach @STREAMIFY_BLOCK:%s@ — Basis-Block unbeendet.\n", name > "/dev/stderr"
          exit 3
        }
      }
    ' "$tmp" > "$tmp.2"
    mv "$tmp.2" "$tmp"
  done
fi

# Schema-Hash-Härtung: die streamify-
# Variante an ihren @SCHEMA_HASH_FILES-Header zusätzlich SICH SELBST + den Renamer
# anhängen. Die Override-Inhalte (ingestion/sql/streamify/*.sql) sind in diese Datei eingebacken,
# also deckt ihr Hash die Overrides mit ab; der Renamer wirkt auf den Input und kommt
# separat dazu. Die Rename-Logik lebt in
# katana_common.awk (parse_rules/rename_line) — die Common-Datei gehört daher mit
# ins Gate. Damit lösen Edits an Overrides/Renamer/Common/Generat einen Schema-
# Drift → Rebuild aus (im DOM-Pfad bleibt der Hash unverändert = nur Basis-Dateien).
# Pfade ENGINE-relativ (so wie read_template_schema_info gegen ENGINE_ROOT auflöst).
sed -e 's#^\(-- @SCHEMA_HASH_FILES .*\)$#\1 sql/convert_xml_01_extract.streamify.sql engine/streamify_fm_xml.awk engine/katana_common.awk#' \
    "$tmp" > "$tmp.2"
mv "$tmp.2" "$tmp"

if $CHECK_MODE; then
  # Freshness-Gate: Regenerat gegen das committete Generat vergleichen, nichts schreiben.
  if [ ! -f "$OUT" ]; then
    echo "ERROR: streamify-Generat fehlt: ${OUT#"$ROOT"/} (ingestion/gen_streamify_sql.sh ausführen + committen)." >&2
    exit 2
  fi
  if cmp -s "$tmp" "$OUT"; then
    echo "✓ streamify-SQL ist frisch (Generat == Regenerat)."
  else
    echo "ERROR: streamify-SQL ist STALE — ${OUT#"$ROOT"/} weicht vom Regenerat ab." >&2
    echo "       ingestion/gen_streamify_sql.sh ausführen und das Generat committen." >&2
    exit 2
  fi
else
  mv "$tmp" "$OUT"
  echo "✓ streamify-SQL generiert: ${OUT#"$ROOT"/}"
fi
