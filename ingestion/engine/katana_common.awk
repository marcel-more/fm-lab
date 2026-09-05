# katana_common.awk — gemeinsame Kernfunktionen der Katana-Engine (A-W1).
#
# Diese Funktionen lebten zuvor DREIFACH dupliziert in split_fm_xml.awk,
# streamify_fm_xml.awk und turbo_phaseS_fuse.awk („identisch zu …"-Kommentare)
# und drifteten real auseinander (A-K3/A-K4 waren Divergenz-Folgen). Jetzt EINE
# Quelle; die Aufrufer laden sie per Mehrfach-`-f` (POSIX-konform):
#     awk -f katana_common.awk -f <spezifisch>.awk
# awk-Funktionen binden Globals zur Laufzeit — die referenzierten Zustände
# (sc_rec, sc_recdepth, sc_sn, branch_open, …) definieren die Aufrufer in BEGIN
# (bzw. split_init()). mawk-kompatibel; Aufruf-Disziplin LC_ALL=C wie in allen
# Katana-Passes.
#
# Seit A-W1-Fortsetzung (Paket 2) leben hier auch die vormals duplizierten
# HAUPTSCHLEIFEN-Bausteine — alle operieren auf dem globalen `line`:
#   parse_rules()/rename_line()  Streamify-Rename (Renamer + Fuse)
#   split_init()/route_line()    Splitter-Zustand + Diversions-Routing (Splitter + Fuse)
#   chunkmap_flush()/eof_check() END-Bausteine (Splitter + Fuse)

# Tiefe (führende Tabs) der aktuellen Zeile bestimmen.
function depth_of(line,   d) { d = 0; while (substr(line, d + 1, 1) == "\t") d++; return d }

# Übergroße eingebettete Binär-Payload auf `line` neutralisieren. FileMaker legt
# Container-Bilder als Base64-/Hex-Blob in EIN einzeiliges Element
# <Stream …>PAYLOAD</Stream> (unter <BinaryData>) ab. Eine Payload jenseits des
# Text-Node-Limits des XML-Parsers (~10 MB in libxml2) sprengt das Parsen des
# gesamten Chunks; da der Blob in den main-Chunk geroutet wird, reißt das den
# kompletten Datei-Import mit (irreführende NOT-NULL-Folgekaskade, weil das
# Wurzel-Attribut-Objekt nie entsteht). Wir entfernen NUR die Roh-Payload; das
# Element und seine Attribute bleiben unverändert — die Objekt-Analyse braucht die
# Bytes nie (nur die LibraryReference-Schlüssel), daher ist sie unberührt. No-Op
# bei Payloads bis `binmax` Bytes (Default 1 MB) → Blob-freie Korpora bleiben
# byte-identisch. binmax=0 schaltet den Schnitt ab. Voraussetzung (vom Preprocessing
# erfüllt): ein Struktur-Element pro Zeile, TAB-Einrückung nach Tiefe.
function binstrip_line(   cap, endpos, tagend, plen) {
    cap = (binmax == "" ? 1048576 : binmax + 0)
    if (cap <= 0) return
    if (line !~ /^\t*<Stream[ >]/) return            # nur ein <Stream>-Element trägt einen Blob
    endpos = index(line, "</Stream>")
    if (endpos == 0) return                          # self-closing / keine Payload
    tagend = index(line, ">")                        # Ende des Öffnungs-Tags <Stream …>
    if (tagend == 0 || tagend >= endpos) return
    plen = endpos - tagend - 1                        # Payload-Länge in Bytes
    if (plen <= cap) return                          # kleine Payload → verbatim behalten (Identität)
    line = substr(line, 1, tagend) "[binary-payload-stripped:" plen "B]" substr(line, endpos)
}

