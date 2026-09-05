# streamify_fm_xml.awk — branch-bewusstes Element-Renaming für den --streamify-Pfad
# der XML-Konvertierung (Hybrid-Modell).
#
# ZWECK
#   Die `read_xml_objects`-Schwergewichte (LayoutObjects, StepsForScripts, …) lesen
#   heute das GANZE Dokument als DOM (RAM-Blowup). Um sie per webbed-SAX-Streaming zu
#   lesen, braucht read_xml(record_element=…) einen EINDEUTIGEN Anker — generische
#   Namen wie `Layout`/`Script` matchen sonst dokumentweit (z. B.
#   record_element='Layout' → 51 statt 14). Dieser Filter benennt die Wiederhol-
#   Elemente NUR innerhalb ihres Ziel-Branches eindeutig um (z. B. LayoutCatalog>Layout
#   → LC_Layout), sodass `record_element='LC_Layout'` exakt die echten Records trifft.
#
# EIGENSCHAFTEN
#   - ZEILEN-STREAMEND, O(n) konstanter Speicher (kein XML-Parser/DOM) — wie
#     tools/split_fm_xml.awk. Setzt dessen Vorverarbeitung voraus (UTF-8, CR→DEL,
#     ein Struktur-Element pro Zeile, TAB-Einrückung nach Tiefe).
#   - BRANCH-BEWUSST: ein Element wird nur umbenannt, wenn sein Ziel-Branch gerade
#     offen ist (Flag, gesetzt bei <Branch …> auf dessen Tiefe, gelöscht bei </Branch>
#     auf derselben Tiefe). Branches verschachteln sich nicht in sich selbst.
#   - PRÄZISE BOUNDARIES: `<Name[ >]` / `</Name>` — `<Layout` matcht NICHT
#     `<LayoutObject`/`<LayoutThemeReference` (dort folgt 'O'/'T'/'R', nicht ' '/'>').
#   - SURGICAL: alle übrigen Bytes bleiben unverändert (Roh-Captures, andere Branches).
#
# REGELN
#   -v rules="Branch:Element:NewName[, …]"  (kommagetrennt). Default unten = alle
#   aktuell unterstützten Schwergewicht-Anker. Beispiel:
#     "LayoutCatalog:Layout:LC_Layout"
#
# Usage: awk -v rules="LayoutCatalog:Layout:LC_Layout" -f streamify_fm_xml.awk < in.xml > out.xml

# Regel-Parsing + Rename leben seit A-W1-Fortsetzung (Paket 2) in
# katana_common.awk (parse_rules/rename_line) — identisch vom Fuse konsumiert.
# A-K2 ist dort gelöst: umbenannt wird nur das Struktur-Tag am Zeilenanfang,
# nie roher CDATA-Inhalt.
BEGIN {
    if (rules == "")
        rules = "LayoutCatalog:Layout:LC_Layout"
    parse_rules(rules, "streamify_fm_xml.awk")
}

{
    line = $0
    # Übergroße Binär-Blobs (<Stream>-Payload) leeren, damit der nachgelagerte
    # (SAX-)Parser nicht am Text-Node-Limit scheitert. No-Op für Nicht-Blob-Zeilen.
    binstrip_line()
    rename_line()
    print line
}
