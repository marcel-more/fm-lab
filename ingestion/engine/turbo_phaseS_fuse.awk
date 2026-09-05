# turbo_phaseS_fuse.awk — FUSIONIERTER Phase-S-Pass (P2.1)
#
# Ersetzt im Turbo-Phase-S-Pfad die bisher GETRENNTEN Voll-Pässe
#   (1) Byte-Clean  (tr -d '\177' | tr '\r' '\177' | tr -d C0)      [preprocess_file]
#   (2) Report-Zähler (wc -c, tr -dc '\r', tr -dc '\177', wc -c)    [preprocess_file]
#   (3) Streamify-Element-Renaming                                  [streamify_fm_xml.awk]
#   (4) Splitter + Chunkmap-Sidecar                                 [split_fm_xml.awk]
# durch EINEN awk-Pass über den iconv-UTF-8-Stream. iconv bleibt als separater
# C-Pass davor (Encoding). Damit fällt Phase S von ~8 auf ~2 Pässe/Datei und die
# Zwischendatei-Round-Trips (_clean.xml schreiben → mv → wieder einlesen) entfallen.
#
# IDENTITÄT (hartes Gate): Output byte-identisch zur alten 3-Pass-Pipeline.
#   - Byte-Clean und die strukturellen Transforms (Rename/Split) sind ORTHOGONAL:
#     Clean berührt nur Steuerbytes (CR/DEL/C0) INNERHALB von CDATA-Inhalt, Rename/
#     Split nur die druckbare Markup-Struktur (<Tag>, TAB-Einrückung). Disjunkte
#     Byte-Klassen → die Reihenfolge clean→rename→split pro Zeile reproduziert exakt
#     die alte Pipeline-Reihenfolge.
#   - LF (0x0A) wird vom Clean NIE verändert (CR→DEL ist 0x0D→0x7F; C0-Strip schließt
#     0x0A/0x09 aus) → die Zeilengrenzen sind vor und nach dem Clean identisch, also
#     liefert per-Zeilen-Clean dasselbe wie der frühere Whole-Stream-`tr`.
#   - MUSS mit LC_ALL=C laufen (byte-transparent, kein Multibyte-Zerschneiden).
#
# Usage: LC_ALL=C awk -v outdir=DIR -v chunkmap=PFAD -v counts=PFAD \
#            [-v rules="Branch:Elem:New,…"] [-v mode=coarse|fine] [-v separate="…"] \
#            [-v subchunk=M] [-v recmap="Branch:RecElem[:M] …"] \
#            -f turbo_phaseS_fuse.awk < utf8_with_bom.xml
#   Schreibt outdir/chunk_000_main.xml + je outdir/chunk_NNN_<branch>.xml, die
#   Chunkmap-TSV nach `chunkmap`, die Zähler-TSV nach `counts`
#   (in_size, out_size, pre_cr, pre_del, pre_stripped) und gibt NCHUNKS auf stdout.
#
# Quellen der gemergten Logik (unverändert in Verhalten, nur fusioniert):
#   tools/split_fm_xml.awk      (Splitter + Chunkmap + Sub-Chunk)
#   tools/streamify_fm_xml.awk  (branch-bewusstes Rename)
#   preprocess_file()           (Byte-Clean + Zähler) in convert_fm_xml.sh

BEGIN {
    # chr(127)-Sentinel-Default: ohne -v ws_sentinel (z. B. Identitaets-Unit-Tests) = ON.
    # WICHTIG: ein uninitialisiertes awk-Skalar vergleicht sich GLEICH zu 0 → ohne dieses
    # BEGIN-Default wuerde `ws_sentinel != 0` faelschlich den Sentinel deaktivieren.
    if (ws_sentinel == "") ws_sentinel = 1; else ws_sentinel = ws_sentinel + 0

    # ---- Splitter- + Streamify-Init: gemeinsamer Kern (katana_common.awk) ----
    split_init()
    nrules = 0
    if (rules != "") parse_rules(rules, "turbo_phaseS_fuse.awk")

    # ---- Zähler-Init (ersetzt die 4 wc/tr-Pässe in preprocess_file) ----
    in_size = 0; out_size = 0; pre_cr = 0; pre_del = 0
}

# ===== Byte-Clean (ersetzt die tr-Pipeline in preprocess_file), operiert auf global `line` =====
# Reihenfolge wie preprocess_file: (c2) DEL-Guard strippen → (b) CR→DEL → (c) C0-Strip.
# Die drei Byte-Klassen sind disjunkt (0x7F ∉ C0-Set, 0x0D vor dem Strip in 0x7F gewandelt),
# daher byte-identisch zur alten 3-fach-`tr`-Kette. BOM-Strip nur auf Zeile 1.
function clean_line(   before) {
    if (NR == 1) sub(/^\357\273\277/, "", line)   # (d) UTF-8-BOM (EF BB BF) strippen
    before = length(line)
    pre_del += gsub(/\177/, "", line)              # (c2) DEL-Guard: 0x7F entfernen
    # (b) CR (0x0D) → DEL (0x7F) chr(127)-Sentinel — nur wenn ws_sentinel != 0.
    # ws_sentinel=0 (webbed bewahrt Whitespace nativ, per Probe): CR bleibt erhalten,
    # ueberlebt den C0-Strip (0x0D nicht im Set) und wird vom Parser zu LF normalisiert;
    # die SQL ws_restore wird dann zum No-op. Default (kein -v) = 1 (Sentinel ON).
    if (ws_sentinel != 0) pre_cr += gsub(/\r/, "\177", line)
    # (c) XML-1.0-invalide C0-Bytes. \000 MUSS das LETZTE Klassen-Element sein: steht
    # es vorn, degeneriert die Bracket-Expression im BWK awk (macOS /usr/bin/awk) zum
    # Leerstring-Match an jeder Position — gsub meldet dann Treffer (n>0), entfernt
    # aber kein einziges Byte, und der C0-Strip wird still zum No-op. mawk/gawk sind
    # mit beiden Reihenfolgen korrekt (cmp-identisch zur tr-Referenz in preprocess_file).
    gsub(/[\001-\010\013\014\016-\037\000]/, "", line)
    in_size  += before
    out_size += length(line)
}

# ===== Hauptblock: clean → (rename) → Split-Routing, alles auf `line` =====
# Rename + Routing sind der gemeinsame Kern (katana_common.awk: rename_line/
# route_line — identisch vom Renamer bzw. Splitter konsumiert); fuse-spezifisch
# bleibt nur der Byte-Clean + die Zähler.
{
    line = $0
    # Übergroße Binär-Blobs VOR dem Byte-Clean neutralisieren (spart den 4-fach-gsub
    # von clean_line über eine ggf. mehrere MB lange Base64-Zeile und hält sie aus dem
    # main-Chunk-Parse). No-Op für Nicht-Blob-Zeilen → byte-identisch für Blob-freie Korpora.
    binstrip_line()
    clean_line()
    if (nrules > 0) rename_line()

    # Root-Tag + optionale XML-Deklaration merken (für die Branch-Skelette)
    if (line ~ /^<\?xml/)           xmldecl = line
    if (line ~ /^<FMSaveAsXML[ >]/) root = line

    route_line()
}

END {
    print n
    chunkmap_flush()
    if (counts != "") {
        printf "%d\t%d\t%d\t%d\t%d\n", in_size, out_size, pre_cr, pre_del, (in_size - out_size) > counts
        close(counts)
    }
    eof_check("turbo_phaseS_fuse.awk")   # abgeschnittene Eingabe diagnostizierbar machen
}