# Chunkmap-Eintrag anlegen (No-Op ohne chunkmap-Sidecar). Setzt cur_entry auf den
# neuen Eintrag, damit ein späteres record_count-Update den richtigen Chunk trifft.
function rec_entry(cat, sn, sm, fn) {
    if (chunkmap == "") return
    ne++
    E_cat[ne] = cat; E_sn[ne] = sn; E_sm[ne] = sm; E_fn[ne] = fn; E_rc[ne] = 0
    cur_entry = ne
}

# Globaler Vorkommen-Index (0-basiert) je Katalog; pro Chunk dieses Katalogs +1.
function next_sn(tag,   v) { v = (tag in SN ? SN[tag] : 0); SN[tag] = v + 1; return v }

# Ist `line` die Öffnungszeile eines Sub-Chunk-Records (Element sc_rec auf exakt
# sc_recdepth Tabs)? Namens-aware, damit Nicht-Record-Geschwister gleicher Tiefe
# (z.B. <UUID>, <TagList>) keine Grenze auslösen.
function is_record_open(line,   i, rest) {
    i = 0; while (substr(line, i + 1, 1) == "\t") i++
    if (i != sc_recdepth) return 0
    rest = substr(line, i + 1)
    # Namens-agnostischer Modus (Tier 2, sc_rec=="*"): JEDES Element-Open-Tag auf
    # Record-Tiefe ist eine Record-Grenze (nicht aber ein Close-Tag </…> — '/' ∉ [A-Za-z_]).
    # Sicher NUR dort, wo es keine Nicht-Record-Geschwister gibt (DDR ObjectList: alle Kinder
    # sind _<UUID>-Records, B.1-verifiziert). sc_recdepth-Filter schließt die tieferen
    # Record-Kinder (≥ sc_recdepth+1 Tabs) und den ObjectList-Close (sc_recdepth−1) aus.
    if (sc_rec == "*") return (rest ~ /^<[A-Za-z_]/)
    return (rest ~ ("^<" sc_rec "([ >/\t]|$)"))
}

# DDR-2-Ebenen-Wrapper: erfasst die Record-Parent-Zeile (ObjectList, Tiefe sc_recdepth−1)
# beim ersten Auftreten und baut die Open-/Close-Skelettblöcke (Parent → Child → ObjectList
# bzw. die drei zugehörigen Closes). Self-closing ObjectList (keine Records) wird ignoriert
# — dann findet ohnehin keine Rotation statt und die Blöcke bleiben ungenutzt.
function sc_prime_capture(line,   pd, prest, rptag, rppad) {
    pd = 0; while (substr(line, pd + 1, 1) == "\t") pd++
    if (pd != sc_recdepth - 1) return
    prest = substr(line, pd + 1)
    if (prest !~ /^<[A-Za-z_]/ || prest ~ /\/>[ \t]*$/) return
    rptag = prest; sub(/^</, "", rptag); sub(/[ >\/\t].*/, "", rptag)
    rppad = substr(line, 1, pd)
    sc_nest_open_block  = sc_p_open "\n" sc_c_open "\n" line
    sc_nest_close_block = rppad "</" rptag ">\n" sc_c_close "\n" sc_p_close
    sc_prime = 0
}

# Aktuellen Sub-Chunk schließen (synthetische Branch-/Wrap-/Root-Closes).
function sc_close_current() {
    if (chunkmap != "") E_rc[cur_entry] = sc_count   # Records dieses Sub-Chunks festhalten
    if (sc_nest2) {                                  # DDR: </ObjectList></Child></Parent>
        print sc_nest_close_block > curfile
        print "</FMSaveAsXML>" > curfile
        close(curfile)
        return
    }
    print sc_pad "</" sc_tag ">" > curfile
    if (sc_depth3) { print "\t\t</AddAction>" > curfile; print "\t</Structure>" > curfile }
    else if (sc_nestwrap) { print sc_nestwrap_close > curfile }
    print "</FMSaveAsXML>" > curfile
    close(curfile)
}

