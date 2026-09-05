# split_fm_xml.awk — zerteilt eine VORVERARBEITETE FileMaker-SaXML-Datei
# (UTF-8, CR→DEL bereits angewandt) in chunk-Dateien, um den Spitzen-DOM-Speicher
# bei Phase 1 zu senken.
#
# STRATEGIE (Diversions-Modell):
#   Die in der `separate`-Liste genannten Top-Level-Branches werden in EIGENE
#   Chunk-Dateien ausgelagert; der gesamte Rest bleibt im "main"-Chunk.
#   - mode=coarse (Default): separate = "StepsForScripts DDR_INFO" — die beiden
#     schwersten, branch-unabhängigen Sektionen; alle Kataloge bleiben in main.
#   - mode=fine (opt-in): separate += "LayoutCatalog FieldsForTables ThemeCatalog" —
#     die schweren, GUARD-FREIEN Kataloge (Gruppe B, eindeutiger record_element-Name;
#     empirisch spurios-frei, siehe I3.1). Senkt main weiter, ändert aber den
#     RAM-PEAK kaum, wenn ein einzelner Katalog (i.d.R. LayoutCatalog) dominiert —
#     der Peak wird dann vom größten Einzelkatalog gesetzt, nicht von main.
#
#   Warum NICHT jeden Katalog separieren? webbeds typisiertes
#   `read_xml(root_element='X', record_element='Y')` matcht den record_element
#   GLOBAL, wenn X im Chunk fehlt — z.B. liefert `record_element='ValueList'` dann
#   ValueList-Zugriffsregeln aus PrivilegeSetsCatalog und überschreibt per UPSERT die
#   echten OptionsForValueLists-Zeilen. I3.1 hat das empirisch eingegrenzt: nur
#   OptionsForValueLists leckt Zeilen, die das WHERE überleben (4 Spurios-Zeilen);
#   die schweren Kataloge der fine-Liste sind alle guard-frei. Solange diese drei
#   und die coarse-Branches separiert werden, bleibt das Ergebnis bit-identisch.
#
# PERFORMANCE: Branches werden ZEILENWEISE direkt in die Chunk-Datei gestreamt.
#   (Frühere Versionen pufferten via `buf = buf $0` — String-Konkatenation ist in
#   awk O(n²) und ließ den Splitter auf großen Branches, z.B. einem ~23-MB-
#   StepsForScripts / ~39-MB-LayoutCatalog, praktisch hängen. Auf der kleinen
#   Test-Datei (3,7 MB) war der Effekt mit 2,8 s noch tolerierbar, auf 80 MB nicht
#   mehr. Streaming ist O(n) und auf der Test-Datei coarse bit-identisch zum
#   Puffer-Verfahren.)
#
# Robustheit: FileMaker rückt strukturell mit TABs ein; nach dem Preprocessing liegt
# jeder Calc-CDATA auf EINER LF-Zeile (interne Umbrüche sind DEL), daher beginnt keine
# Inhaltszeile mit exakt n führenden Tabs gefolgt von '<'. Die Branch-Marker sind so
# eindeutig. Das Structure/AddAction-Wrapping richtet sich nach der GEMESSENEN
# Einrücktiefe (t==3 ⇒ Tiefe-3-Katalog), nicht nach dem Namen — robust auch wenn ein
# Katalog unter ModifyAction/ReplaceAction statt AddAction steht (Exploder-Befund D).
# Vollständigkeit (jede Quellzeile genau einem Chunk) sichert der Abnahmetest
# (gesplittet == ungesplittet) im aufrufenden Skript.
#
# SUB-CHUNKING:
#   Optional werden die SCHWERSTEN separierten Branches zusätzlich INNERHALB des
#   Branches in Stücke von je `subchunk` Records geschnitten — der Peak-DOM-Speicher
#   eines Branches sinkt damit auf ≈ Branchgröße / (Records / subchunk). Jeder
#   Sub-Chunk bleibt ein eigenständiges <FMSaveAsXML>-Dokument MIT vollständiger
#   Branch-/Katalog-Hülle (zwingend für webbeds root_element-Scoping). Die
#   Record-Grenze wird NAMENS-AWARE auf Branch-Tiefe+1 erkannt (recmap: Branch→
#   Record-Element) — Tab-Tiefe ALLEIN genügt nicht, weil manche Kataloge führende
#   Nicht-Record-Geschwister auf derselben Tiefe tragen (LayoutCatalog: <UUID>,
#   <TagList> vor den <Layout>-Records). Korrektheit ist UPSERT-additiv (Records
#   per UUID, reihenfolge-unabhängig); Branches OHNE recmap-Eintrag werden wie
#   bisher nur separiert (kein Sub-Chunk). Verifiziert via Tabellenvergleich
#   gesplittet-mit-Sub-Chunk == gesplittet-ohne (bit-identisch außer FilesCatalog.
#   XML_Path = letzter Chunk-Name + Import_Timestamp — beide variieren bereits beim
#   normalen --split, kein NEUER Divergenzpunkt).
#
#   NICHT sub-chunkbar (empirisch ermittelt — NICHT in recmap aufnehmen):
#   - LayoutCatalog (→Layouts) und ScriptCatalog: ihre Records tragen
#     Sequence_ID = ROW_NUMBER() OVER () in XML-Reihenfolge (KRITISCH für die
#     Folder-Hierarchie). read_xml numeriert jeden Sub-Chunk ab 1 → die globale
#     Sequenz zerbricht (688-Zeilen-Divergenz in Layouts gemessen). LayoutCatalog ist
#     dennoch sub-chunkbar, weil extract.sql den seq_offset aus der Chunkmap addiert.
#   Sicher & sinnvoll: StepsForScripts (schwerster separierter Branch, coarse-
#   Default; Records = <Script> auf Tiefe 4, keine Positionsspalte).
#
#   DDR-2-EBENEN-SUBCHUNK (Tier 2): die NEST-Kinder DDR_INFO →
#   Calculation/Script sind sub-chunkbar, OBWOHL ihre Records anonyme UUID-Tag-Namen
#   tragen — der namens-agnostische Anker sc_rec="*" (is_record_open) erkennt jedes
#   Element-Open auf Record-Tiefe (Child→ObjectList→_<UUID>, Tiefe Kind+2). Die Records
#   sitzen 2 Ebenen unter der NEST-Kindzeile, daher rekonstruiert sc_open_next/
#   sc_close_current einen 2-Ebenen-Wrapper (<Parent><Child><ObjectList> …). Identität
#   ist trivial gesichert: DDR_Calculations/DDR_ScriptSteps haben KEINE globale
#   Sequence-Spalte (PK Calc_UUID/Step_UUID, Chunk_Index record-lokal) → kein seq_offset,
#   UPSERT additiv. Aktivierung via recmap "Calculation:*:M Script:*:M".
#
# Usage: awk -v outdir=DIR [-v mode=coarse|fine] [-v separate="..."]
#            [-v subchunk=M] [-v recmap="Branch:RecElem ..."] -f split_fm_xml.awk < cleaned.xml
#        Schreibt outdir/chunk_000_main.xml + je outdir/chunk_NNN_<branch>.xml.
#        Gibt die Zahl erzeugter Chunks auf stdout aus.

# Zustand + Routing leben seit A-W1-Fortsetzung (Paket 2) in katana_common.awk
# (split_init/route_line/chunkmap_flush/eof_check) — der Splitter ist nur noch
# der dünne Treiber um den gemeinsamen Kern (identisch vom Fuse konsumiert).
BEGIN { split_init() }

{
    line = $0
    # Übergroße Binär-Blobs (<Stream>-Payload) leeren, BEVOR die Zeile nach main
    # geroutet wird — sonst sprengt ein >10-MB-Text-Node den main-Chunk-Parse.
    binstrip_line()
    # Root-Tag + optionale XML-Deklaration merken (für die Branch-Skelette);
    # beide Zeilen laufen unverändert weiter nach main (route_line Zweig 4).
    if (line ~ /^<\?xml/)           xmldecl = line
    if (line ~ /^<FMSaveAsXML[ >]/) root = line
    route_line()
}

END {
    print n
    # Chunkmap-Sidecar (Turbo, Phase S): seq_offset = split_number×sub_m
    # berechnet der Harness beim Laden.
    chunkmap_flush()
    eof_check("split_fm_xml.awk")   # A-K5: abgeschnittene Eingabe diagnostizierbar machen
}