# Neuen Sub-Chunk eröffnen (Skelett: xmldecl + root + Wrap + Original-Branchzeile).
function sc_open_next() {
    n++
    curfile = sprintf("%s/chunk_%03d_%s.xml", outdir, n, sc_tag)
    rec_entry(sc_tag, next_sn(sc_tag), sc_M, sprintf("chunk_%03d_%s.xml", n, sc_tag))
    if (xmldecl != "") print xmldecl > curfile
    print root > curfile
    if (sc_nest2) {                                  # DDR: <Parent><Child><ObjectList>
        print sc_nest_open_block > curfile
        return
    }
    if (sc_depth3) { print "\t<Structure membercount=\"1\">" > curfile; print "\t\t<AddAction membercount=\"1\">" > curfile }
    else if (sc_nestwrap) { print sc_nestwrap_open > curfile }
    print sc_branchline > curfile
}

# ============================================================================
# Streamify-Rename (vormals dupliziert: streamify_fm_xml.awk-Hauptschleife ≙
# rename_line() im Fuse)
# ============================================================================

# Regel-String "Branch:Element:NewName[,…]" in die rule_*-Arrays parsen.
# Setzt das globale nrules; ungültige Regel = harter Abbruch (Exit 2).
function parse_rules(rulestr, progname,   nr_, i_, np_) {
    nrules = 0
    nr_ = split(rulestr, RUL_, ",")
    for (i_ = 1; i_ <= nr_; i_++) {
        gsub(/^[ \t]+|[ \t]+$/, "", RUL_[i_])
        if (RUL_[i_] == "") continue
        np_ = split(RUL_[i_], RP_, ":")
        if (np_ != 3) { print progname ": ungültige Streamify-Regel '" RUL_[i_] "'" > "/dev/stderr"; exit 2 }
        rule_branch[++nrules] = RP_[1]
        rule_elem[nrules]     = RP_[2]
        rule_new[nrules]      = RP_[3]
    }
}

# Branch-bewusstes Element-Renaming auf dem globalen `line`.
# A-K2 (kontext-sensitiv): umbenannt wird NUR das Struktur-Tag am Zeilenanfang
# (nach den Einrück-Tabs) — das frühere gsub über die ganze Zeile konnte rohe
# '<Elem'-Treffer in CDATA-Inhalt umschreiben (…<![CDATA[…<Layout …]]>…).
# Nach dem Preprocessing beginnt jedes Strukturelement am Zeilenanfang, und
# Attributwerte sind XML-escaped (&lt;) — rohes '<Elem' außerhalb des
# Zeilenanfangs existiert nur in CDATA. Einzeiler-Leafs (<Elem …>Text</Elem>)
# werden über den Trailing-Close-Zweig konsistent gehalten.
function rename_line(   d, i, b, e, nn, rest) {
    d = depth_of(line)
    # 1) Branch-CLOSE zuerst: deaktiviert das Flag, BEVOR auf dieser Zeile etwas
    #    umbenannt würde (die Close-Zeile selbst trägt keinen Record-Anker).
    for (i = 1; i <= nrules; i++) {
        b = rule_branch[i]
        if (branch_open[b] && d == branch_depth[b] && line ~ ("^\t*</" b ">[ \t]*$")) branch_open[b] = 0
    }
    # 2) Renaming für offene Branches (Open-/Close-Tag am Strukturanfang).
    for (i = 1; i <= nrules; i++) {
        b = rule_branch[i]
        if (!branch_open[b]) continue
        e = rule_elem[i]; nn = rule_new[i]
        rest = substr(line, d + 1)
        # awk-sub kennt KEINE Backreferences → Boundaries explizit (kein Capture).
        # "<Elem " (Attribute) matcht NICHT <ElemObject/<ElemTheme…; "<Elem>" ohne.
        if (sub("^<" e " ", "<" nn " ", rest) || sub("^<" e ">", "<" nn ">", rest)) {
            sub("</" e ">$", "</" nn ">", rest)   # Einzeiler-Leaf: trailing Close mit umbenennen
            line = substr(line, 1, d) rest
        } else if (sub("^</" e ">", "</" nn ">", rest)) {
            line = substr(line, 1, d) rest
        }
    }
    # 3) Branch-OPEN zuletzt: aktiviert das Flag für Folgezeilen (nicht die
    #    Branch-Zeile selbst). Self-closing Branch (<Branch …/>) und Einzeiler
    #    (<Branch …>…</Branch>) ignorieren.
    for (i = 1; i <= nrules; i++) {
        b = rule_branch[i]
        if (!branch_open[b] && line ~ ("^\t*<" b "[ >]") && line !~ /\/>[ \t]*$/ && line !~ ("</" b ">[ \t]*$")) {
            branch_open[b] = 1; branch_depth[b] = d
        }
    }
}

# ============================================================================
# Splitter-Kern (vormals dupliziert: split_fm_xml.awk-Hauptschleife ≙
# Split-Routing-Teil des Fuse)
# ============================================================================

# Splitter-Zustand aus den -v-Variablen (mode/separate/subchunk/recmap/nest/
# chunkmap/outdir) initialisieren — von BEGIN der Aufrufer gerufen.
function split_init(   k_, i_, j_, np_, rk_, ci_, nn_, cc_, em_, key_, p_, npar_, nrest_) {
    if (mode == "") mode = "coarse"
    if (separate == "") {
        if (mode == "fine")
            separate = "StepsForScripts DDR_INFO LayoutCatalog FieldsForTables ThemeCatalog"
        else
            separate = "StepsForScripts DDR_INFO"
    }
    k_ = split(separate, SA_, " ")
    for (i_ = 1; i_ <= k_; i_++) SEP[SA_[i_]] = 1
    # Sub-Chunk-Konfiguration: subchunk=M (0/leer = aus). recmap mappt Branch→
    # Record-Element; Eintrag "Branch:RecElem" ODER (Turbo, pro-Katalog-M)
    # "Branch:RecElem:M" — fehlt M, gilt das globale subchunk (rückwärtskompatibel).
    subchunk = (subchunk == "" ? 0 : subchunk + 0)
    if (recmap != "") {
        rk_ = split(recmap, RM_, " ")
        for (i_ = 1; i_ <= rk_; i_++) {
            np_ = split(RM_[i_], RMP_, ":")
            REC[RMP_[1]] = RMP_[2]
            if (np_ >= 3 && RMP_[3] != "") RECM[RMP_[1]] = RMP_[3] + 0
        }
    }
    # NEST: zerlegt einen Tiefe-1-Branch in seine Tiefe-2-Kinder,
    # jedes als eigener Chunk MIT Parent-Hülle (z.B. DDR_INFO → Calculation-Chunk +
    # Script-Chunk). Format: "Parent:Child1,Child2 …". Der Parent darf NICHT in SEP
    # stehen (sonst klassische 1-Chunk-Separierung) — unten defensiv entfernt.
    if (nest != "") {
        nn_ = split(nest, NG_, " ")
        for (i_ = 1; i_ <= nn_; i_++) {
            ci_ = index(NG_[i_], ":")
            if (ci_ < 2) continue
            npar_ = substr(NG_[i_], 1, ci_ - 1); nrest_ = substr(NG_[i_], ci_ + 1)
            NESTPAR[npar_] = 1
            cc_ = split(nrest_, NCH_, ",")
            for (j_ = 1; j_ <= cc_; j_++) if (NCH_[j_] != "") NESTOF[npar_ SUBSEP NCH_[j_]] = 1
        }
    }
    # Ein sub-chunkbarer Branch MUSS separiert sein, sonst erreicht er die Sub-Chunk-
    # Logik nie (sie sitzt im Branch-Start-Zweig, der nur bei tag in SEP feuert).
    # Effektives M je Branch = RECM[branch] (falls gesetzt) sonst globales subchunk.
    for (key_ in REC) {
        em_ = ((key_ in RECM) ? RECM[key_] : subchunk)
        if (em_ > 0) SEP[key_] = 1
    }
    for (p_ in NESTPAR) delete SEP[p_]
    main = sprintf("%s/chunk_000_main.xml", outdir)
    n = 1                      # main zählt als Chunk 0; Branch-Chunks ab 1
    root = ""; xmldecl = ""
    diverting = 0; curfile = ""; close_re = ""; depth3 = 0
    nestwrap = 0; nestwrap_close = ""
    nest_active = 0; nest_parent = ""; nest_ppad = ""; nest_close_re = ""
    sc_active = 0; sc_rec = ""; sc_recdepth = 0; sc_count = 0
    sc_branchline = ""; sc_pad = ""; sc_tag = ""; sc_M = 0
    sc_nestwrap = 0; sc_nestwrap_open = ""; sc_nestwrap_close = ""
    # DDR-2-Ebenen-Subchunk (Tier 2): Records eines NEST-Kindes liegen 2
    # Ebenen unter der Kindzeile (Child → ObjectList → _<UUID>).
    sc_nest2 = 0; sc_prime = 0; sc_nest_open_block = ""; sc_nest_close_block = ""
    sc_c_open = ""; sc_c_close = ""; sc_p_open = ""; sc_p_close = ""
    # Chunkmap-Sidecar (Turbo, Phase S): SN[tag] = GLOBALER Vorkommen-Index je
    # Katalog (0-basiert) = split_number → seq_offset = split_number×M. Zählt über
    # ALLE Chunks eines Katalogs (Sub-Chunks UND mehrfache Branch-Vorkommen) fort,
    # damit Sequence_IDs mehrfach auftretender Kataloge nicht kollidieren.
    ne = 0; cur_entry = 0
    if (chunkmap != "") rec_entry("main", 0, 0, "chunk_000_main.xml")
}

# Diversions-Routing der aktuellen Zeile (globales `line`): laufende Diversion →
# Branch-Chunk (mit Sub-Chunk-Rotation), NEST-Wartezustand → Kind-Chunks,
# Branch-Start → neue Diversion, sonst → main. Ein Aufruf verarbeitet die Zeile
# vollständig (Ersatz für die vormals duplizierten Pattern-Action-Blöcke).
function route_line(   ctag, cpad, sc_eff_m, sc_will, tag, t, j, pad, eff_m, will_sub, ct) {
    # --- (1) Innerhalb eines ausgelagerten Branches: Zeile direkt in den
    #     Branch-Chunk streamen (kein Puffer → O(n)). ---
    if (diverting) {
        # DDR-2-Ebenen-Subchunk: die erste Element-Open-Zeile auf Record-Tiefe−1
        # ist der Record-Parent (ObjectList); einmalig erfassen.
        if (sc_active && sc_prime) sc_prime_capture(line)
        # Sub-Chunk-Rotation an einer Record-Grenze, BEVOR die Zeile geschrieben
        # wird → der neue Record landet vollständig im neuen Chunk. Die echte
        # Branch-Close-Zeile löst KEINE Rotation aus (is_record_open namens-aware).
        if (sc_active && is_record_open(line)) {
            if (sc_count >= sc_M) { sc_close_current(); sc_open_next(); sc_count = 0 }
            sc_count++
        }
        print line > curfile
        if (line ~ close_re) {
            if (chunkmap != "" && sc_active) E_rc[cur_entry] = sc_count   # letzter Sub-Chunk
            if (depth3) { print "\t\t</AddAction>" > curfile; print "\t</Structure>" > curfile }
            else if (nestwrap) { print nestwrap_close > curfile }
            print "</FMSaveAsXML>" > curfile
            close(curfile)
            diverting = 0; curfile = ""; sc_active = 0; sc_nest2 = 0; sc_prime = 0
            nestwrap = 0   # nach NEST-Kind zurück in den Parent-Wartezustand
        }
        return
    }

    # --- (2) NEST-Parent-Wartezustand (Tier 1): zwischen den Tiefe-2-
    #     Kindern eines zerlegten Tiefe-1-Parents (DDR_INFO). ---
    if (nest_active) {
        if (line ~ nest_close_re) { nest_active = 0; return }   # synthetischer Parent-Close: verwerfen
        if (line ~ /^\t\t<[A-Za-z_][A-Za-z0-9_]*/) {
            ctag = line; sub(/^\t+</, "", ctag); sub(/[ >\/].*/, "", ctag)
            if ((nest_parent SUBSEP ctag) in NESTOF) {
                cpad = "\t\t"
                n++
                curfile = sprintf("%s/chunk_%03d_%s.xml", outdir, n, ctag)
                # Effektives Sub-Chunk-M dieses NEST-Kindes (recmap Calculation:*:M /
                # Script:*:M); fehlt M, gilt das globale subchunk.
                sc_eff_m = ((ctag in RECM) ? RECM[ctag] : subchunk)
                sc_will = (sc_eff_m > 0 && (ctag in REC))
                rec_entry(ctag, next_sn(ctag), (sc_will ? sc_eff_m : 0), sprintf("chunk_%03d_%s.xml", n, ctag))
                if (xmldecl != "") print xmldecl > curfile
                print root > curfile
                print nest_ppad "<" nest_parent ">" > curfile   # Parent-Hülle, z.B. "\t<DDR_INFO>"
                print line > curfile
                depth3 = 0; nestwrap = 1; nestwrap_close = nest_ppad "</" nest_parent ">"
                # Self-closing Kind ODER Einzeiler <Kind …>…</Kind> (A-K4: Open+Close
                # auf EINER Zeile — close_re würde nie matchen → Fehl-Diversion bis EOF).
                if (line ~ /\/>[ \t]*$/ || line ~ ("</" ctag ">[ \t]*$")) {
                    print nestwrap_close > curfile
                    print "</FMSaveAsXML>" > curfile
                    close(curfile); curfile = ""; nestwrap = 0
                    return
                }
                close_re = "^" cpad "</" ctag ">[ \t]*$"
                diverting = 1
                # Tier 2 — DDR-ObjectList-Sub-Chunking: Records 2 Ebenen unter der
                # Kindzeile, sc_recdepth=Kind+2, Record-Parent via sc_prime_capture.
                # Keine Sequence-Spalte → kein seq_offset, UPSERT additiv.
                if (sc_will) {
                    ct = 0; while (substr(line, ct + 1, 1) == "\t") ct++
                    sc_active = 1; sc_nest2 = 1; sc_prime = 1
                    sc_tag = ctag; sc_rec = REC[ctag]
                    sc_recdepth = ct + 2; sc_count = 0; sc_M = sc_eff_m
                    sc_p_open = nest_ppad "<" nest_parent ">"; sc_p_close = nest_ppad "</" nest_parent ">"
                    sc_c_open = line; sc_c_close = cpad "</" ctag ">"
                } else {
                    sc_active = 0; sc_nest2 = 0
                }
                return
            }
        }
        # Sonstige Zeile direkt unter dem Parent — bei DDR_INFO existiert keine
        # (B.1-verifiziert). Defensiv nach main, damit keine Quellzeile verloren geht.
        print line > main
        return
    }

    # --- (3) Branch-Start erkennen: <Name …> an Tiefe-1- ODER Tiefe-3-Position,
    #     sofern Name in der separate-Liste steht. ---
    if (line ~ /^\t(\t\t)?<[A-Za-z_][A-Za-z0-9_]*/) {
        tag = line
        sub(/^\t+</, "", tag); sub(/[ >\/].*/, "", tag)
        # NEST-Parent: Tiefe-1-Branch in Tiefe-2-Kinder zerlegen statt 1 Chunk.
        # Die Parent-Open-Zeile wird verworfen (je Kind als Hülle neu gebaut).
        if (tag in NESTPAR) {
            if (line ~ /\/>[ \t]*$/) return              # leerer/self-closing Parent
            t = 0; while (substr(line, t + 1, 1) == "\t") t++
            nest_ppad = ""; for (j = 0; j < t; j++) nest_ppad = nest_ppad "\t"
            nest_active = 1; nest_parent = tag
            nest_close_re = "^" nest_ppad "</" tag ">[ \t]*$"
            return
        }
        if (tag in SEP) {
            t = 0; while (substr(line, t + 1, 1) == "\t") t++
            pad = ""; for (j = 0; j < t; j++) pad = pad "\t"
            depth3 = (t == 3); nestwrap = 0   # normaler Branch nutzt nie die NEST-Hülle
            # Branch-Chunk eröffnen: eigenständiges <FMSaveAsXML>-Dokument mit
            # Original-Root; Tiefe-3-Kataloge in <Structure><AddAction> gewrappt.
            n++
            curfile = sprintf("%s/chunk_%03d_%s.xml", outdir, n, tag)
            eff_m = ((tag in RECM) ? RECM[tag] : subchunk)
            will_sub = (eff_m > 0 && (tag in REC))
            rec_entry(tag, next_sn(tag), (will_sub ? eff_m : 0), sprintf("chunk_%03d_%s.xml", n, tag))
            if (xmldecl != "") print xmldecl > curfile
            print root > curfile
            if (depth3) { print "\t<Structure membercount=\"1\">" > curfile; print "\t\t<AddAction membercount=\"1\">" > curfile }
            print line > curfile
            # Self-closing Branch ODER Einzeiler <X …>…</X> (A-K4: der Close liegt
            # auf DERSELBEN Zeile — close_re matcht nie → Fehl-Diversion bis EOF).
            if (line ~ /\/>[ \t]*$/ || line ~ ("</" tag ">[ \t]*$")) {
                if (depth3) { print "\t\t</AddAction>" > curfile; print "\t</Structure>" > curfile }
                print "</FMSaveAsXML>" > curfile
                close(curfile); curfile = ""
                return
            }
            close_re = "^" pad "</" tag ">[ \t]*$"
            diverting = 1
            # Sub-Chunking scharfschalten (nur bei recmap-Eintrag + effektivem M>0).
            if (will_sub) {
                sc_active = 1; sc_tag = tag; sc_rec = REC[tag]
                sc_recdepth = t + 1; sc_count = 0; sc_M = eff_m
                sc_branchline = line; sc_pad = pad; sc_depth3 = depth3; sc_nestwrap = 0
            } else {
                sc_active = 0
            }
            return
        }
    }

    # --- (4) alle übrigen Zeilen → main-Chunk (verbatim) ---
    print line > main
}

# Chunkmap-Sidecar am END schreiben: eine TSV-Zeile je Chunk in Erzeugungs-
# Reihenfolge (main zuerst): catalog, split_number, record_count, sub_m, chunk_file.
function chunkmap_flush(   i_) {
    if (chunkmap == "") return
    for (i_ = 1; i_ <= ne; i_++)
        printf "%s\t%d\t%d\t%d\t%s\n", E_cat[i_], E_sn[i_], E_rc[i_], E_sm[i_], E_fn[i_] > chunkmap
    close(chunkmap)
}

# A-K5: EOF innerhalb einer offenen Diversion / eines NEST-Wartezustands =
# abgeschnittene Eingabe (Branch-Close nie erreicht) — der betroffene Chunk ist
# unvollständig (synthetische Closes fehlen) und scheitert downstream am Parser.
# Warnung (kein Abbruch): der Zähler-Output bleibt gültig, die Diagnose wird lesbar.
function eof_check(progname) {
    if (diverting)
        print progname ": WARNUNG: EOF innerhalb offener Diversion (erwarteter Branch-Close '" close_re "' nie erreicht — Eingabe abgeschnitten?). Chunk-Datei " curfile " ist unvollständig." > "/dev/stderr"
    if (nest_active)
        print progname ": WARNUNG: EOF im NEST-Wartezustand (Parent '" nest_parent "' nie geschlossen — Eingabe abgeschnitten?)." > "/dev/stderr"
}
