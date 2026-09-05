/*
-- convert_xml_01_extract.sql — Phase 1 der XML-Konvertierungs-Pipeline.
-- EINZIGE XML-lesende Phase: überführt die
-- Roh-Kataloge 1:1 aus der XML in DuckDB-Tabellen und speichert Roh-XML-
-- Fragmente (Parameters_XML, Object_XML, Step_XML, …) für die nachgelagerten
-- Phasen. Die Referenz-Auflösung liegt in convert_xml_02_resolve.sql (Phase 2).
-- Chunk-fähig: jede Sektion ist bei einem Chunk ohne ihren Katalog ein No-Op
-- (UPSERT bzw. branch-guarded DELETE bei PrivilegeSet*).
--
-- DuckDB SQL Script to parse FileMaker XML Catalog
-- and extract various catalog information into tables.

-- XML File must be converted to UTF-8 encoding beforehand!

-- Version 0.4
-- Date: 2026-01-14

-- Schema-Versionierung:
--   @SCHEMA_VERSION wird vom Shell-Skript per grep ausgewertet und gegen den
--   Wert in der DB-Tabelle SchemaInfo verglichen. Bei Mismatch löst der
--   Auto-Heal-Mechanismus einen Force-Rebuild aus.
--
--   @SCHEMA_HASH_FILES listet die SQL-Files, deren MD5-Summe als sekundärer
--   Drift-Indikator herangezogen wird (Pfade ENGINE-relativ, aufgelöst gegen
--   ingestion/). build_resolutions.sql bewusst NICHT enthalten, weil es nur
--   abgeleitete Tabellen anlegt. Ebenfalls bewusst NICHT enthalten: das
--   Generat sql/generated/design_functions_seed.sql (Seed des P1c-Retypes) —
--   sein Provenienz-Kopf ändert sich mit jedem Referenz-Pull, ohne dass sich
--   die Namensmenge ändert; das würde jeden bestehenden Katalog grundlos als
--   driftend melden. Die Retype-Logik selbst (convert_xml_01c_…) ist gelistet.

-- @SCHEMA_VERSION 1.27.0
-- @SCHEMA_VERSION_DATE 2026-09-02
-- @SCHEMA_CHANGELOG 1.27.0: Display-Calculation-Lücken (Merge-Familie): neue
--   P1-Tabelle DDR_ChunkListContexts (Kontext-TO + Chunk_Count je ChunkList-
--   Anker aus DDR_INFO, AUCH für leere ChunkLists — die tauchten bisher
--   nirgends auf) und neue P3-Tabelle LayoutObjectSymbols ({{…}}-Inventar aus
--   Text_Content, bewusst ohne Where-used-Kanten). CalculationsCatalog erhält
--   Result_Type (Ergebnistyp aus dem %X:-Präfix der Layoutformel, Default
--   Text); display_calculation-Instanzen bekommen Formula_Text (lokalisierte
--   Rohformel aus Text_Content) + Kontext-TO. Defekt-Kompensation FileMaker-
--   DDR: %X:-Fehlchunks (VariableReference statt FieldRef) erzeugen keine
--   Phantom-Variablen mehr, die Feldreferenz wird gegen die Kontext-TO
--   gerettet (P2 A.5.1b); leere DisplayCalculations-ChunkLists erhalten eine
--   Fallback-Instanz + Feldkanten aus Text_Content (P2 A.5.1c, P4 b_disp).
--   Neue Tabellen/Spalte → MINOR-Bump.
-- @SCHEMA_CHANGELOG 1.26.0: ScriptTriggers.Trigger_Parameter_Text (P1): neue
--   Spalte am Tabellenende — der strukturelle Klartext der Trigger-Parameter-
--   Berechnung (/ScriptTrigger/ScriptReference/Calculation/Text, CDATA-dekodiert
--   via xml_extract_text; alle drei Owner-Ebenen File/Layout/LayoutObject).
--   Bisher existierte der Klartext nur als P1-Objekt-Aggregat
--   (LayoutObjects.ScriptTrigger_Parameter_Text, ALLE Parameter eines Objekts
--   konkateniert) — Formula_Text der script_trigger_parameter-Instanzen blieb
--   dadurch immer NULL und Dateien ohne DDR-Info hatten auf Layout-/File-Ebene
--   gar keine Parameter-Instanz. P4 befüllt daraus (a) Formula_Text der
--   DDR-Anker-Instanzen und (b) per-Trigger-Fallback-Instanzen ohne DDR
--   (Calc_Kind_Raw='ScriptTrigger_<id>' statt kollabierter NULL-Instanz);
--   neue Kandidaten-Kanten reads_field·transaction_parameter_field für das
--   OnWindowTransaction-Parameterfeld (Namens-Kandidaten, file-lokal). Reiner
--   Payload (PK unverändert), DOM- und Streamify-Pfad identisch erweitert.
--   Neue Spalte → MINOR-Bump (Master-Rebuild befüllt Bestandskataloge).
-- @SCHEMA_CHANGELOG 1.25.0: Conditional Formatting strukturiert (P3/P4): neue
--   Tabelle LayoutObjectConditions — eine Zeile pro CF-Regel, depth-verankert
--   aus LayoutObjects.Object_XML extrahiert (/LayoutObject/Conditions/
--   Formatting/Condition; eigene Regeln, Container-Nesting kann nicht
--   doppelzählen — ersetzt den fehlerhaften Leaf-Filter-/Regex-Pfad der
--   Inventar-Query: 4.557 FP/920 FN im Referenzkorpus). Spalten: Rule_UUID
--   (md5 CFRule::File::Object::Index), Object_UUID, Layout_ID, Rule_Index
--   (1-basiert == Condition/@id+1 == DDRREF-Suffix N), Condition_Type (@type
--   roh: 0 Formel, 1-13 wertbasierter Operator), Condition_Kind
--   ('formula'/'value'), Options_Raw (Format-Bitmaske roh; Bit0 = Enable), Calc_Text
--   (Bedingungsformel; bei wertbasierten Regeln die von FM mitserialisierte
--   äquivalente Self-Formel), Calc_Hash (DDRREF), Calculation_UUID (FK auf
--   CalculationsCatalog Rolle conditional_format, in P4 über
--   Calc_Kind_Raw='Condition_N' gefüllt; NULL ohne Anker), Range_Start/
--   Range_End (Operanden wertbasierter Regeln als Ausdruckstext, FM-Vor-
--   kodierung dekodiert), Formatting_Membercount (@membercount, P6-Guard-
--   Basis), Local_CSS (angewandtes Format roh, CDATA). Neue P6-View
--   v_check_cf_rules (membercount-Guard, FK-Coverage). Neue Tabelle →
--   MINOR-Bump (Master-Rebuild befüllt Bestandskataloge).
-- @SCHEMA_CHANGELOG 1.24.0: ScriptTriggers-Vervollständigung (P1): drei neue
--   Spalten am Tabellenende. (a) Trigger_FindMode + Trigger_PreviewMode — SaXML
--   schreibt je Trigger NUR die aktivierten Modi als Attribute (browseMode/
--   findMode/previewMode="True"); bisher wurde allein browseMode extrahiert,
--   wodurch ein Nur-Suchen-Trigger als Trigger_BrowseMode=NULL erschien (kein
--   aktiver Modus sichtbar) und Blättern+Suchen von reinem Blättern nicht
--   unterscheidbar war. (b) Trigger_ScriptParameter_FieldName — das
--   OnWindowTransaction-Attribut scriptParameterFieldName (Feldname, dessen
--   Inhalt FileMaker in den JSON-Scriptparameter aufnimmt); reine Namens-
--   Referenz ohne Tabellen-Qualifizierung/ID/UUID, spät gebunden — hier nur
--   persistiert, KEINE Feld-Kante (Kandidaten-Auflösung ist Folgearbeit).
--   Alle drei als VARCHAR-Passthrough analog Trigger_BrowseMode ('True'/NULL
--   bzw. Roh-Name/NULL). DOM- und Streamify-Pfad identisch erweitert.
--   Neue Spalten → MINOR-Bump (Master-Rebuild befüllt Bestandskataloge).
-- @SCHEMA_CHANGELOG 1.23.0: int32-Härtung der XML-gespeisten Numerik (P1/P2/P3):
--   FileMaker serialisiert vorzeichenlose 32-bit-Werte (z. B. 4294967295 =
--   UINT32_MAX als „-1"/Sentinel), die den Wertebereich von INTEGER (int32)
--   sprengen — webbed bricht dann den kompletten Datei-Scan hart ab
--   (XmlUncastableValue, upstream issue #102; trifft auch explizite
--   columns={…}-Schemata, DOM wie SAX). Daher ALLE XML-gespeisten INTEGER-
--   Deklarationen auf BIGINT geweitet: read_xml-columns-Specs + zugehörige DDL
--   (TableOccurrenceCatalog Box_/Coord_/Color_*, FieldsForTables
--   Max_Repetitions/Validation_MaxChars, ScriptCatalog Option_Bitmask/
--   compatibility, Layouts L_Width/Modifications, AccountsCatalog Account_Kind,
--   PrivilegeSets Other_Value, CustomMenuItems Item_Index) sowie die
--   ::INTEGER-/TRY_CAST-Extraktionen (StepsForScripts Step_Index/Step_ID,
--   LayoutParts Part_*, LayoutObjects Object_Kind, Bounds_*, Z_Order,
--   P2 XMLLayoutReferences/LayoutObjectSteps Step_ID, P3 StepCalculations
--   Step_Index/Calc_Position) — inkl. der streamify-Overrides. Statische
--   kuratierte Maps (ScriptStepRoleMap, ScriptStepControlMap) bleiben bewusst
--   INTEGER (nicht XML-gespeist). Nur Typ-Weitung, keine neuen Spalten/Tabellen;
--   MINOR-Bump, weil der Master-Rebuild die Spaltentypen erneuern muss.
--   Ergaenzung (gleicher Bump): Sentinel-Normalisierung Validation_MaxChars —
--   4294967295 wird per NULLIF zu NULL („unbegrenzt" = kein Limit gesetzt);
--   nur dieser eine Slot (Semantik belegt), alle anderen geweiteten Slots
--   tragen den Rohwert. Drift-Waechter v_check_numeric_sentinels in P6.
-- @SCHEMA_CHANGELOG 1.22.0: Calculation als eigenständiger Objekttyp (P1/P2/P4/P6):
--   Neue Tabelle CalculationsCatalog (P4) — eine Zeile pro Berechnungs-INSTANZ
--   (Identität Owner × Calc_Role × Calc_Index, synthetische UUID
--   md5('Calculation::'||File||'::'||Owner||'::'||Role||'::'||Index)); Union aus
--   den DDR-Ankern (DDR_Calculations, Nachfolger von v_calc_anchors) und den
--   strukturellen Slots ohne DDR-Anker (FieldsForTables-Slots, StepCalculations,
--   CalcsForCustomFunctions, LayoutObjects-Textslots, PrivilegeSetRecordAccess) —
--   Instanzen existieren damit auch OHNE DDR-Info. ObjectCatalog führt die Zeilen
--   als Object_Type='Calculation' (post-CTAS-Block, Muster PluginComponent);
--   neue structural Link-Rolle has_calculation (Owner → Calculation, containment,
--   Counts_For_Where_Used=false, Registry + P6-Wächter). Die bestehenden owner-
--   projizierten Usage-Kanten bleiben KANONISCH (Variante A) — Calculation→Ziel
--   gibt es nur als abgeleitete View v_calculation_links (kein Kanten-Duplikat,
--   kein Graph-Blowup; has_calculation ist structural und bleibt damit per
--   Konstruktion aus LogicalLinks/ClusterEdges draußen). v_calc_anchors wird zur
--   materialisierten Fassade über CalculationsCatalog (Spaltenset unverändert).
--   Subrole-Präzisierung an den P2-Feld-Kanten: AutoEnter-Refs tragen jetzt
--   Link_Subrole 'auto_enter' (A.2.4–A.2.6, A.6.3, A.6.4, A.7.2), die Refs der
--   Fehlermeldungs-Berechnung 'validation_message' statt 'validation'
--   (A.2.10–A.2.11; Link_Role bleibt validates_by_calc) — damit sind die
--   Feld-Slots in v_calculation_links trennscharf. Lücken-Schließung:
--   ScriptTriggers speichert neu Trigger_XML (nur Owner-Typen Layout/File;
--   Object-Level steckt bereits in LayoutObjects.Object_XML), P2 erntet daraus
--   die Layout-/File-Level-Trigger-Parameter-Refs (neue Sektion A.12) — die
--   bisher unsichtbaren Layout-Trigger-Parameter-Anker bekommen Owner-Kanten.
--   Neue P6-Views v_check_calculations (Owner-Existenz, UUID-Dups,
--   DDR-Anker-Abdeckung, Rollen-Vokabular). Neue Tabelle + neue Spalte +
--   Inhalts-Korrektur an ObjectLinks → MINOR-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.21.0: Classic-Theme sichtbar machen (P3/A.11 + P4): SaXML
--   kodiert das Classic-Theme als LEERES Element <LayoutThemeReference/> ohne
--   id/name/UUID/Base — nur Nicht-Classic-Themes tragen das Attribut-Tripel.
--   Folge bisher: L_Theme_* ist für JEDES Classic-Layout NULL, die Zeichenkette
--   'com.filemaker.theme.classic' steht in keinem einzigen Layout-Datensatz, und
--   die uses_theme-Kante blieb für Classic komplett leer (Classic erschien in
--   jeder Datei als unbenutzt). NEU: Layouts.L_Theme_Resolved_Name/_UUID
--   (abgeleitet in P3, nur für echte Layouts belegt — Ordner/Trenner bleiben
--   NULL): leere Referenz → Name 'com.filemaker.theme.classic', UUID aus dem
--   ThemeCatalog der Datei, aufgelöst über den Theme-NAMEN (Theme_ID=1 ist NICHT
--   verlässlich Classic). Die Rohspalten bleiben unverändert (roh = „was stand im
--   Export"). P4 baut uses_theme jetzt über die aufgelöste UUID, P6
--   (v_check_synthetic/uses_theme_links) zählt die Erwartung entsprechend.
--   Deutung am Korpus beidseitig verifiziert: genau die Dateien mit themenlosen
--   Layouts führen Classic im ThemeCatalog, und Classic wird nie explizit
--   referenziert. Neue Spalten + Inhalts-Korrektur an ObjectLinks → Version-Bump.
--   ANMERKUNG zum Rebuild: P3 läuft einmal auf der Master-DB (ALTER … IF NOT
--   EXISTS + UPDATE über alle Layouts) und P4 baut ObjectLinks per CREATE OR
--   REPLACE komplett neu — fachlich genügt ein erneuter Pipeline-Lauf. Der
--   Versions-Mismatch löst über die Auto-Heal-Erkennung trotzdem einen
--   Rebuild aus (Absicht: SchemaInfo darf nicht über den DB-Inhalt lügen);
--   P7 re-clustert danach automatisch.
-- @SCHEMA_CHANGELOG 1.20.0: PSoS-Ausführungskontext als Link_Subrole (P4 Block 15):
--   calls_script-Kanten aus Perform Script on Server tragen Subrole 'on_server'
--   (Step 164) bzw. 'on_server_callback' (Step 210); gewöhnliche Aufrufe (Step 1)
--   bleiben Subrole NULL. Bewusst KEINE neue Link-Rolle — calls_script bleibt die
--   eine Aufruf-Rolle (where-used/Call-Chain/Graph unverändert), der Kontext ist
--   ein Qualifier nach dem Muster Condition_1/Hide/left/right. Dedup-Pässe
--   (prefer-local, prefer-declared-source) sind bereits Subrole-bewusst
--   (IS NOT DISTINCT FROM). Konsument: platform_specific_server-Bundle löst
--   Server-Bindungsziele über die Kante statt per Step_XML-Regex auf.
--   Inhalts-Korrektur an ObjectLinks → Version-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.19.0: UUID-Healing Fundament (H0): P2-Referenztabellen
--   (XMLStepReferences, XMLLayoutReferences, XMLCalcReferences) extrahieren zusätzlich
--   Ref_ID (= FileMaker-interne @id des Referenz-Elements; SaXML-Tripel id+name+UUID)
--   und TO_Ref_ID (Kontext-TO-@id bei Feld-Referenzen — FieldReference/@id ist
--   tabellen-lokal, Feld-Schlüssel zweistufig); DuplicateAbsorptionDetails erhält
--   Healed_UUID/Heal_Status/Discriminator (Mapping Original↔Ersatz-UUID); neue
--   Prelude-Makros fm_heal_uuid/fm_heal_pick/fm_heal_enabled (md5-Ersatz-UUIDs über
--   interne FM-IDs, Survivor = kleinste interne ID, Schalter FM_UUID_HEAL).
--   H1 umgesetzt: Heilung in den Upsert-CTEs der 9 main-Kataloge (ScriptCatalog,
--   ExternalDS, BaseTable, TO, Fields, ValueList, OptionsForValueLists [VL-Namespace],
--   CustomFunctions [_cf_catalog_raw], Accounts) + Zensus-Detail-Mapping je Katalog;
--   Kaskade der Fremd-UUID-Spalten post-P1 (convert_xml_01b_heal_cascade.sql);
--   P4-Rewrite-Stufe (1) verteilt eingehende Referenzen per Ref_ID auf die Zwillinge.
--   H2 umgesetzt: Heilung der sub-gechunkten Kataloge (StepsForScripts
--   [script_id·step_index], LayoutObjects [layout_id·object_id, _dedup_rn-Partition
--   um Object_ID erweitert — Copy-Paste-Zwillinge überleben bis zur Heilung],
--   Layouts [layout_id]) intra-chunk in Basis + streamify-Overrides; chunk-
--   übergreifende Paare heilt der catmerge-Nachschlag (convert_turbo.sh: Pflicht-
--   Dup-Count fail-hard, Heal-INSERT mit globalem min-Identitäts-Survivor,
--   Zensus-Vervollständigung Chunk_Seq=-1; Part-Pfad-Fallback zensiert nur).
--   P2 attribuiert Layout-Objekt-Quellen über die Katalogspalte statt Roh-XML
--   (geheilte Zwillinge trügen sonst die Original-UUID). Ersatz-UUIDs sind
--   chunking-invariant (M=1 ≡ M=25 verifiziert). 3A/Doppel-Serialisierung
--   kollabiert weiterhin. Auf duplikatfreien Korpora Lauf-zu-Lauf bit-identisch.
-- @SCHEMA_CHANGELOG 1.18.0: Klon-Scoping über deklarierte Datenquellen (P4): neue
--   Tabelle DataSourceFileMap ((File_Name, DS_UUID) → importierte Zieldatei, via
--   DS_Name-Match bzw. Pfadlisten-Auflösung — schließt die _dev-Suffix-Lücke);
--   ObjectLinks-Block 6 (base_table) scopet das Ziel auf die deklarierte Quelldatei;
--   neuer prefer-declared-source-Post-Pass entfernt Phantom-Kanten in Klon-Korpora
--   (Kante fächert über mehrere Dateien, genau eine ist deklarierte Datenquelle);
--   neue P6-View v_check_phantom_links. Klonfreie Korpora bleiben bit-identisch;
--   Inhalts-Korrektur an ObjectLinks → Version-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.17.0: Dup-Zensus vervollständigt (Metadata-Integrity Stufe 0):
--   DuplicateAbsorptionDetails + Kontext-/Klartext-Spalten (Parent_Name, Position,
--   Display_Text, Payload_XML); Detail-Erfassung zusätzlich für StepsForScripts,
--   Layouts und LayoutObjects; LayoutObjects-Zensus zählt Copy-Paste-Dups
--   (gleiche UUID, verschiedene Object_IDs) getrennt von FileMakers
--   Doppel-Serialisierung; neue Tabelle MergeAbsorptions (Persistenz des
--   katmerge-a2-Reports, befüllt von convert_turbo.sh).
-- @SCHEMA_CHANGELOG 1.16.0: StepsForScripts.Calculation_Text — zweite Härtung der
--   Extraktion: zusätzlich not(ancestor::Bounds). Bei Fensterschritten OHNE
--   Namens-Berechnung (New Window / Go to Related Record mit "New window"-Option,
--   leeres <Name/>) griff '[1]' bisher die erste Geometrie-Berechnung — die Spalte
--   meldete eine Fensterhöhe als vermeintlichen Fensternamen. Die Spalten-Semantik
--   ("erste Berechnung in Dokument-Reihenfolge, ohne Repetitions-/Geometrie-Slots")
--   ist jetzt in schema-reference.md dokumentiert. NEU dazu (P3, additiv):
--   StepCalculations — ALLE positionierten Berechnungen je Step mit Slot-Kontext
--   (Elternelement: Name/height/URL/Parameter:<type>/…) + Calc_Position; sowie
--   StepsForScripts.Opens_Window (abgeleitet, nur Step_ID 74/122 belegt: New Window
--   immer TRUE, Go to Related Record TRUE bei <WindowReference>-Option, sonst FALSE).
--   Inhalts-Korrektur + neue Tabelle → Version-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.15.0: CustomFunctionsCatalog um Folder_Type / Is_Separator /
--   Sequence_ID erweitert (additiv, analog ScriptCatalog + Layouts). CF-Ordner und
--   -Trenner (isFolder="True"/"Marker") waren bisher von echten Custom Functions
--   ununterscheidbar und zählten in jeder CF-Kennzahl mit. Folge-Änderungen:
--   FolderHierarchy bekommt den dritten UNION-Zweig, ObjectCatalog filtert Ordner
--   aus dem CustomFunction-Block und führt sie über Block 24 als 'Folder'.
--   Zusätzlich ScriptStepRoleMap um 26 Step-IDs nachkuratiert (P6-Wächter
--   v_check_step_roles / Quality-Check auf 0). Version-Bump, weil ein
--   inkrementeller Lauf weder die neuen Spalten füllt noch die Katalogzeilen
--   umhängt.
-- @SCHEMA_CHANGELOG 1.14.0: ObjectCatalog/ScriptStepType jetzt auch aus LayoutObjectSteps
--   (convert_xml_04_catalog.sql, Block 27). Bisher nur aus StepsForScripts: ein Step-Typ,
--   den ausschließlich ein Button verwendet (Button / Grouped Button), bekam keinen
--   Katalogeintrag — der Step-Namen-Link der Button-Detailansicht (md5('ScriptStepType::'
--   ||Step_Name)) lief damit ins "not found". Reine Zeilen-Ergänzung, keine Spalten;
--   Version-Bump, weil nur er den Rebuild auslöst (Hash-Drift allein → nur „warn",
--   ein inkrementeller Lauf zöge die fehlenden Katalogzeilen NICHT nach).
-- @SCHEMA_CHANGELOG 1.13.0: StepsForScripts.Calculation_Text — Korrektur der Extraktion.
--   Bisher griff '//Calculation/Text'[1] das erste <Calculation> in Dokument-Reihenfolge;
--   bei einer BERECHNETEN Repetition der Ziel-Feldreferenz (<repetition><Calculation>…) ist
--   das der Repetitions-Ausdruck statt der eigentlichen Berechnung. Neu:
--   '//Calculation[not(ancestor::repetition)]/Text'[1] (step-typ-unabhängig; betraf
--   Set Field, Replace Field Contents, Insert Calculated Result, Insert from URL u.a.).
--   Reine Inhalts-Korrektur einer bestehenden Spalte → Version-Bump wg. Hash-/Rebuild.
-- @SCHEMA_CHANGELOG 1.12.1: ObjectCatalog-Anzeigename für Themes = Theme_Display
--   (COALESCE auf internen name), convert_xml_04_catalog.sql — der Theme-Detailtitel,
--   Referenzen und Graph zeigen jetzt „Apex Blau" statt com.filemaker.theme.apex_blue.
--   Reine Anzeige-Semantik (Links laufen über UUID) → Version-Bump wg. Hash-/Rebuild.
-- @SCHEMA_CHANGELOG 1.12.0: ThemeCatalog +1 Spalte Theme_Display (aus <Theme @Display>)
--   — der lokalisierte Anzeigename des Designs (z.B. „Apex Blau"), wie ihn die
--   FileMaker-Oberfläche zeigt. Bisher nur der interne name (com.filemaker.theme.*).
--   Additiv (nur Spalte) → Version-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.11.0: Layout „Allgemein"-Optionen aus dem <Options>-Bitfeld:
--   Layouts +5 Boolean-Spalten (Auto_Save_Changes=Bit4-invertiert, Show_Field_Frames=
--   Bit5, Frame_Current_Record_Only=Bit0, Show_Current_Record_List=Bit28-invertiert,
--   Quick_Find_Enabled=Bit15-invertiert). Decoder an 6 Kalibrier-Layouts (je genau eine
--   Option aktiv) + Default-Layout verifiziert (6/6). „In Layout-Menüs aufnehmen" ist
--   separat das @hidden-Attribut (Is_Hidden, 1.9.0). Abgeleitet aus Options_Raw, nur
--   echte Layouts → sonst NULL. Additiv (nur Spalten) → Version-Bump (Master-Rebuild).
-- @SCHEMA_CHANGELOG 1.10.0: Feld-Optionen-Abdeckung: FieldsForTables +14 Spalten.
--   Validierung: Validation_AlwaysValidate, _StrictType (<Strict>), _MaxChars
--   (<MaximumSize>), _Range_From/_To (<Range @from/@to>), _Calc_Text/_Calc_Hash
--   (<Calculated><Calculation>, Prüfung durch Berechnung), _Message (<Message>),
--   _Message_Calc_Hash (<MessageCalc>). Speicher: Storage_IndexLanguage(_ID) aus
--   <Storage><LanguageReference> (Standard-Indexsprache; Kind-Element, kein Attribut).
--   Summary: Summary_RestartEachGroup + _RepetitionMode (<SummaryInfo
--   @restartEachGroup/@summarizeRepetition>). Neue Link-Rolle validates_by_calc
--   (Field→Field/CustomFunction via Validation_Calc_Hash → DDR-Chunks; schließt die
--   Where-used-Lücke für nur in einer Feldvalidierung referenzierte Objekte).
--   Additiv (Spalten + Rolle) → Version-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.9.0: Layout-Metadaten: Layouts +5 Spalten (Is_Hidden aus
--   <Options @hidden> = „In Layout-Menüs aufnehmen" invertiert; L_Theme_Base aus
--   LayoutThemeReference@Base; Modified_By/_At/Modifications aus <UUID @userName/
--   @timestamp/@modifications> = Autoren-Metadaten). <Options @hidden> wird als
--   BARE-Attribut gelesen (nicht "@hidden"). Layout-Ebene Script-Trigger existieren
--   bereits in der Tabelle ScriptTriggers (Owner_Type='Layout') — keine neue Tabelle.
--   Additiv (nur Spalten) → Version-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.8.0: Layout-Ansichten (Darstellungsform): Layouts +5 Spalten
--   (Options_Raw + View_Form/List/Table_Available + Default_View). Die verfügbaren
--   Ansichten (Formular/Liste/Tabelle) und die Standardansicht sind im bit-gepackten
--   <Options>-Integer des Layout-Tails kodiert (kein explizites XML-Element). Decoder
--   an 5 Kalibrier-Layouts verifiziert (5/5, Konfund Bit1↔Bit9 durch Mehrfach-Ansicht-
--   Layout aufgelöst): Bit1/2/3 = Form/Liste/Tabelle NICHT verfügbar (invertiert),
--   Bit9 = Standard≠Formular, Bit14 = Standard=Tabelle. Options_Raw roh mitgeführt für
--   spätere Bit-Ableitungen ohne Reimport; View-Spalten nur für echte Layouts (Ordner/
--   Trenner → NULL). Additiv (Spalten-Erweiterung) → Version-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.7.0: Button-eingebettete Script-Steps als Klartext im
--   LayoutObject-Detail (wie Script-Detail). (a) DDR_ScriptSteps: UUID-lose
--   StepText-Records (button-eingebettete Steps <_ hash="…">) fallen auf
--   'hash:'||Step_Hash zurück statt auf den leeren PK zu kollabieren (nur EINER
--   pro Datei überlebte) — der Klartext ist so via DDRREF-Hash auflösbar.
--   (b) Neue P2-Tabelle LayoutObjectSteps (Object_UUID, File_Name, Step_ID,
--   Step_Name, Step_Enabled, StepText_Hash): materialisiert pro Button-Objekt den
--   eigenen action/Step, damit die READ_ONLY-API (kann webbed nicht laden) ihn ohne
--   xml_extract als Tokens rendern kann. Additiv (neue Tabelle + Extraktions-
--   Semantik) → Version-Bump wg. Hash-Drift-Wächter (Master-Rebuild).
-- @SCHEMA_CHANGELOG 1.6.1: RelationshipCatalog erfasst jetzt Beziehungen mit
--   Prädikat-Feldern auf externen TO-Seiten (F-1b). Der frühere UUID-Pflicht-Filter
--   verwarf die GESAMTE Beziehung, wenn ein Prädikat-Feld einer anderen Datei gehörte
--   (FieldReference@UUID="") → 393 fehlende Beziehungen (17 %). Neu: strukturelle
--   Gültigkeitsprüfung (Prädikat-Feld-id statt UUID), leere Feld-UUID → NULL
--   (NULLIF), P4 löst über (Field_TO_UUID, Field_ID) auf die kanonische Feld-UUID
--   auf (analog Sort-Feld-Block). Keine Spalten-/Tabellen-Änderung — reine
--   Extraktions-Semantik (Datengewinn) → Version-Bump nur wg. Hash-Drift-Wächter.
--   Korpus 1961 → 2354 Beziehungen; neuer P6-View v_check_relationship_field_resolution.
-- @SCHEMA_CHANGELOG 1.5.2: FileOptionsCatalog +6 Spalten aus dem Metadata-
--   AddAction-Zweig: SavePassword (Save_Password_Keychain/_RequireMobile —
--   "Gespeicherte Anmeldeinformationen für die Authentifizierung zulassen",
--   sicherheitsrelevant, eigenständig vom Auto-Login <Login>) + PageSetup
--   (PageSetup_Orientation/_Scale/_Width/_Height — Druck-Standard, nur extrahiert,
--   nicht im GUI). Element-Universum via Prod-Korpus + ooe-fm-Referenz verifiziert
--   ("Toolbar ausblenden" existiert in SaXML bis FM22 nicht). Additiv, aber
--   Spalten-Erweiterung → Version-Bump (Master-Rebuild nötig).
-- @SCHEMA_CHANGELOG 1.5.1: Layout-MenuSet + Sub-Summary-Umbruchfeld: Layouts
--   +3 Spalten (L_MenuSet_ID/_Name/_UUID aus CustomMenuSetReference, Built-in-
--   Default id=0 → NULL), LayoutParts +6 Spalten (Part_Seq, Break_Field_ID/
--   _Name/_UUID, Break_TO_Name/_UUID) + PK-Erweiterung um Part_Seq (mehrere
--   Parts gleicher Art kollabierten). LayoutPart-Composite-UUID neu:
--   'part_'-Präfix + Part_Seq. Neue Link-Rollen:
--   uses_menuset (Layout→CustomMenuSet), breaks_on_field (LayoutPart→Field;
--   Platzhalter-FieldReference id=0 → NULL, Kante nur für Sub-Summary-Parts —
--   Grand-Summary-Leftovers sind kein Usage-Signal).
-- @SCHEMA_CHANGELOG 1.5.0: Abdeckungs-Erweiterung: FieldsForTables
--   +18 Spalten (Validation_*, Storage_*, Serial_*, Summary_*), Layouts +5 Spalten
--   (L_TO_UUID, L_Width, L_Theme_*), neue Tabelle FileOptionsCatalog (Metadata-
--   Branch: Encryption/Minimum/Login/Defaults/Sharing). Neue Referenz
--   XMLStepReferences Ref_Type='menuset' (Install Menu Set). Neue Link-Rollen:
--   grants_privilege, uses_theme, installs_menuset, LayoutPart→parent_layout,
--   uses_valuelist(validation), summarizes_field, default_layout,
--   auto_login_account. Additiv, aber Spalten-Erweiterung bestehender Tabellen
--   → Version-Bump (Turbo-Merge INSERT BY NAME braucht den Master-Rebuild).
-- @SCHEMA_CHANGELOG 1.4.1: CalcsForCustomFunctions auch für SaXML v2.3.0.0 (FM 26+),
--   wo <Calculation> in <CustomFunction> eingebettet ist statt in einer separaten
--   <CalcsForCustomFunctions>-Sektion. Struktur-tolerante Doppel-Extraktion (Legacy +
--   Embedded) aus EINEM CustomFunctionsCatalog-Parse; keine Versions-Weiche. Additiv.
-- @SCHEMA_CHANGELOG 1.4.0: neue Tabellen FileAccessAuthorizations,
--   CustomMenuSetCatalog, LibraryReferences (additiv; bestehende 41 Tabellen unverändert).
--   + CustomMenuSet im ObjectCatalog + CustomMenuSet→CustomMenu (contains_menu) in ObjectLinks.
-- @SCHEMA_HASH_FILES sql/convert_xml_01_extract.sql sql/convert_xml_01b_heal_cascade.sql sql/convert_xml_01c_design_function_retype.sql sql/convert_xml_02_resolve.sql sql/convert_xml_03_details.sql sql/convert_xml_04_catalog.sql
*/


-- webbed (XML-Reader) laden. Stock/Manual/öffentliches Repo: das signierte
-- Community-webbed aus dem Extension-Home (im Image gebacken — kein INSTALL/
-- Netzwerk nötig). Der Convert-Pipeline-Treiber (convert_fm_xml.sh) ERSETZT diese
-- Zeile im Patched-Modus per sed durch  LOAD '<abs-Pfad>'  und startet duckdb mit
-- -unsigned (das gepatchte webbed mit dem nested-attr-SAX-Fix ist lokal gebaut →
-- unsigniert).
LOAD webbed;

-- xml_unescape(): dekodiert die gängigen XML-Entities in TEXT, der aus ATTRIBUTwerten
-- gelesen wird (Entity-Residual). Hintergrund: webbeds SAX-Pfad dekodiert
-- numerische/benannte Entities in Attributen NICHT (DOM schon) → derselbe Name kommt
-- je nach Chunk-Größe (SAX bei großem Chunk vs DOM bei kleinem) als 'Copy &#38; Paste'
-- ODER 'Copy & Paste' → chunk-abhängig (bricht --split/--subchunk-Bit-Identität).
-- Anwendung auf die betroffenen Namens-Spalten macht beide Pfade konsistent.
-- IDEMPOTENT für DOM-Werte: ein bereits dekodiertes literales '&' enthält kein
-- Entity-Muster und bleibt unverändert. '&amp;' MUSS zuletzt ersetzt werden, sonst
-- würde '&amp;lt;' fälschlich zu '<' statt '&lt;'.
-- Workaround-Disable-Gate (Version-Check-Registry ingestion/version_check.json,
-- Capability sax_attr_entities → Flag wa_attr_unescape, Default ON). Der Workaround wird
-- NICHT geloescht, sondern flag-bewacht: aktiv (default) → dekodieren; OFF (sobald webbed
-- SAX-Attribut-Entities selbst dekodiert) → s unveraendert durchreichen. DOM-No-op,
-- idempotent → identitaets-neutral, solange das Flag ON ist.
CREATE OR REPLACE MACRO xml_unescape(s) AS
    CASE WHEN getvariable('wa_attr_unescape') THEN
    replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
        s,
        '&#38;','&'), '&#60;','<'), '&#62;','>'), '&#34;','"'), '&#39;',''''),
        '&lt;','<'), '&gt;','>'), '&quot;','"'), '&apos;',''''),
        '&amp;','&')
    ELSE s END;

-- ws_restore(): holt den chr(127)-Sentinel zurueck zu LF (0x7F -> chr 10). Der
-- Preprozessor (convert_fm_xml.sh / turbo_phaseS_fuse.awk) wandelt CR (0x0D) VOR dem
-- Parsen in 0x7F (DEL, kein Whitespace), damit webbeds frueherer #73-Whitespace-Collapse
-- (CleanTextContent()) den Zeilenumbruch nicht zu einem Space kollabiert; hier wird er
-- danach zu LF restauriert. Anwendung auf ALLE Calc-/Text-Spalten UND die Roh-XML-
-- Fragmentspalten (Step_XML/Object_XML/Parameters_XML), die sonst das DEL-Byte leakten.
-- Workaround-Disable-Gate (Version-Check-Registry ingestion/version_check.json,
-- Capability whitespace_preservation -> Flag wa_ws_sentinel, Default ON). Der Workaround
-- wird NICHT geloescht, sondern flag-bewacht: aktiv (Default) -> 0x7F->LF restaurieren;
-- OFF (sobald webbed Whitespace nativ bewahrt, per Probe) -> s unveraendert durchreichen
-- (dann ist auch der Preproc-Sentinel aus, also kein 0x7F vorhanden -> ELSE = No-op).
-- EMPIRISCH bit-identisch (v2.2.1): replace(0x7F->LF) [Sentinel ON] == native CR->LF
-- [Sentinel OFF], fuer typisierte Reads UND Fragment-Extraktion.
CREATE OR REPLACE MACRO ws_restore(s) AS
    CASE WHEN getvariable('wa_ws_sentinel') THEN replace(s, chr(127), chr(10)) ELSE s END;

-- fm_canon_layout_type: locale-robuste Kanonisierung des LayoutObject-Typs.
-- `LayoutObject/@type` ist im SaXML-Export LOKALISIERT (dt. Client: „Ausschnitt"=Portal,
-- „Tastenleiste"=Button Bar, „Einblendmenü"=Pop-up Menu, „Bearbeitungsfeld"=Edit Box …).
-- Ohne Normalisierung tragen non-EN-Exporte deutsche Typnamen UND — schwerwiegender — die
-- Container-Rekursion unten (`WHERE parent.Object_Type IN (<engl. Namen>)`) descendet nicht
-- in lokalisierte Container → deren Kind-Objekte gehen still verloren (fehlende displays_field-
-- Links, leere Portale/Button-Bars/Tab-Panels). Diese Kanonisierung läuft an der Extraktion,
-- also BEVOR die Rekursion auf `parent.Object_Type` filtert → schließt beide Lücken zugleich.
--
-- Ist der Rohtyp bereits ein kanonischer englischer Name (englische Exporte), wird er
-- UNVERÄNDERT durchgereicht: die erste WHEN-Klausel greift und die CASE-Kurzschluss-Semantik
-- fasst `oxml` nie an → englischer Korpus bit-identisch UND ohne XML-Zusatzparsing.
-- Nur für nicht-kanonische (lokalisierte) Rohtypen leitet der Macro aus locale-UNABHÄNGIGEN
-- Signalen ab (Wrapper-ELEMENTNAMEN sind im Export IMMER englisch; nur @type ist übersetzt):
--   * @kind (numerisch) als Primärschalter — 1:1 für kind 2..7,9..12,14..18 (korpus-verifiziert);
--   * kind=8 (Group vs Grouped Button): Grouped Button hat das direkte Kind
--     /LayoutObject/GroupedButton/action, ein einfacher Group nicht;
--   * kind=13 (Web Viewer vs Chart): beide teilen kind=13 und tragen einen
--     <External>-Block; das Chart hat darin das Kind /LayoutObject/External/Chart
--     (der Web Viewer stattdessen External/WebViewer). Ohne Sonde kollabierten
--     Charts auf 'Web Viewer' (kind-13-Kollision);
--   * kind=1 (Feld-Controls): /LayoutObject/Field/Display/@Style — 0=Edit Box, 1=Drop-down
--     List, 2=Pop-up Menu, 3=Checkbox Set, 4=Radio Button Set, 6=Drop-down Calendar,
--     7=Concealed Edit Box. (Das Container-FELD hat ebenfalls Style 0, kommt aber
--     unlokalisiert als „Container" durch → bleibt via Kanon-Pfad korrekt, wird nie
--     abgeleitet.) Direkte Kind-Achsen statt //-Deszendenten, damit verschachtelte
--     Kinder den Elterntyp nicht verfälschen.
-- Unbekannter kind ⇒ Rohtyp behalten; P6 v_check_unknown_object_types meldet ihn zur Kuration.
CREATE OR REPLACE MACRO fm_canon_layout_type(raw_type, kind, oxml) AS (
    CASE
        WHEN raw_type IN (
            'Text', 'Edit Box', 'Grouped Button', 'Rectangle', 'Line', 'Graphic',
            'Group', 'Checkbox Set', 'Button', 'Container', 'Portal', 'Drop-down List',
            'Panel', 'Radio Button Set', 'Button Bar', 'PopoverPanel', 'Popover Button',
            'Pop-up Menu', 'Tab Control', 'Web Viewer', 'Chart', 'Oval', 'Rounded Rectangle',
            'Concealed Edit Box', 'Slide Control', 'Drop-down Calendar'
        ) THEN raw_type
        WHEN kind = 2  THEN 'Text'
        WHEN kind = 3  THEN 'Graphic'
        WHEN kind = 4  THEN 'Line'
        WHEN kind = 5  THEN 'Rectangle'
        WHEN kind = 6  THEN 'Rounded Rectangle'
        WHEN kind = 7  THEN 'Oval'
        WHEN kind = 8  THEN CASE WHEN len(xml_extract_elements(oxml, '/LayoutObject/GroupedButton/action')) > 0
                                 THEN 'Grouped Button' ELSE 'Group' END
        WHEN kind = 9  THEN 'Portal'
        WHEN kind = 10 THEN 'Button'
        WHEN kind = 11 THEN 'Tab Control'
        WHEN kind = 12 THEN 'Panel'
        WHEN kind = 13 THEN CASE WHEN len(xml_extract_elements(oxml, '/LayoutObject/External/Chart')) > 0
                                 THEN 'Chart' ELSE 'Web Viewer' END
        WHEN kind = 14 THEN 'Popover Button'
        WHEN kind = 15 THEN 'PopoverPanel'
        WHEN kind = 16 THEN 'Slide Control'
        WHEN kind = 17 THEN 'Panel'
        WHEN kind = 18 THEN 'Button Bar'
        WHEN kind = 1  THEN CASE xml_extract_text(oxml, '/LayoutObject/Field/Display/@Style')[1]
                                WHEN '1' THEN 'Drop-down List'
                                WHEN '2' THEN 'Pop-up Menu'
                                WHEN '3' THEN 'Checkbox Set'
                                WHEN '4' THEN 'Radio Button Set'
                                WHEN '6' THEN 'Drop-down Calendar'
                                WHEN '7' THEN 'Concealed Edit Box'
                                ELSE 'Edit Box'
                            END
        ELSE raw_type
    END
);

-- ============================================
-- UUID-Healing (Schema 1.19.0) — deterministische Ersatz-UUIDs für Intra-File-Duplikate
-- ============================================
-- Intra-File-UUID-Duplikate (Klasse B: Copy-Paste-Zwillinge — gleiche UUID, verschiedene
-- interne FM-IDs) kollabierten bisher im ON-CONFLICT-Upsert (Objekt-Verlust, nur zensiert).
-- Die Heilung gibt jedem Nicht-Survivor-Zwilling eine deterministische Ersatz-UUID:
--
--   md5('DupHeal::' || Catalog || '::' || File_Name || '::' || Original_UUID || '::' || Diskriminator)
--
-- Eigenschaften (verbindliche Design-Regeln):
--   * Diskriminator = INTERNE FileMaker-ID (Script_ID, L_ID, Table_ID+Field_ID, …) —
--     NIE Occurrence_Seq/Chunk_Seq/XML-Reihenfolge (chunking-/glob-abhängig) und NIE
--     die Roh-XML-Serialisierung (DOM/SAX-Divergenz; Muster der md5-NULL-PK-Guards).
--   * Reine Zeilenfunktion → parallel-sicher ohne Chunk-Koordination (Katana-Auflage).
--   * md5-Hex (32 Zeichen, ohne Bindestriche) matcht die native UUID-Form 8-4-4-4-12
--     bewusst NICHT → „native UUID"-Filter (Klon-Dashboards) schließen Synthetik aus.
--   * Survivor-Regel: der Zwilling mit der KLEINSTEN internen ID behält die Original-
--     UUID (deterministisch, unabhängig von Chunk-/Merge-Reihenfolge; das älteste
--     Objekt ist mit hoher Wahrscheinlichkeit das „Original").
--   * Rückfall-Schalter FM_UUID_HEAL=0 → Verhalten wie vor der Heilung (absorbieren +
--     zensieren), für Vergleichs-Importe und Fehler-Reproduktion.
CREATE OR REPLACE MACRO fm_heal_enabled() AS
    COALESCE(NULLIF(getenv('FM_UUID_HEAL'), ''), '1') <> '0';

CREATE OR REPLACE MACRO fm_heal_uuid(catalog_name, file_name, orig_uuid, discriminator) AS
    md5('DupHeal::' || COALESCE(catalog_name, '') || '::' || COALESCE(file_name, '') || '::' ||
        COALESCE(orig_uuid, '') || '::' || COALESCE(discriminator::VARCHAR, ''));

-- Auswahl-Helfer für die Upsert-CTEs: Survivor behält die Original-UUID, alle anderen
-- Zwillinge werden geheilt — sofern der Schalter an ist (sonst Original-UUID → der
-- ON-CONFLICT-Kollaps greift exakt wie heute).
CREATE OR REPLACE MACRO fm_heal_pick(is_survivor, catalog_name, file_name, orig_uuid, discriminator) AS
    CASE WHEN is_survivor OR NOT fm_heal_enabled() THEN orig_uuid
         ELSE fm_heal_uuid(catalog_name, file_name, orig_uuid, discriminator) END;

-- json_escape() Macro entfernt: xml_to_json() wird nicht mehr verwendet.
-- Stattdessen speichern wir rohes XML (Object_XML, Parameters_XML, Menu_XML, Theme_XML)
-- und extrahieren Werte direkt per xml_extract_text().

-- Pfad zur XML-Datei. Env-Variable FM_XML_DIR überschreibt den Default
-- 'xml' (relativ zum aktuellen Arbeitsverzeichnis). Das convert-xml-Skill-
-- Skript setzt FM_XML_DIR auf ein temporäres Verzeichnis.
SET file_search_path = COALESCE(NULLIF(getenv('FM_XML_DIR'), ''), 'xml');
SET VARIABLE fm_xml = 'Test.xml';  -- Wird durch Skill-Script ersetzt

-- Schema-Marker (werden vom Shell-Skript zur Build-Zeit ersetzt; siehe
-- Header-Kommentar @SCHEMA_VERSION / @SCHEMA_HASH_FILES).
-- Die SchemaInfo-Tabelle (s. u.) wird am Ende des Imports mit diesen Werten
-- befüllt, sodass folgende Läufe Drift detektieren können.
SET VARIABLE schema_version = '1.1.0';   -- Wird durch Skill-Script ersetzt
SET VARIABLE schema_hash = 'pending';    -- Wird durch Skill-Script ersetzt
SET VARIABLE schema_notes = 'convert_xml.sql import';

-- Sub-Chunk-Offset für Sequence_ID.
-- Default 0 = unsplit/coarse unverändert. Beim Sub-Chunking eines Sequence_ID-Katalogs
-- (LayoutCatalog/ScriptCatalog) injiziert das Skript pro Sub-Chunk den globalen
-- Record-Offset (= Σ Records vorheriger Sub-Chunks), damit ROW_NUMBER() pro Chunk +
-- Offset die globale XML-Reihenfolge rekonstruiert (Sequence_ID wird nur als ORDER-BY
-- konsumiert → Ordnung genügt, Kontiguität egal).
SET VARIABLE seq_offset = 0;   -- Wird beim Sub-Chunking pro Chunk ersetzt

-- maximale Speichergröße für read_xml erhöhen (Standard: 16MB)
SET VARIABLE max_filesize TO 256000000; -- 256 MB

-- ============================================================================
-- SAX-Streaming-Aktuatoren
-- ----------------------------------------------------------------------------
-- Empirisch ermittelte webbed-Mechanik: NICHT der streaming-Flag, sondern
-- `maximum_file_size` ist der Aktuator. Datei > maximum_file_size + streaming=true
-- → SAX (O(beschränkt) RAM). Datei ≤ maximum_file_size → DOM (egal welcher Flag).
-- streaming=false + Datei > Cap → harter Fehler (KEIN stilles Korrumpieren).
--
-- Darum zwei Variablen, von jedem typisierten read_xml gemeinsam genutzt:
--   dom_threshold  — der maximum_file_size-Wert pro Read (klein ⇒ erzwingt SAX)
--   use_streaming  — der streaming-Flag (nur true, wenn der SAX-nested-attr-Fix da ist)
--
-- SAFE-BY-DEFAULT: Default = DOM (dom_threshold = max_filesize, use_streaming=false).
-- So bleibt Stock-/öffentliches-webbed unverändert sicher (256-MB-DOM, Fehler erst
-- bei >256 MB statt stiller Stream-Korruption). NUR der Patched-Modus des Treibers
-- (convert_fm_xml.sh) ersetzt den Marker unten durch einen Capability-Self-Test,
-- der use_streaming/dom_threshold scharf schaltet.
SET VARIABLE dom_threshold = getvariable('max_filesize');
SET VARIABLE use_streaming = false;
-- Workaround-Disable-Flags (Version-Check-Registry ingestion/version_check.json):
-- Default = Workaround ON (safe-by-default). Ein zukuenftiger Treiber-Probe-Lauf kann sie
-- am @WEBBED_SELFTEST@-Marker uebersteuern (auf OFF), sobald der zugehoerige webbed-Fix da ist.
SET VARIABLE wa_attr_unescape = true;
-- chr(127)-Sentinel-Restore (Capability whitespace_preservation / #73). Default ON =
-- Sentinel aktiv (0x7F->LF, ws_restore-Macro greift). Der Treiber uebersteuert das Flag
-- am Selbsttest-Marker (unten) auf false, sobald die Probe bestaetigt, dass webbed
-- Whitespace nativ bewahrt (dann laeuft auch der Preproc-Sentinel nicht). Gemeinsame
-- Single Source mit der Bash-/awk-Preproc-Gatung (WS_SENTINEL_ON im Treiber).
SET VARIABLE wa_ws_sentinel = true;
-- @WEBBED_SELFTEST@  (Treiber ersetzt diese Zeile im Patched-Modus; sonst No-Op)

-- Performance (P1): File_Name EINMAL aus der XML
-- ableiten und als Variable bereitstellen. Bislang baute jede der ~28 Katalog-
-- Sektionen über eine `filename_normalized`-CTE einen ZUSÄTZLICHEN read_xml nur für
-- den (datei-weit konstanten) File_Name auf — DuckDB dedupliziert die zwei
-- read_xml-Scans pro Statement NICHT, was die Parse-Last je Sektion verdoppelte
-- (~2,3 s → ~1,05 s ohne den Zweit-Scan). filename_normalized liest jetzt diese
-- Variable; das Ergebnis ist bit-identisch (gleiche Ableitung, nur einmal berechnet).
-- KONSOLIDIERTER ROOT-READ: die
-- Root-Attribute (`/FMSaveAsXML/@…`) wurden zuvor von DREI read_xml_objects-Aufrufen
-- separat gelesen (fm_file-Ableitung, XMLMetadata, FilesCatalog) — je ein Whole-Doc-
-- DOM-Parse. Da Root-Attribute strukturell NICHT per record_element streambar sind
-- (Root = ganzes Dokument), werden sie hier EINMAL in eine Temp-Tabelle gelesen und
-- von allen drei Konsumenten genutzt → 3 → 1 Whole-Doc-Parse, bit-identisch.
CREATE OR REPLACE TEMP TABLE _root_attrs AS
SELECT
    xml_extract_text(xml, '/FMSaveAsXML/@File')[1] AS file_full,
    regexp_replace(xml_extract_text(xml, '/FMSaveAsXML/@File')[1], '\.fmp12$', '') AS file_name,
    xml_extract_text(xml, '/FMSaveAsXML/@UUID')[1] AS file_uuid,
    xml_extract_text(xml, '/FMSaveAsXML/@version')[1] AS xml_version,
    xml_extract_text(xml, '/FMSaveAsXML/@Source')[1] AS fm_version,
    COALESCE(xml_extract_text(xml, '/FMSaveAsXML/@Has_DDR_INFO')[1], 'False') AS has_ddr_info,
    xml_extract_text(xml, '/FMSaveAsXML/@locale')[1] AS locale
FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'));

SET VARIABLE fm_file = (SELECT file_name FROM _root_attrs);


-- ========================================
-- SchemaInfo (Versions-Persistenz)
-- ========================================
-- Speichert den Schema-Stand (Version + Content-Hash + Timestamp) nach jedem
-- erfolgreichen Import. Wird vom convert_fm_xml.sh-Skript zur Drift-Detection
-- gelesen. Historie bleibt erhalten — aktueller Stand =
-- arg_max(SchemaInfo.* ORDER BY Schema_Built_At).
CREATE TABLE IF NOT EXISTS SchemaInfo (
    Schema_Version VARCHAR NOT NULL,
    Schema_Hash VARCHAR NOT NULL,
    Schema_Built_At TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    Builder_Notes VARCHAR,
    PRIMARY KEY (Schema_Version, Schema_Hash, Schema_Built_At)
);


-- ========================================
-- XML Metadata (Root-Attribut-Informationen)
-- ========================================
-- Tabelle für XML-Metadaten aller importierten Dateien
-- HINWEIS: Diese Daten sind auch in FilesCatalog verfügbar,
-- XMLMetadata wird aus historischen Gründen beibehalten
CREATE TABLE IF NOT EXISTS XMLMetadata (
    Has_DDR_INFO VARCHAR,
    XML_Version VARCHAR,
    FileMaker_Version VARCHAR,
    Filename VARCHAR,
    File_UUID VARCHAR,
    Locale VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (File_UUID, File_Name)
);

-- @P1_SECTION:main@
-- XMLMetadata befüllen — aus dem konsolidierten _root_attrs (kein eigener Root-Read).
INSERT INTO XMLMetadata
SELECT
    has_ddr_info as Has_DDR_INFO,
    xml_version as XML_Version,
    fm_version as FileMaker_Version,
    file_full as Filename,
    file_uuid as File_UUID,
    locale as Locale,
    getvariable('fm_file') as File_Name
FROM _root_attrs
ON CONFLICT (File_UUID, File_Name) DO UPDATE SET
    Has_DDR_INFO = EXCLUDED.Has_DDR_INFO,
    XML_Version = EXCLUDED.XML_Version,
    FileMaker_Version = EXCLUDED.FileMaker_Version,
    Filename = EXCLUDED.Filename,
    Locale = EXCLUDED.Locale;


-- ========================================
-- FilesCatalog (Multi-File Support)
-- ========================================
-- Tabelle für Metadaten aller importierten FileMaker-Dateien
-- Wird bei jedem Import aktualisiert (UPSERT)
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS FilesCatalog (
    File_Name VARCHAR PRIMARY KEY,          -- Dateiname ohne .fmp12 Suffix
    File_FullName VARCHAR,                  -- Dateiname mit .fmp12 Suffix
    File_UUID VARCHAR,                      -- UUID der Datei (aus XML); KEIN UNIQUE: geklonte
                                            -- FileMaker-Dateien ("Kopie speichern unter…") teilen
                                            -- dieselbe interne UUID. Identität liegt auf File_Name (PK).
    FileMaker_Version VARCHAR,              -- FileMaker Version (z.B. "ProAdvanced 21.0.2.206")
    Has_DDR_INFO BOOLEAN DEFAULT FALSE,     -- DDR-Info verfügbar?
    Import_Timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,  -- Zeitpunkt des letzten Imports
    XML_Path VARCHAR                        -- Pfad zur XML-Quelldatei
);

-- FilesCatalog befüllen (UPSERT bei wiederholten Importen)
-- @P1_SECTION:main@
INSERT INTO FilesCatalog (File_Name, File_FullName, File_UUID, FileMaker_Version, Has_DDR_INFO, Import_Timestamp, XML_Path)
SELECT
    file_name as File_Name,
    file_full as File_FullName,
    file_uuid as File_UUID,
    fm_version as FileMaker_Version,
    has_ddr_info = 'True' as Has_DDR_INFO,
    (now() AT TIME ZONE 'UTC') as Import_Timestamp,   -- explizit UTC (TZ-unabhängig, s. devcontainer Etc/UTC)
    getvariable('fm_xml') as XML_Path
FROM _root_attrs
ON CONFLICT (File_Name) DO UPDATE SET
    -- Audit: File_FullName/File_UUID fehlten (stale nach Re-Export mit
    -- geänderter UUID). Jede Nicht-PK-Spalte gehört in SET.
    File_FullName = EXCLUDED.File_FullName,
    File_UUID = EXCLUDED.File_UUID,
    Import_Timestamp = EXCLUDED.Import_Timestamp,
    FileMaker_Version = EXCLUDED.FileMaker_Version,
    Has_DDR_INFO = EXCLUDED.Has_DDR_INFO,
    XML_Path = EXCLUDED.XML_Path;


-- DuplicateAbsorptions
-- @END_P1_SECTION@
-- DuplicateAbsorptions — Dup-Absorption-Zensus (Monitoring, additiv).
-- Der Per-File-Upsert (ON CONFLICT auf UUID-PK) kollabiert Quellobjekte mit
-- identischer UUID still zu einer Zeile (Quelldefekt: FileMaker-Export
-- mit doppelten UUIDs, deterministisch last-write-wins). Dieser Zensus schreibt je
-- (Katalog, Datei) die Zahl der GEPARSTEN Quell-Records (VOR dem Upsert-Dedup);
-- der P6-Check v_check_absorbed_dups vergleicht live gegen die gespeicherten
-- Zeilen und weist die Differenz (= absorbierte Dubletten) im Import-Report aus.
-- Chunk_Seq: beim Sub-Chunking (--split) schreibt jeder Chunk seine eigene Zeile
-- (Chunk_Seq = seq_offset, unsplit = 0) — der Check summiert je (Katalog, Datei).
-- Das ist robust gegen Dup-Paare, die über eine Chunk-Grenze gespalten werden
-- (die Quell-Summe zählt schlicht alle geparsten Records), und verträgt den
-- parallelen Chunk-Merge (ON CONFLICT DO NOTHING trifft nur identische Chunk-Zeilen).
-- Kein Zeilen-Erhalt, keine Verhaltensänderung — reines Sichtbarmachen.
CREATE TABLE IF NOT EXISTS DuplicateAbsorptions (
    File_Name VARCHAR NOT NULL,
    Catalog VARCHAR NOT NULL,          -- Tabellenname, z. B. 'StepsForScripts'
    PK_Columns VARCHAR,                -- Provenienz, z. B. 'Step_UUID,File_Name'
    Chunk_Seq BIGINT NOT NULL DEFAULT 0,
    Source_Records BIGINT,             -- geparste Quell-Records dieses Chunks
    PRIMARY KEY (Catalog, File_Name, Chunk_Seq)
);

-- DuplicateAbsorptionDetails — Objekt-Merkmale der KOLLIDIERENDEN Objekte je Dup-UUID
-- (Erweiterung 2026-07-06). Der Zensus oben zählt nur den VERLUST; diese
-- Tabelle nennt zusätzlich Typ + Name der Objekte, die still kollabiert sind — damit
-- der Entwickler die Schwere einschätzen und im Export gezielt suchen kann. Befüllt aus
-- dem Pre-Dedup-Rowset (vor dem ON-CONFLICT-Kollaps), je kollidierendem Vorkommen eine
-- Zeile, NUR für UUIDs mit COUNT(*)>1 (korpusweit ~wenige Zeilen → winzig). Rein additiv
-- (Anzeige), kein Zeilen-Erhalt, keine synthetischen UUIDs. Occurrence_Seq numeriert die
-- Vorkommen einer UUID in XML-Reihenfolge (1,2,…) → der Namens-/Kontext-UNTERSCHIED der
-- Zwillinge ist das eigentliche Signal (z. B. dasselbe UUID in zwei verschiedenen Scripts).
CREATE TABLE IF NOT EXISTS DuplicateAbsorptionDetails (
    File_Name VARCHAR NOT NULL,
    Catalog VARCHAR NOT NULL,          -- Tabellenname, z. B. 'ScriptCatalog'
    Object_UUID VARCHAR NOT NULL,      -- die doppelt vergebene Quell-UUID
    Object_Name VARCHAR,               -- Name des Objekts (bzw. Container-Script bei Steps)
    Object_Type VARCHAR,               -- Objekttyp (Script/Folder/Separator, ScriptStep …)
    Occurrence_Seq BIGINT NOT NULL,    -- 1,2,… je Vorkommen der UUID (XML-Reihenfolge)
    Chunk_Seq BIGINT NOT NULL DEFAULT 0,
    -- Kontext-/Klartext-Spalten (Schema 1.17.0): die absorbierten Objekte fehlen nach
    -- dem Import im Katalog — diese Spalten sind die einzige Spur, über die der
    -- Entwickler das Objekt in seiner Lösung wiederfindet.
    Parent_Name VARCHAR,               -- Container-Kontext (Script bei Steps, Layout bei LayoutObjects)
    Position VARCHAR,                  -- Fundstelle im Container (z. B. 'Step 12', Listen-Position)
    Display_Text VARCHAR,              -- Klartext-Identifikation (gedeckelt, s. Befüller)
    Payload_XML VARCHAR,               -- Roh-XML-Ausschnitt (hart gedeckelt; nur wo das Fragment vorliegt)
    -- UUID-Healing (Schema 1.19.0): Mapping Original-UUID ↔ Ersatz-UUID je Vorkommen.
    -- Der Zensus ist damit der Abstraktions-Layer der Heilung — beide Richtungen
    -- (Original→Ersatz für „unter welcher Katalog-UUID erreichbar", Ersatz→Original
    -- für externe Tools/XML-Textsuche) sind eine Zensus-Abfrage.
    Healed_UUID VARCHAR,               -- vergebene Ersatz-UUID (NULL = Original behalten bzw. absorbiert)
    Heal_Status VARCHAR,               -- 'kept-original' | 'healed' | 'absorbed' (3A/nicht heilbar/Schalter aus)
    Discriminator VARCHAR,             -- verwendeter Identitätswert (z. B. 'script_id=421') — macht die
                                       -- Stabilitätsgrundlage der Ersatz-UUID auditierbar
    PRIMARY KEY (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq)
);

-- Kontext-Spalten für inkrementelle DBs ohne Force-Rebuild (Muster Step_XML).
ALTER TABLE DuplicateAbsorptionDetails ADD COLUMN IF NOT EXISTS Parent_Name VARCHAR;
ALTER TABLE DuplicateAbsorptionDetails ADD COLUMN IF NOT EXISTS Position VARCHAR;
ALTER TABLE DuplicateAbsorptionDetails ADD COLUMN IF NOT EXISTS Display_Text VARCHAR;
ALTER TABLE DuplicateAbsorptionDetails ADD COLUMN IF NOT EXISTS Payload_XML VARCHAR;
ALTER TABLE DuplicateAbsorptionDetails ADD COLUMN IF NOT EXISTS Healed_UUID VARCHAR;
ALTER TABLE DuplicateAbsorptionDetails ADD COLUMN IF NOT EXISTS Heal_Status VARCHAR;
ALTER TABLE DuplicateAbsorptionDetails ADD COLUMN IF NOT EXISTS Discriminator VARCHAR;

-- MergeAbsorptions — Persistenz des katmerge-a2-Dup-Reports (Schema 1.17.0).
-- Befüllt NICHT hier, sondern von ingestion/lib/convert_turbo.sh nach dem
-- Chunk-Merge (best-effort, analog zur a2-Warnzeile). Die DDL liegt in P1, damit
-- JEDE DB die Tabelle trägt (meist leer) und Dashboard-SQL nie auf einen
-- Binder-Error läuft. Ursachen am Merge-Punkt nicht sicher unterscheidbar:
-- Chunk-Overlap (Converter-Artefakt, kein Lösungs-Defekt) ODER Klon-Datei mit
-- identischem internem File_Name (echte UUID-Kollision, Klasse-A-Variante).
CREATE TABLE IF NOT EXISTS MergeAbsorptions (
    Table_Name VARCHAR NOT NULL,       -- Katalogtabelle, deren Merge Dubletten absorbierte
    File_Name VARCHAR,                 -- betroffene Datei (NULL, wenn nicht attribuierbar)
    Absorbed_Count BIGINT,             -- absorbierte PK-Dubletten
    Merge_Path VARCHAR,                -- 'catmerge' (Part-Pfad meldet nicht separat)
    Run_Timestamp TIMESTAMP            -- Zeitpunkt des Merge-Laufs (UTC)
);

-- ExternalDataSourceCatalog
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS ExternalDataSourceCatalog (
    DS_ID BIGINT,
    DS_Name VARCHAR,
    DS_Type VARCHAR,
    Path VARCHAR,
    DS_UUID VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (DS_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
ds_records AS (
    SELECT id, name, type, File, UUID
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='ExternalDataSourceCatalog',
        record_element='ExternalDataSource',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'type': 'VARCHAR',
            'File': 'STRUCT(UniversalPathList VARCHAR)',
            'UUID': 'STRUCT("#text" VARCHAR, "accountName" VARCHAR, "modifications" BIGINT, "timestamp" VARCHAR, "userName" VARCHAR)'
        }
    )
),
ds_healed AS (
    -- UUID-Healing (H1): Survivor = kleinste DS_ID je UUID behält die Original-UUID,
    -- weitere Zwillinge erhalten im INSERT unten die deterministische Ersatz-UUID
    -- (fm_heal_pick, Prelude). Doppel-Serialisierung (gleiche UUID UND gleiche ID)
    -- kollabiert weiterhin korrekt: Zeilen mit identischem Diskriminator erhalten
    -- identische UUIDs → ON CONFLICT greift wie bisher.
    -- Zweiter Hash-Partition-Pass auf dem bereits gelesenen Rowset — kein XML-Re-Scan.
    SELECT dr.*,
           (dr.UUID->>'#text' IS NULL OR dr.id IS NULL  -- NULL-id: kein Diskriminator → nie heilen
            OR dr.id = MIN(dr.id) OVER (PARTITION BY dr.UUID->>'#text')) AS is_survivor
    FROM ds_records dr
)
INSERT INTO ExternalDataSourceCatalog
SELECT
    dr.id AS DS_ID,
    dr.name AS DS_Name,
    dr.type AS DS_Type,
    dr.File.UniversalPathList AS Path,
    fm_heal_pick(dr.is_survivor, 'ExternalDataSourceCatalog', fn.File_Name,
                 dr.UUID->>'#text', 'ds_id=' || dr.id::VARCHAR) AS DS_UUID,
    fn.File_Name as File_Name
FROM ds_healed dr
CROSS JOIN filename_normalized fn
ON CONFLICT (DS_UUID, File_Name) DO UPDATE SET
    DS_ID = EXCLUDED.DS_ID,
    DS_Name = EXCLUDED.DS_Name,
    DS_Type = EXCLUDED.DS_Type,
    Path = EXCLUDED.Path;

-- Zensus (Dup-Absorption): geparste Quell-Records, minimaler Re-Read (nur id).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'ExternalDataSourceCatalog', 'DS_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM read_xml(
    getvariable('fm_xml'),
    root_element='ExternalDataSourceCatalog',
    record_element='ExternalDataSource',
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'id': 'BIGINT'}
)
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (ExternalDataSourceCatalog): Name der kollidierenden
-- Datenquellen je doppelt vergebener UUID. Liest denselben Quell-Rowset wie der
-- Katalog-INSERT oben (kein Zeilenfilter). DELETE-vor-INSERT hält den Detail-Satz
-- je (Katalog, Datei) beim Re-Import frisch (analog zum per-Datei-Overwrite des
-- Zensus). Bit-identisch zum Katalog-INSERT (rein additiv, eigene Tabelle).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'ExternalDataSourceCatalog'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        id,
        UUID->>'#text' AS Object_UUID,
        name AS Object_Name,
        'ExternalDataSource' AS Object_Type,
        ROW_NUMBER() OVER () AS xml_ord
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='ExternalDataSourceCatalog',
        record_element='ExternalDataSource',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'UUID': 'STRUCT("#text" VARCHAR)'
        }
    )
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H1): Survivor-/Heal-Markierung, identische Logik wie im Katalog-INSERT
-- oben (Survivor = kleinste ID; Doppel-Serialisierung — gleiche UUID+ID — bleibt
-- 'absorbed', nur das jeweils erste Vorkommen einer (UUID, ID)-Identität trägt den
-- Katalog-Status). Der Zensus ist damit das persistierte Mapping Original↔Ersatz.
marked AS (
    SELECT s.*,
           (s.id IS NULL  -- NULL-id: kein Diskriminator → wie Survivor behandeln (nie 'healed')
            OR s.id = MIN(s.id) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.id ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'ExternalDataSourceCatalog' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    -- Kontext: Datenquellen sind Top-Level → kein Container; Position = Stelle
    -- in der "Externe Datenquellen verwalten"-Liste (XML-Reihenfolge, 1-basiert).
    NULL AS Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name, 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('ExternalDataSourceCatalog', getvariable('fm_file'), s.Object_UUID,
                           'ds_id=' || s.id::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'ds_id=' || s.id::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;


-- BaseTableCatalog
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS BaseTableCatalog (
    BT_ID BIGINT,
    BT_Name VARCHAR,
    BT_UUID VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (BT_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
bt_records AS (
    SELECT id, name, UUID
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='BaseTableCatalog',
        record_element='BaseTable',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'UUID': 'STRUCT("#text" VARCHAR, "modifications" BIGINT, "userName" VARCHAR, "accountName" VARCHAR, "timestamp" VARCHAR)'
        }
    )
),
bt_healed AS (
    -- UUID-Healing (H1): Survivor = kleinste BT_ID je UUID behält die Original-UUID,
    -- weitere Zwillinge erhalten im INSERT unten die deterministische Ersatz-UUID
    -- (fm_heal_pick, Prelude). Doppel-Serialisierung (gleiche UUID UND gleiche ID)
    -- kollabiert weiterhin korrekt: Zeilen mit identischem Diskriminator erhalten
    -- identische UUIDs → ON CONFLICT greift wie bisher.
    -- Zweiter Hash-Partition-Pass auf dem bereits gelesenen Rowset — kein XML-Re-Scan.
    SELECT br.*,
           (br.UUID->>'#text' IS NULL OR br.id IS NULL  -- NULL-id: kein Diskriminator → nie heilen
            OR br.id = MIN(br.id) OVER (PARTITION BY br.UUID->>'#text')) AS is_survivor
    FROM bt_records br
)
INSERT INTO BaseTableCatalog
SELECT
    br.id AS BT_ID,
    xml_unescape(br.name) AS BT_Name,
    fm_heal_pick(br.is_survivor, 'BaseTableCatalog', fn.File_Name,
                 br.UUID->>'#text', 'table_id=' || br.id::VARCHAR) AS BT_UUID,
    fn.File_Name as File_Name
FROM bt_healed br
CROSS JOIN filename_normalized fn
ON CONFLICT (BT_UUID, File_Name) DO UPDATE SET
    BT_ID = EXCLUDED.BT_ID,
    BT_Name = EXCLUDED.BT_Name;

-- Zensus (Dup-Absorption): geparste Quell-Records, minimaler Re-Read (nur id).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'BaseTableCatalog', 'BT_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM read_xml(
    getvariable('fm_xml'),
    root_element='BaseTableCatalog',
    record_element='BaseTable',
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'id': 'BIGINT'}
)
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (BaseTableCatalog): Name der kollidierenden Tabellen je
-- doppelt vergebener UUID. Liest denselben Quell-Rowset wie der Katalog-INSERT
-- oben (kein Zeilenfilter). DELETE-vor-INSERT hält den Detail-Satz je (Katalog,
-- Datei) beim Re-Import frisch (analog zum per-Datei-Overwrite des Zensus).
-- Bit-identisch zum Katalog-INSERT (rein additiv, eigene Tabelle).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'BaseTableCatalog'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        id,
        UUID->>'#text' AS Object_UUID,
        xml_unescape(name) AS Object_Name,
        'BaseTable' AS Object_Type,
        ROW_NUMBER() OVER () AS xml_ord
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='BaseTableCatalog',
        record_element='BaseTable',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'UUID': 'STRUCT("#text" VARCHAR)'
        }
    )
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H1): Survivor-/Heal-Markierung, identische Logik wie im Katalog-INSERT
-- oben (Survivor = kleinste ID; Doppel-Serialisierung — gleiche UUID+ID — bleibt
-- 'absorbed', nur das jeweils erste Vorkommen einer (UUID, ID)-Identität trägt den
-- Katalog-Status). Der Zensus ist damit das persistierte Mapping Original↔Ersatz.
marked AS (
    SELECT s.*,
           (s.id IS NULL  -- NULL-id: kein Diskriminator → wie Survivor behandeln (nie 'healed')
            OR s.id = MIN(s.id) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.id ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'BaseTableCatalog' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    -- Kontext: Basistabellen sind Top-Level → kein Container; Position = Stelle
    -- in der "Datenbank verwalten"-Tabellenliste (XML-Reihenfolge, 1-basiert).
    NULL AS Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name, 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('BaseTableCatalog', getvariable('fm_file'), s.Object_UUID,
                           'table_id=' || s.id::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'table_id=' || s.id::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;


-- TableOccurrenceCatalog
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS TableOccurrenceCatalog (
    TO_ID BIGINT,
    TO_Name VARCHAR,
    TO_Type VARCHAR,
    TO_UUID VARCHAR,
    DS_ID BIGINT,
    DS_Name VARCHAR,
    DS_UUID VARCHAR,
    BT_ID BIGINT,
    BT_Name VARCHAR,
    BT_UUID VARCHAR,
    View_State VARCHAR,
    Box_Height BIGINT,
    Coord_Top BIGINT,
    Coord_Left BIGINT,
    Coord_Bottom BIGINT,
    Coord_Right BIGINT,
    Color_R BIGINT,
    Color_G BIGINT,
    Color_B BIGINT,
    Color_Alpha DOUBLE,
    File_Name VARCHAR,
    PRIMARY KEY (TO_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
to_records AS (
    SELECT *
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='TableOccurrenceCatalog',
        record_element='TableOccurrence',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'type': 'VARCHAR',
            'View': 'VARCHAR',
            'height': 'BIGINT',
            'UUID': 'STRUCT("#text" VARCHAR, "accountName" VARCHAR, "modifications" BIGINT, "timestamp" VARCHAR, "userName" VARCHAR)',
            'BaseTableSourceReference': 'STRUCT(
                "DataSourceReference" STRUCT(
                    "id" BIGINT,
                    "name" VARCHAR,
                    "UUID" VARCHAR
                ),
                "BaseTableReference" STRUCT(
                    "id" BIGINT,
                    "name" VARCHAR,
                    "UUID" VARCHAR
                )
            )',
            'CoordRect': 'STRUCT("top" BIGINT, "left" BIGINT, "bottom" BIGINT, "right" BIGINT)',
            'Color': 'STRUCT("red" BIGINT, "green" BIGINT, "blue" BIGINT, "alpha" DOUBLE)'
        }
    )
),
to_healed AS (
    -- UUID-Healing (H1): Survivor = kleinste TO_ID je UUID behält die Original-UUID,
    -- weitere Zwillinge erhalten im INSERT unten die deterministische Ersatz-UUID
    -- (fm_heal_pick, Prelude). Geheilt wird NUR die eigene TO_UUID (PK) — die
    -- Fremd-UUIDs DS_UUID/BT_UUID bleiben roh (Kaskade auf Referenzen ist ein
    -- separater Schritt). Doppel-Serialisierung (gleiche UUID UND gleiche ID)
    -- kollabiert weiterhin korrekt: Zeilen mit identischem Diskriminator erhalten
    -- identische UUIDs → ON CONFLICT greift wie bisher.
    -- Zweiter Hash-Partition-Pass auf dem bereits gelesenen Rowset — kein XML-Re-Scan.
    SELECT tr.*,
           (tr.UUID->>'#text' IS NULL OR tr.id IS NULL  -- NULL-id: kein Diskriminator → nie heilen
            OR tr.id = MIN(tr.id) OVER (PARTITION BY tr.UUID->>'#text')) AS is_survivor
    FROM to_records tr
)
INSERT INTO TableOccurrenceCatalog (
    TO_ID, TO_Name, TO_Type, TO_UUID,
    DS_ID, DS_Name, DS_UUID,
    BT_ID, BT_Name, BT_UUID,
    View_State, Box_Height,
    Coord_Top, Coord_Left, Coord_Bottom, Coord_Right,
    Color_R, Color_G, Color_B, Color_Alpha,
    File_Name
)
SELECT
    tr.id AS TO_ID,
    xml_unescape(tr.name) AS TO_Name,
    tr.type AS TO_Type,
    fm_heal_pick(tr.is_survivor, 'TableOccurrenceCatalog', fn.File_Name,
                 tr.UUID->>'#text', 'to_id=' || tr.id::VARCHAR) AS TO_UUID,
    tr.BaseTableSourceReference.DataSourceReference.id AS DS_ID,
    tr.BaseTableSourceReference.DataSourceReference.name AS DS_Name,
    tr.BaseTableSourceReference.DataSourceReference.UUID AS DS_UUID,
    tr.BaseTableSourceReference.BaseTableReference.id AS BT_ID,
    xml_unescape(tr.BaseTableSourceReference.BaseTableReference.name) AS BT_Name,
    tr.BaseTableSourceReference.BaseTableReference.UUID AS BT_UUID,
    tr.View AS View_State,
    tr.height AS Box_Height,
    tr.CoordRect.top AS Coord_Top,
    tr.CoordRect."left" AS Coord_Left,
    tr.CoordRect.bottom AS Coord_Bottom,
    tr.CoordRect."right" AS Coord_Right,
    tr.Color.red AS Color_R,
    tr.Color.green AS Color_G,
    tr.Color.blue AS Color_B,
    tr.Color.alpha AS Color_Alpha,
    fn.File_Name as File_Name
FROM to_healed tr
CROSS JOIN filename_normalized fn
ON CONFLICT (TO_UUID, File_Name) DO UPDATE SET
    TO_ID = EXCLUDED.TO_ID,
    TO_Name = EXCLUDED.TO_Name,
    TO_Type = EXCLUDED.TO_Type,
    DS_ID = EXCLUDED.DS_ID,
    DS_Name = EXCLUDED.DS_Name,
    DS_UUID = EXCLUDED.DS_UUID,
    BT_ID = EXCLUDED.BT_ID,
    BT_Name = EXCLUDED.BT_Name,
    BT_UUID = EXCLUDED.BT_UUID,
    View_State = EXCLUDED.View_State,
    Box_Height = EXCLUDED.Box_Height,
    Coord_Top = EXCLUDED.Coord_Top,
    Coord_Left = EXCLUDED.Coord_Left,
    Coord_Bottom = EXCLUDED.Coord_Bottom,
    Coord_Right = EXCLUDED.Coord_Right,
    Color_R = EXCLUDED.Color_R,
    Color_G = EXCLUDED.Color_G,
    Color_B = EXCLUDED.Color_B,
    Color_Alpha = EXCLUDED.Color_Alpha;

-- Zensus (Dup-Absorption): geparste Quell-Records, minimaler Re-Read (nur id).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'TableOccurrenceCatalog', 'TO_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM read_xml(
    getvariable('fm_xml'),
    root_element='TableOccurrenceCatalog',
    record_element='TableOccurrence',
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'id': 'BIGINT'}
)
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (TableOccurrenceCatalog): Name der kollidierenden
-- Tabellenauftreten je doppelt vergebener UUID. Liest denselben Quell-Rowset wie
-- der Katalog-INSERT oben (kein Zeilenfilter). DELETE-vor-INSERT hält den Detail-
-- Satz je (Katalog, Datei) beim Re-Import frisch (analog zum per-Datei-Overwrite
-- des Zensus). Bit-identisch zum Katalog-INSERT (rein additiv, eigene Tabelle).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'TableOccurrenceCatalog'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        id,
        UUID->>'#text' AS Object_UUID,
        xml_unescape(name) AS Object_Name,
        'TableOccurrence' AS Object_Type,
        xml_unescape(BaseTableSourceReference.BaseTableReference.name) AS Parent_Name,
        ROW_NUMBER() OVER () AS xml_ord
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='TableOccurrenceCatalog',
        record_element='TableOccurrence',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'UUID': 'STRUCT("#text" VARCHAR)',
            'BaseTableSourceReference': 'STRUCT("BaseTableReference" STRUCT("name" VARCHAR))'
        }
    )
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H1): Survivor-/Heal-Markierung, identische Logik wie im Katalog-INSERT
-- oben (Survivor = kleinste ID; Doppel-Serialisierung — gleiche UUID+ID — bleibt
-- 'absorbed', nur das jeweils erste Vorkommen einer (UUID, ID)-Identität trägt den
-- Katalog-Status). Der Zensus ist damit das persistierte Mapping Original↔Ersatz.
marked AS (
    SELECT s.*,
           (s.id IS NULL  -- NULL-id: kein Diskriminator → wie Survivor behandeln (nie 'healed')
            OR s.id = MIN(s.id) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.id ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'TableOccurrenceCatalog' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    -- Kontext: Parent = referenzierte Basistabelle (Quelle des Auftretens);
    -- Position = Stelle in der TableOccurrence-Liste (XML-Reihenfolge, 1-basiert).
    s.Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name, 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('TableOccurrenceCatalog', getvariable('fm_file'), s.Object_UUID,
                           'to_id=' || s.id::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'to_id=' || s.id::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;


-- RelationshipCatalog
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS RelationshipCatalog (
    Rel_ID BIGINT,
    Left_TO_Name VARCHAR,
    Left_TO_ID BIGINT,
    Left_TO_UUID VARCHAR,
    Left_Delete BOOLEAN,
    Left_Create BOOLEAN,
    Right_TO_Name VARCHAR,
    Right_TO_ID BIGINT,
    Right_TO_UUID VARCHAR,
    Right_Delete BOOLEAN,
    Right_Create BOOLEAN,
    Operator VARCHAR,
    -- Predicate_Index: 1-basierter Index des Join-Prädikats innerhalb der Relation.
    -- Mehrfeld-Joins (FileMaker JoinPredicateList membercount > 1) erzeugen pro
    -- Prädikat eine eigene Zeile; ohne diesen Schlüssel-Bestandteil kollabierte das
    -- ON CONFLICT (Rel_ID, File_Name) frühere Prädikate auf nur eines (zuletzt gewinnt).
    Predicate_Index BIGINT,
    Left_Field_Name VARCHAR,
    Left_Field_ID BIGINT,
    Left_Field_UUID VARCHAR,
    Left_Field_TO_Name VARCHAR,
    Left_Field_TO_UUID VARCHAR,
    Right_Field_Name VARCHAR,
    Right_Field_ID BIGINT,
    Right_Field_UUID VARCHAR,
    Right_Field_TO_Name VARCHAR,
    Right_Field_TO_UUID VARCHAR,
    -- Sortier-Konfiguration je TO-Seite (FileMaker „Datensätze sortieren").
    -- Pro Relation/Seite konstant → über alle Predicate_Index-Zeilen wiederholt
    -- (wie Left_TO_Name). _Enabled = SortSpecification@value; _Fields = kommaseparierte
    -- Sortierfelder (mit „(absteigend)"-Marker bei Descending), NULL wenn deaktiviert.
    -- _Field_UUIDs = Feld-UUIDs der Sortierfolge (PrimaryField) → speisen in P4 die
    -- Relationship→Field-Graph-Links (Link_Role='sort_field'), damit die Sort-Abhängigkeit
    -- in der Where-used-Analyse des Felds auftaucht.
    Left_Sort_Enabled BOOLEAN,
    Left_Sort_Fields VARCHAR,
    Left_Sort_Field_UUIDs VARCHAR[],
    -- _Field_IDs / _Field_TO_UUIDs: index-gleich zu _Field_UUIDs. Die FieldReference-UUID
    -- der Sortfelder ist kontext-synthetisch (pro Feld×TO) → P4 löst über (TO_UUID, Feld-ID)
    -- auf die kanonische Feld-UUID auf (analog Prädikatfelder). Feld-ID ist entity-frei.
    Left_Sort_Field_IDs BIGINT[],
    Left_Sort_Field_TO_UUIDs VARCHAR[],
    -- _ValueList_UUIDs: Custom-Sortierung nach Werteliste (<Sort type="Custom"> mit
    -- <ValueListReference>) je Seite. Nur Sort-Einträge MIT VL-UUID (list_filter, analog
    -- _Field_UUIDs). Speist in P4 Relationship→ValueList (sorts_by_valuelist, Subrole
    -- left/right) — vorher erschien eine NUR als Relationship-Sortier-Referenz genutzte
    -- Werteliste in Where-used/Dead-Code als ungenutzt.
    Left_Sort_ValueList_UUIDs VARCHAR[],
    Right_Sort_Enabled BOOLEAN,
    Right_Sort_Fields VARCHAR,
    Right_Sort_Field_UUIDs VARCHAR[],
    Right_Sort_Field_IDs BIGINT[],
    Right_Sort_Field_TO_UUIDs VARCHAR[],
    Right_Sort_ValueList_UUIDs VARCHAR[],
    File_Name VARCHAR,
    PRIMARY KEY (Rel_ID, File_Name, Predicate_Index)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
)
INSERT INTO RelationshipCatalog
SELECT
    id AS Rel_ID,
    xml_unescape(LeftTable.TableOccurrenceReference.name) AS Left_TO_Name,
    LeftTable.TableOccurrenceReference.id AS Left_TO_ID,
    LeftTable.TableOccurrenceReference.UUID AS Left_TO_UUID,
    LeftTable.cascadeDelete AS Left_Delete,
    LeftTable.cascadeCreate AS Left_Create,
    xml_unescape(RightTable.TableOccurrenceReference.name) AS Right_TO_Name,
    RightTable.TableOccurrenceReference.id AS Right_TO_ID,
    RightTable.TableOccurrenceReference.UUID AS Right_TO_UUID,
    RightTable.cascadeDelete AS Right_Delete,
    RightTable.cascadeCreate AS Right_Create,
    pe.jp.type AS Operator,
    pe.idx AS Predicate_Index,
    pe.jp.LeftField.FieldReference.name AS Left_Field_Name,
    pe.jp.LeftField.FieldReference.id AS Left_Field_ID,
    -- Externe TO-Seite: die Feld-Entität gehört der anderen Datei → FieldReference@UUID=""
    -- (leerer String). Als NULL normalisieren, damit P4 die kanonische Feld-UUID über
    -- (Field_TO_UUID, Field_ID) auflöst statt einen Leerstring-Link zu erzeugen (F-1b).
    NULLIF(pe.jp.LeftField.FieldReference.UUID, '') AS Left_Field_UUID,
    pe.jp.LeftField.FieldReference.TableOccurrenceReference.name AS Left_Field_TO_Name,
    pe.jp.LeftField.FieldReference.TableOccurrenceReference.UUID AS Left_Field_TO_UUID,
    pe.jp.RightField.FieldReference.name AS Right_Field_Name,
    pe.jp.RightField.FieldReference.id AS Right_Field_ID,
    NULLIF(pe.jp.RightField.FieldReference.UUID, '') AS Right_Field_UUID,
    pe.jp.RightField.FieldReference.TableOccurrenceReference.name AS Right_Field_TO_Name,
    pe.jp.RightField.FieldReference.TableOccurrenceReference.UUID AS Right_Field_TO_UUID,
    -- Sortierfelder je Seite (konstant über die Prädikat-Zeilen einer Relation):
    LeftTable.SortSpecification.value AS Left_Sort_Enabled,
    CASE WHEN LeftTable.SortSpecification.value
         THEN array_to_string(list_transform(LeftTable.SortSpecification.SortList.Sort,
                lambda s, i: s.PrimaryField.FieldReference.name
                  || CASE WHEN s.type = 'Descending' THEN ' (absteigend)' ELSE '' END), ', ')
         ELSE NULL END AS Left_Sort_Fields,
    -- Index-gleiche Arrays: erst die Sort-Liste auf Einträge MIT FieldReference-UUID
    -- filtern, dann UUID / id / TO-UUID daraus ableiten → alle drei bleiben ausgerichtet.
    CASE WHEN LeftTable.SortSpecification.value
         THEN list_transform(list_filter(LeftTable.SortSpecification.SortList.Sort,
                lambda s: s.PrimaryField.FieldReference.UUID IS NOT NULL),
                lambda s: s.PrimaryField.FieldReference.UUID)
         ELSE NULL END AS Left_Sort_Field_UUIDs,
    CASE WHEN LeftTable.SortSpecification.value
         THEN list_transform(list_filter(LeftTable.SortSpecification.SortList.Sort,
                lambda s: s.PrimaryField.FieldReference.UUID IS NOT NULL),
                lambda s: s.PrimaryField.FieldReference.id)
         ELSE NULL END AS Left_Sort_Field_IDs,
    CASE WHEN LeftTable.SortSpecification.value
         THEN list_transform(list_filter(LeftTable.SortSpecification.SortList.Sort,
                lambda s: s.PrimaryField.FieldReference.UUID IS NOT NULL),
                lambda s: s.PrimaryField.FieldReference.TableOccurrenceReference.UUID)
         ELSE NULL END AS Left_Sort_Field_TO_UUIDs,
    CASE WHEN LeftTable.SortSpecification.value
         THEN list_transform(list_filter(LeftTable.SortSpecification.SortList.Sort,
                lambda s: s.ValueListReference.UUID IS NOT NULL),
                lambda s: s.ValueListReference.UUID)
         ELSE NULL END AS Left_Sort_ValueList_UUIDs,
    RightTable.SortSpecification.value AS Right_Sort_Enabled,
    CASE WHEN RightTable.SortSpecification.value
         THEN array_to_string(list_transform(RightTable.SortSpecification.SortList.Sort,
                lambda s, i: s.PrimaryField.FieldReference.name
                  || CASE WHEN s.type = 'Descending' THEN ' (absteigend)' ELSE '' END), ', ')
         ELSE NULL END AS Right_Sort_Fields,
    CASE WHEN RightTable.SortSpecification.value
         THEN list_transform(list_filter(RightTable.SortSpecification.SortList.Sort,
                lambda s: s.PrimaryField.FieldReference.UUID IS NOT NULL),
                lambda s: s.PrimaryField.FieldReference.UUID)
         ELSE NULL END AS Right_Sort_Field_UUIDs,
    CASE WHEN RightTable.SortSpecification.value
         THEN list_transform(list_filter(RightTable.SortSpecification.SortList.Sort,
                lambda s: s.PrimaryField.FieldReference.UUID IS NOT NULL),
                lambda s: s.PrimaryField.FieldReference.id)
         ELSE NULL END AS Right_Sort_Field_IDs,
    CASE WHEN RightTable.SortSpecification.value
         THEN list_transform(list_filter(RightTable.SortSpecification.SortList.Sort,
                lambda s: s.PrimaryField.FieldReference.UUID IS NOT NULL),
                lambda s: s.PrimaryField.FieldReference.TableOccurrenceReference.UUID)
         ELSE NULL END AS Right_Sort_Field_TO_UUIDs,
    CASE WHEN RightTable.SortSpecification.value
         THEN list_transform(list_filter(RightTable.SortSpecification.SortList.Sort,
                lambda s: s.ValueListReference.UUID IS NOT NULL),
                lambda s: s.ValueListReference.UUID)
         ELSE NULL END AS Right_Sort_ValueList_UUIDs,
    fn.File_Name as File_Name
FROM read_xml(
    getvariable('fm_xml'),
    root_element='RelationshipCatalog',
    record_element='Relationship',
    max_depth=10,
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={
        'id': 'BIGINT',
        'LeftTable': 'STRUCT(
            cascadeCreate BOOLEAN,
            cascadeDelete BOOLEAN,
            "TableOccurrenceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR),
            "SortSpecification" STRUCT(
                value BOOLEAN,
                "SortList" STRUCT(
                    "Sort" STRUCT(
                        type VARCHAR,
                        "PrimaryField" STRUCT(FieldReference STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR,
                            "TableOccurrenceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR))),
                        "ValueListReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)
                    )[]
                )
            )
        )',
        'RightTable': 'STRUCT(
            cascadeCreate BOOLEAN,
            cascadeDelete BOOLEAN,
            "TableOccurrenceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR),
            "SortSpecification" STRUCT(
                value BOOLEAN,
                "SortList" STRUCT(
                    "Sort" STRUCT(
                        type VARCHAR,
                        "PrimaryField" STRUCT(FieldReference STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR,
                            "TableOccurrenceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR))),
                        "ValueListReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)
                    )[]
                )
            )
        )',
        'JoinPredicateList': 'STRUCT(
            "JoinPredicate" STRUCT(
                type VARCHAR,
                "LeftField" STRUCT(
                    FieldReference STRUCT(
                        id BIGINT, name VARCHAR, UUID VARCHAR,
                        "TableOccurrenceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)
                    )
                ),
                "RightField" STRUCT(
                    FieldReference STRUCT(
                        id BIGINT, name VARCHAR, UUID VARCHAR,
                        "TableOccurrenceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)
                    )
                )
            )[]
        )'
    }
)
-- list_transform hängt jedem Prädikat seinen 1-basierten Listenindex an, bevor
-- UNNEST die Liste in Zeilen auflöst → ein Mehrfeld-Join (membercount > 1) liefert
-- jetzt N Zeilen mit eindeutigem Predicate_Index statt einer (vgl. Schema-PK).
CROSS JOIN UNNEST(list_transform(JoinPredicateList.JoinPredicate, lambda jp, i: {idx: i, jp: jp})) AS t(pe)
CROSS JOIN filename_normalized fn
-- F-1b: strukturelle statt UUID-Gültigkeit. Der frühere UUID-IS-NOT-NULL-Filter verwarf
-- die GESAMTE Beziehung (alle Prädikat-Zeilen), wenn ein Prädikat-Feld auf einer externen
-- TO-Seite lag (FieldReference@UUID=""). Prädikat-Feld-id ist entity-frei und immer gesetzt
-- → als Gültigkeits-Kriterium tragfähig; die leere Feld-UUID wird oben zu NULL normalisiert
-- und in P4 über (Field_TO_UUID, Field_ID) kanonisch aufgelöst.
WHERE pe.jp.LeftField.FieldReference.id IS NOT NULL
  AND pe.jp.RightField.FieldReference.id IS NOT NULL
ON CONFLICT (Rel_ID, File_Name, Predicate_Index) DO UPDATE SET
    Left_TO_Name = EXCLUDED.Left_TO_Name,
    Left_TO_ID = EXCLUDED.Left_TO_ID,
    Left_TO_UUID = EXCLUDED.Left_TO_UUID,
    Left_Delete = EXCLUDED.Left_Delete,
    Left_Create = EXCLUDED.Left_Create,
    Right_TO_Name = EXCLUDED.Right_TO_Name,
    Right_TO_ID = EXCLUDED.Right_TO_ID,
    Right_TO_UUID = EXCLUDED.Right_TO_UUID,
    Right_Delete = EXCLUDED.Right_Delete,
    Right_Create = EXCLUDED.Right_Create,
    Operator = EXCLUDED.Operator,
    Left_Field_Name = EXCLUDED.Left_Field_Name,
    Left_Field_ID = EXCLUDED.Left_Field_ID,
    -- UPSERT-Drift (real eingetreten): Left/Right_Field_UUID fehlten in der
    -- SET-Liste → inkonsistente Zeile nach inkrementellem Re-Import, falsche
    -- left_field/right_field-Links. Regel: JEDE Nicht-PK-Spalte gehört in SET.
    Left_Field_UUID = EXCLUDED.Left_Field_UUID,
    Left_Field_TO_Name = EXCLUDED.Left_Field_TO_Name,
    Left_Field_TO_UUID = EXCLUDED.Left_Field_TO_UUID,
    Right_Field_Name = EXCLUDED.Right_Field_Name,
    Right_Field_ID = EXCLUDED.Right_Field_ID,
    Right_Field_UUID = EXCLUDED.Right_Field_UUID,
    Right_Field_TO_Name = EXCLUDED.Right_Field_TO_Name,
    Right_Field_TO_UUID = EXCLUDED.Right_Field_TO_UUID,
    Left_Sort_Enabled = EXCLUDED.Left_Sort_Enabled,
    Left_Sort_Fields = EXCLUDED.Left_Sort_Fields,
    Left_Sort_Field_UUIDs = EXCLUDED.Left_Sort_Field_UUIDs,
    Left_Sort_Field_IDs = EXCLUDED.Left_Sort_Field_IDs,
    Left_Sort_Field_TO_UUIDs = EXCLUDED.Left_Sort_Field_TO_UUIDs,
    Left_Sort_ValueList_UUIDs = EXCLUDED.Left_Sort_ValueList_UUIDs,
    Right_Sort_Enabled = EXCLUDED.Right_Sort_Enabled,
    Right_Sort_Fields = EXCLUDED.Right_Sort_Fields,
    Right_Sort_Field_UUIDs = EXCLUDED.Right_Sort_Field_UUIDs,
    Right_Sort_Field_IDs = EXCLUDED.Right_Sort_Field_IDs,
    Right_Sort_Field_TO_UUIDs = EXCLUDED.Right_Sort_Field_TO_UUIDs,
    Right_Sort_ValueList_UUIDs = EXCLUDED.Right_Sort_ValueList_UUIDs;

-- Zensus (Dup-Absorption): Quell-Rowset = ein Record je Join-Prädikat (UNNEST) mit
-- demselben UUID-Filter wie der Katalog-INSERT; minimaler Re-Read (nur Prädikat-UUIDs).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'RelationshipCatalog', 'Rel_ID,File_Name,Predicate_Index',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM (
    SELECT unnest(JoinPredicateList.JoinPredicate) AS jp
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='RelationshipCatalog',
        record_element='Relationship',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'JoinPredicateList': 'STRUCT(
                "JoinPredicate" STRUCT(
                    "LeftField" STRUCT(FieldReference STRUCT(id BIGINT)),
                    "RightField" STRUCT(FieldReference STRUCT(id BIGINT))
                )[]
            )'
        }
    )
)
-- Gleiches Gültigkeits-Kriterium wie der Katalog-INSERT (strukturell/id-basiert, F-1b).
WHERE jp.LeftField.FieldReference.id IS NOT NULL
  AND jp.RightField.FieldReference.id IS NOT NULL
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;


-- FieldsForTables
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS FieldsForTables (
    Table_ID BIGINT,
    Table_Name VARCHAR,
    Table_UUID VARCHAR,
    Field_ID BIGINT,
    Field_Name VARCHAR,
    Field_Type VARCHAR,
    Data_Type VARCHAR,
    Field_Comment VARCHAR,
    Field_UUID VARCHAR,
    Is_Global BOOLEAN,
    Max_Repetitions BIGINT,
    DDR_Hash VARCHAR,  -- DDR-Hash für Calculated Fields (ab FM21+)
    Calculation_Text VARCHAR,  -- Klartext-Formel aus <Text> CDATA (vollständiger als ChunkList)
    -- AutoEnter-Basisattribute (alle Typen)
    AutoEnter_Type VARCHAR,              -- 'Looked_up', 'SerialNumber', 'Calculated', 'ConstantData', etc.
    AutoEnter_ProhibitMod BOOLEAN,       -- Benutzer darf überschreiben?
    -- Lookup-Details (nur für AutoEnter_Type = 'Looked_up')
    Lookup_Field_Name VARCHAR,           -- Name des Quellfeldes
    Lookup_Field_UUID VARCHAR,           -- UUID des Quellfeldes
    Lookup_TO_Name VARCHAR,              -- Name der Beziehungs-TO
    Lookup_TO_UUID VARCHAR,              -- UUID der Beziehungs-TO
    Lookup_DontCopyIfEmpty BOOLEAN,      -- Leerwerte nicht übernehmen?
    Lookup_NoMatchOption VARCHAR,        -- 'DoNotCopy' oder 'ConstantData'
    -- AutoEnter Calculated-Details (nur für AutoEnter_Type = 'Calculated')
    AE_Calc_Text VARCHAR,               -- Klartext-Formel (komplementär zu Calculation_Text)
    AE_Calc_Hash VARCHAR,               -- DDR-Hash (komplementär zu DDR_Hash)
    AE_Calc_OverwriteExisting BOOLEAN,  -- Vorhandene Werte überschreiben?
    AE_Calc_AlwaysEvaluate BOOLEAN,     -- Bei jeder Änderung neu berechnen?
    -- ConstantData (nur für AutoEnter_Type = 'ConstantData')
    AE_ConstantData VARCHAR,            -- Fester Standardwert
    -- Validierung (Schema 1.5.0)
    Validation_Type VARCHAR,            -- 'OnlyDuringDataEntry' | 'Always'
    Validation_AllowOverride BOOLEAN,
    Validation_NotEmpty BOOLEAN,
    Validation_Unique BOOLEAN,
    Validation_Existing BOOLEAN,
    Validation_VL_ID BIGINT,            -- ValueList-Validierung (Where-used-Kante!)
    Validation_VL_Name VARCHAR,
    Validation_VL_UUID VARCHAR,
    -- Storage/Indexierung (Schema 1.5.0; Is_Global/Max_Repetitions oben)
    Storage_AutoIndex BOOLEAN,
    Storage_Index VARCHAR,              -- 'None' | 'All' | 'Minimal'
    Storage_StoreCalcResults BOOLEAN,   -- nur Calculated Fields
    -- SerialNumber-Details (nur AutoEnter_Type = 'SerialNumber')
    Serial_Increment VARCHAR,
    Serial_NextValue VARCHAR,
    Serial_Generate VARCHAR,            -- 'OnCreation' | 'OnCommit'
    -- Summary-Definition (nur fieldtype = 'Summary'; FieldReference-UUID ist
    -- kanonisch (BaseTable-Kontext, korpus-verifiziert) → direkte Where-used-Kante
    Summary_Operation VARCHAR,          -- 'Total' | 'Average' | 'Count' | 'List' | …
    Summary_Field_Name VARCHAR,
    Summary_Field_UUID VARCHAR,
    -- Validierung, Speicher-Indexsprache und Summary-Modifikatoren (Schema 1.10.0)
    Validation_AlwaysValidate BOOLEAN,   -- <Validation @alwaysValidate>
    Validation_StrictType VARCHAR,       -- <Strict>: 'FourDigitYear' | numerisch | Zeit (Token roh, kein Enum-Zwang)
    Validation_MaxChars BIGINT,         -- <MaximumSize> maximale Zeichenanzahl
    Validation_Range_From VARCHAR,       -- <Range @from> (Datum/Zeit/Zahl → VARCHAR)
    Validation_Range_To VARCHAR,         -- <Range @to>
    Validation_Calc_Text VARCHAR,        -- <Calculated><Calculation><Text> Prüf-Calc (Klartext)
    Validation_Calc_Hash VARCHAR,        -- <Calculated>…<DDRREF @hash> → validates_by_calc Graph-Kante
    Validation_Message VARCHAR,          -- <Message> statische eigene Fehlermeldung
    Validation_Message_Calc_Hash VARCHAR,-- <MessageCalc>…<DDRREF @hash> (Meldung per Berechnung)
    Storage_IndexLanguage VARCHAR,       -- <Storage><LanguageReference @name> Standard-Indexsprache
    Storage_IndexLanguage_ID BIGINT,     -- <Storage><LanguageReference @id>
    Summary_RestartEachGroup BOOLEAN,    -- <SummaryInfo @restartEachGroup> Ergebnis je Gruppe neu
    Summary_RepetitionMode VARCHAR,      -- <SummaryInfo @summarizeRepetition>: 'Together' | 'Individually'
    File_Name VARCHAR,
    PRIMARY KEY (Field_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
field_records AS (
    -- Rowset NACH UNNEST + Zeilenfiltern — identischer Zeilen-Scope wie der bisherige
    -- Katalog-INSERT (das Survivor-Window unten MUSS auf dem entfalteten, gefilterten
    -- Rowset laufen, nicht auf den FieldCatalog-Records).
    SELECT BaseTableReference, f
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='FieldsForTables',
        record_element='FieldCatalog',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'BaseTableReference': 'STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)',
            'ObjectList': 'STRUCT(
                "Field" STRUCT(
                    "id" BIGINT,
                    "name" VARCHAR,
                    "fieldtype" VARCHAR,
                    "datatype" VARCHAR,
                    "comment" VARCHAR,
                    "UUID" STRUCT("#text" VARCHAR),
                    "Storage" STRUCT(
                        "global" BOOLEAN,
                        "maxRepetitions" BIGINT,
                        "autoIndex" BOOLEAN,
                        "index" VARCHAR,
                        "storeCalculationResults" BOOLEAN,
                        "LanguageReference" STRUCT("name" VARCHAR, "id" BIGINT)
                    ),
                    "Validation" STRUCT(
                        "type" VARCHAR,
                        "alwaysValidate" BOOLEAN,
                        "allowOverride" BOOLEAN,
                        "notEmpty" BOOLEAN,
                        "unique" BOOLEAN,
                        "existing" BOOLEAN,
                        "Strict" VARCHAR,
                        "MaximumSize" BIGINT,
                        "Range" STRUCT("from" VARCHAR, "to" VARCHAR),
                        "Message" VARCHAR,
                        "Calculated" STRUCT("Calculation" STRUCT("DDRREF" STRUCT("hash" VARCHAR), "Text" VARCHAR)),
                        "MessageCalc" STRUCT("Calculation" STRUCT("DDRREF" STRUCT("hash" VARCHAR))),
                        "ValueListReference" STRUCT("id" BIGINT, "name" VARCHAR, "UUID" VARCHAR)
                    ),
                    "SummaryInfo" STRUCT(
                        "operation" VARCHAR,
                        "restartEachGroup" BOOLEAN,
                        "summarizeRepetition" VARCHAR,
                        "SummaryField" STRUCT(
                            "FieldReference" STRUCT("id" BIGINT, "name" VARCHAR, "UUID" VARCHAR)
                        )
                    ),
                    "Calculation" STRUCT("DDRREF" STRUCT("hash" VARCHAR), "Text" VARCHAR),
                    "AutoEnter" STRUCT(
                        "type" VARCHAR,
                        "prohibitModification" BOOLEAN,
                        "overwriteExisting" BOOLEAN,
                        "alwaysEvaluate" BOOLEAN,
                        "ConstantData" VARCHAR,
                        "SerialNumber" STRUCT(
                            "increment" VARCHAR,
                            "nextvalue" VARCHAR,
                            "generate" VARCHAR
                        ),
                        "Looked_up" STRUCT(
                            "dontCopyIfEmpty" BOOLEAN,
                            "noMatchCopyOption" VARCHAR,
                            "FieldReference" STRUCT(
                                "id" BIGINT,
                                "name" VARCHAR,
                                "UUID" VARCHAR,
                                "TableOccurrenceReference" STRUCT(
                                    "id" BIGINT,
                                    "name" VARCHAR,
                                    "UUID" VARCHAR
                                )
                            )
                        ),
                        "Calculated" STRUCT(
                            "Calculation" STRUCT(
                                "DDRREF" STRUCT("hash" VARCHAR),
                                "Text" VARCHAR
                            )
                        )
                    )
                )[]
            )'
        }
    )
    CROSS JOIN UNNEST(ObjectList.Field) AS t(f)
    WHERE f.id IS NOT NULL
      AND f.UUID."#text" IS NOT NULL
),
field_healed AS (
    -- UUID-Healing (H1): Survivor je UUID behält die Original-UUID, weitere Zwillinge
    -- erhalten im INSERT unten die deterministische Ersatz-UUID (fm_heal_pick, Prelude).
    -- Schlüssel ist ZUSAMMENGESETZT (Field/@id ist tabellen-lokal!): Tupel-MIN über
    -- (Table_ID, Field_ID) — DuckDB vergleicht Structs lexikographisch, der Survivor
    -- ist damit deterministisch (kleinste Tabelle, darin kleinstes Feld). Doppel-
    -- Serialisierung (gleiche UUID UND gleicher Schlüssel) kollabiert weiterhin
    -- korrekt: Zeilen mit identischem Diskriminator erhalten identische UUIDs →
    -- ON CONFLICT greift wie bisher.
    -- Zweiter Hash-Partition-Pass auf dem bereits gelesenen Rowset — kein XML-Re-Scan.
    SELECT fr.*,
           (fr.f.UUID."#text" IS NULL OR fr.BaseTableReference.id IS NULL  -- NULL-Table-ID: kein Diskriminator → nie heilen
            OR (fr.BaseTableReference.id, fr.f.id) =
               MIN((fr.BaseTableReference.id, fr.f.id)) OVER (PARTITION BY fr.f.UUID."#text")) AS is_survivor
    FROM field_records fr
)
INSERT INTO FieldsForTables
SELECT
    BaseTableReference.id AS Table_ID,
    xml_unescape(BaseTableReference.name) AS Table_Name,
    BaseTableReference.UUID AS Table_UUID,
    f.id AS Field_ID,
    xml_unescape(f.name) AS Field_Name,
    f.fieldtype AS Field_Type,
    f.datatype AS Data_Type,
    ws_restore(f.comment) AS Field_Comment,
    fm_heal_pick(is_survivor, 'FieldsForTables', fn.File_Name, f.UUID."#text",
                 'table_id=' || BaseTableReference.id::VARCHAR || '·field_id=' || f.id::VARCHAR) AS Field_UUID,
    f.Storage.global AS Is_Global,
    f.Storage.maxRepetitions AS Max_Repetitions,
    f.Calculation.DDRREF.hash AS DDR_Hash,  -- DDR-Hash für Calculated Fields (ab FM21+)
    -- chr(127) -> chr(10): Preprocessing-Sentinel für CR zurück zu LF
    ws_restore(f.Calculation.Text) AS Calculation_Text,
    -- AutoEnter-Basisattribute
    CASE WHEN f.AutoEnter.type = '' THEN NULL ELSE f.AutoEnter.type END AS AutoEnter_Type,
    f.AutoEnter.prohibitModification AS AutoEnter_ProhibitMod,
    -- Lookup-Details
    f.AutoEnter.Looked_up.FieldReference.name AS Lookup_Field_Name,
    f.AutoEnter.Looked_up.FieldReference.UUID AS Lookup_Field_UUID,
    f.AutoEnter.Looked_up.FieldReference.TableOccurrenceReference.name AS Lookup_TO_Name,
    f.AutoEnter.Looked_up.FieldReference.TableOccurrenceReference.UUID AS Lookup_TO_UUID,
    f.AutoEnter.Looked_up.dontCopyIfEmpty AS Lookup_DontCopyIfEmpty,
    f.AutoEnter.Looked_up.noMatchCopyOption AS Lookup_NoMatchOption,
    -- AutoEnter Calculated-Details
    ws_restore(f.AutoEnter.Calculated.Calculation.Text) AS AE_Calc_Text,
    f.AutoEnter.Calculated.Calculation.DDRREF.hash AS AE_Calc_Hash,
    f.AutoEnter.overwriteExisting AS AE_Calc_OverwriteExisting,
    f.AutoEnter.alwaysEvaluate AS AE_Calc_AlwaysEvaluate,
    -- ConstantData. ws_restore: fester Standardwert kann CR enthalten.
    ws_restore(f.AutoEnter.ConstantData) AS AE_ConstantData,
    -- Validierung
    NULLIF(f.Validation.type, '') AS Validation_Type,
    f.Validation.allowOverride AS Validation_AllowOverride,
    f.Validation.notEmpty AS Validation_NotEmpty,
    f.Validation."unique" AS Validation_Unique,
    f.Validation.existing AS Validation_Existing,
    f.Validation.ValueListReference.id AS Validation_VL_ID,
    xml_unescape(f.Validation.ValueListReference.name) AS Validation_VL_Name,
    f.Validation.ValueListReference.UUID AS Validation_VL_UUID,
    -- Storage/Indexierung
    f.Storage.autoIndex AS Storage_AutoIndex,
    f.Storage."index" AS Storage_Index,
    f.Storage.storeCalculationResults AS Storage_StoreCalcResults,
    -- SerialNumber
    f.AutoEnter.SerialNumber.increment AS Serial_Increment,
    f.AutoEnter.SerialNumber.nextvalue AS Serial_NextValue,
    f.AutoEnter.SerialNumber.generate AS Serial_Generate,
    -- Summary
    NULLIF(f.SummaryInfo.operation, '') AS Summary_Operation,
    xml_unescape(f.SummaryInfo.SummaryField.FieldReference.name) AS Summary_Field_Name,
    f.SummaryInfo.SummaryField.FieldReference.UUID AS Summary_Field_UUID,
    -- Validierung / Indexsprache / Summary-Modifikatoren (Schema 1.10.0)
    f.Validation.alwaysValidate AS Validation_AlwaysValidate,
    NULLIF(f.Validation.Strict, '') AS Validation_StrictType,
    -- Sentinel-Normalisierung: 4294967295 (UINT32_MAX) = FileMakers "unbegrenzt"
    -- fuer die maximale Zeichenanzahl -> NULL (= kein Limit gesetzt, deckt sich
    -- mit nicht konfigurierter Validierung). Exakt-Match, bewusst keine
    -- Bereichsregel; Drift-Waechter: v_check_numeric_sentinels (P6).
    NULLIF(f.Validation.MaximumSize, 4294967295) AS Validation_MaxChars,
    NULLIF(f.Validation.Range."from", '') AS Validation_Range_From,
    NULLIF(f.Validation.Range."to", '') AS Validation_Range_To,
    -- Prüf-Calc: Text (ws_restore wie AE-Calc) + DDR-Hash für die Graph-Kante
    ws_restore(f.Validation.Calculated.Calculation.Text) AS Validation_Calc_Text,
    f.Validation.Calculated.Calculation.DDRREF.hash AS Validation_Calc_Hash,
    -- Eigene Meldung: statischer Text (ws_restore, kann CR/Entities enthalten) + optionaler Calc-Hash
    ws_restore(f.Validation.Message) AS Validation_Message,
    f.Validation.MessageCalc.Calculation.DDRREF.hash AS Validation_Message_Calc_Hash,
    -- Standard-Indexsprache (Kind-Element <LanguageReference> von <Storage>)
    NULLIF(f.Storage.LanguageReference.name, '') AS Storage_IndexLanguage,
    f.Storage.LanguageReference.id AS Storage_IndexLanguage_ID,
    -- Summary-Modifikatoren
    f.SummaryInfo.restartEachGroup AS Summary_RestartEachGroup,
    NULLIF(f.SummaryInfo.summarizeRepetition, '') AS Summary_RepetitionMode,
    fn.File_Name as File_Name
FROM field_healed
CROSS JOIN filename_normalized fn
ON CONFLICT (Field_UUID, File_Name) DO UPDATE SET
    Table_ID = EXCLUDED.Table_ID,
    Table_Name = EXCLUDED.Table_Name,
    Table_UUID = EXCLUDED.Table_UUID,
    Field_ID = EXCLUDED.Field_ID,
    Field_Name = EXCLUDED.Field_Name,
    Field_Type = EXCLUDED.Field_Type,
    Data_Type = EXCLUDED.Data_Type,
    Field_Comment = EXCLUDED.Field_Comment,
    Is_Global = EXCLUDED.Is_Global,
    Max_Repetitions = EXCLUDED.Max_Repetitions,
    DDR_Hash = EXCLUDED.DDR_Hash,
    Calculation_Text = EXCLUDED.Calculation_Text,
    AutoEnter_Type = EXCLUDED.AutoEnter_Type,
    AutoEnter_ProhibitMod = EXCLUDED.AutoEnter_ProhibitMod,
    Lookup_Field_Name = EXCLUDED.Lookup_Field_Name,
    Lookup_Field_UUID = EXCLUDED.Lookup_Field_UUID,
    Lookup_TO_Name = EXCLUDED.Lookup_TO_Name,
    Lookup_TO_UUID = EXCLUDED.Lookup_TO_UUID,
    Lookup_DontCopyIfEmpty = EXCLUDED.Lookup_DontCopyIfEmpty,
    Lookup_NoMatchOption = EXCLUDED.Lookup_NoMatchOption,
    AE_Calc_Text = EXCLUDED.AE_Calc_Text,
    AE_Calc_Hash = EXCLUDED.AE_Calc_Hash,
    AE_Calc_OverwriteExisting = EXCLUDED.AE_Calc_OverwriteExisting,
    AE_Calc_AlwaysEvaluate = EXCLUDED.AE_Calc_AlwaysEvaluate,
    AE_ConstantData = EXCLUDED.AE_ConstantData,
    Validation_Type = EXCLUDED.Validation_Type,
    Validation_AllowOverride = EXCLUDED.Validation_AllowOverride,
    Validation_NotEmpty = EXCLUDED.Validation_NotEmpty,
    Validation_Unique = EXCLUDED.Validation_Unique,
    Validation_Existing = EXCLUDED.Validation_Existing,
    Validation_VL_ID = EXCLUDED.Validation_VL_ID,
    Validation_VL_Name = EXCLUDED.Validation_VL_Name,
    Validation_VL_UUID = EXCLUDED.Validation_VL_UUID,
    Storage_AutoIndex = EXCLUDED.Storage_AutoIndex,
    Storage_Index = EXCLUDED.Storage_Index,
    Storage_StoreCalcResults = EXCLUDED.Storage_StoreCalcResults,
    Serial_Increment = EXCLUDED.Serial_Increment,
    Serial_NextValue = EXCLUDED.Serial_NextValue,
    Serial_Generate = EXCLUDED.Serial_Generate,
    Summary_Operation = EXCLUDED.Summary_Operation,
    Summary_Field_Name = EXCLUDED.Summary_Field_Name,
    Summary_Field_UUID = EXCLUDED.Summary_Field_UUID,
    Validation_AlwaysValidate = EXCLUDED.Validation_AlwaysValidate,
    Validation_StrictType = EXCLUDED.Validation_StrictType,
    Validation_MaxChars = EXCLUDED.Validation_MaxChars,
    Validation_Range_From = EXCLUDED.Validation_Range_From,
    Validation_Range_To = EXCLUDED.Validation_Range_To,
    Validation_Calc_Text = EXCLUDED.Validation_Calc_Text,
    Validation_Calc_Hash = EXCLUDED.Validation_Calc_Hash,
    Validation_Message = EXCLUDED.Validation_Message,
    Validation_Message_Calc_Hash = EXCLUDED.Validation_Message_Calc_Hash,
    Storage_IndexLanguage = EXCLUDED.Storage_IndexLanguage,
    Storage_IndexLanguage_ID = EXCLUDED.Storage_IndexLanguage_ID,
    Summary_RestartEachGroup = EXCLUDED.Summary_RestartEachGroup,
    Summary_RepetitionMode = EXCLUDED.Summary_RepetitionMode;

-- Zensus (Dup-Absorption): Quell-Rowset = ein Record je Feld (UNNEST je FieldCatalog)
-- mit demselben id-Filter wie der Katalog-INSERT; minimaler Re-Read (nur Feld-id).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'FieldsForTables', 'Field_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM read_xml(
    getvariable('fm_xml'),
    root_element='FieldsForTables',
    record_element='FieldCatalog',
    max_depth=10,
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'ObjectList': 'STRUCT("Field" STRUCT("id" BIGINT)[])'}
)
CROSS JOIN UNNEST(ObjectList.Field) AS t(f)
WHERE f.id IS NOT NULL
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (FieldsForTables): Name + Tabellen-Kontext der kollidierenden
-- Felder je doppelt vergebener UUID. Liest denselben Quell-Rowset wie der Katalog-
-- INSERT oben (UNNEST + identische Zeilenfilter, inkl. UUID-Guard). DELETE-vor-INSERT
-- hält den Detail-Satz je (Katalog, Datei) beim Re-Import frisch (analog zum
-- per-Datei-Overwrite des Zensus). Bit-identisch zum Katalog-INSERT (rein additiv).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'FieldsForTables'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        BaseTableReference.id AS Table_ID,
        xml_unescape(BaseTableReference.name) AS Parent_Name,
        f.id AS Field_ID,
        f.UUID."#text" AS Object_UUID,
        xml_unescape(f.name) AS Object_Name,
        'Field' AS Object_Type,
        ROW_NUMBER() OVER () AS xml_ord
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='FieldsForTables',
        record_element='FieldCatalog',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'BaseTableReference': 'STRUCT(id BIGINT, name VARCHAR)',
            'ObjectList': 'STRUCT("Field" STRUCT("id" BIGINT, "name" VARCHAR, "UUID" STRUCT("#text" VARCHAR))[])'
        }
    )
    CROSS JOIN UNNEST(ObjectList.Field) AS t(f)
    WHERE f.id IS NOT NULL
      AND f.UUID."#text" IS NOT NULL
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H1): Survivor-/Heal-Markierung, identische Logik wie im Katalog-INSERT
-- oben (Survivor = kleinstes (Table_ID, Field_ID)-Tupel; Doppel-Serialisierung —
-- gleiche UUID+Schlüssel — bleibt 'absorbed', nur das jeweils erste Vorkommen einer
-- (UUID, Schlüssel)-Identität trägt den Katalog-Status). Der Zensus ist damit das
-- persistierte Mapping Original↔Ersatz.
marked AS (
    SELECT s.*,
           ((s.Table_ID, s.Field_ID) =
            MIN((s.Table_ID, s.Field_ID)) OVER (PARTITION BY s.Object_UUID)
            OR s.Table_ID IS NULL) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.Table_ID, s.Field_ID ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'FieldsForTables' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    -- Kontext: Parent = Basistabelle des Felds; Position = Stelle im entfalteten
    -- Feld-Rowset der Datei (XML-Reihenfolge, 1-basiert).
    s.Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name, 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('FieldsForTables', getvariable('fm_file'), s.Object_UUID,
                           'table_id=' || s.Table_ID::VARCHAR || '·field_id=' || s.Field_ID::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'table_id=' || s.Table_ID::VARCHAR || '·field_id=' || s.Field_ID::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;


-- ValueListCatalog
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS ValueListCatalog (
    VL_ID BIGINT,
    VL_Name VARCHAR,
    Source_Type VARCHAR,
    VL_UUID VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (VL_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
vl_records AS (
    SELECT id, name, Source, UUID
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='ValueListCatalog',
        record_element='ValueList',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'UUID': 'STRUCT("#text" VARCHAR, "modifications" BIGINT, "userName" VARCHAR, "accountName" VARCHAR, "timestamp" VARCHAR)',
            'Source': 'STRUCT(value VARCHAR)'
        }
    )
    WHERE id IS NOT NULL
),
vl_healed AS (
    -- UUID-Healing (H1): Survivor = kleinste VL_ID je UUID behält die Original-UUID,
    -- weitere Zwillinge erhalten im INSERT unten die deterministische Ersatz-UUID
    -- (fm_heal_pick, Prelude). Doppel-Serialisierung (gleiche UUID UND gleiche ID)
    -- kollabiert weiterhin korrekt: Zeilen mit identischem Diskriminator erhalten
    -- identische UUIDs → ON CONFLICT greift wie bisher. Namespace/Diskriminator sind
    -- mit OptionsForValueLists (unten) abgestimmt — beide Tabellen heilen mit
    -- identischem md5-Input, damit Katalog- und Options-Zeile eines Zwillings
    -- dieselbe Ersatz-UUID tragen.
    -- Zweiter Hash-Partition-Pass auf dem bereits gelesenen Rowset — kein XML-Re-Scan.
    SELECT vr.*,
           (vr.UUID."#text" IS NULL
            OR vr.id = MIN(vr.id) OVER (PARTITION BY vr.UUID."#text")) AS is_survivor
    FROM vl_records vr
)
INSERT INTO ValueListCatalog
SELECT
    vr.id AS VL_ID,
    xml_unescape(vr.name) AS VL_Name,
    vr.Source.value AS Source_Type,
    fm_heal_pick(vr.is_survivor, 'ValueListCatalog', fn.File_Name,
                 vr.UUID."#text", 'vl_id=' || vr.id::VARCHAR) AS VL_UUID,
    fn.File_Name as File_Name
FROM vl_healed vr
CROSS JOIN filename_normalized fn
ON CONFLICT (VL_UUID, File_Name) DO UPDATE SET
    VL_ID = EXCLUDED.VL_ID,
    VL_Name = EXCLUDED.VL_Name,
    Source_Type = EXCLUDED.Source_Type;

-- Zensus (Dup-Absorption): geparste Quell-Records mit demselben id-Filter
-- wie der Katalog-INSERT; minimaler Re-Read (nur id).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'ValueListCatalog', 'VL_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM read_xml(
    getvariable('fm_xml'),
    root_element='ValueListCatalog',
    record_element='ValueList',
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'id': 'BIGINT'}
)
WHERE id IS NOT NULL
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (ValueListCatalog): Name der kollidierenden Wertelisten je
-- doppelt vergebener UUID. Liest denselben Quell-Rowset wie der Katalog-INSERT oben
-- (identischer id-Filter). DELETE-vor-INSERT hält den Detail-Satz je (Katalog, Datei)
-- beim Re-Import frisch (analog zum per-Datei-Overwrite des Zensus). Bit-identisch
-- zum Katalog-INSERT (rein additiv, eigene Tabelle). Das Mapping gilt zugleich für
-- OptionsForValueLists (heilt mit identischem Namespace/Diskriminator, s. u.).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'ValueListCatalog'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        id,
        UUID."#text" AS Object_UUID,
        xml_unescape(name) AS Object_Name,
        'ValueList' AS Object_Type,
        ROW_NUMBER() OVER () AS xml_ord
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='ValueListCatalog',
        record_element='ValueList',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'UUID': 'STRUCT("#text" VARCHAR)'
        }
    )
    WHERE id IS NOT NULL
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H1): Survivor-/Heal-Markierung, identische Logik wie im Katalog-INSERT
-- oben (Survivor = kleinste ID; Doppel-Serialisierung — gleiche UUID+ID — bleibt
-- 'absorbed', nur das jeweils erste Vorkommen einer (UUID, ID)-Identität trägt den
-- Katalog-Status). Der Zensus ist damit das persistierte Mapping Original↔Ersatz.
marked AS (
    SELECT s.*,
           (s.id IS NULL  -- NULL-id: kein Diskriminator → wie Survivor behandeln (nie 'healed')
            OR s.id = MIN(s.id) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.id ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'ValueListCatalog' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    -- Kontext: Wertelisten sind Top-Level → kein Container; Position = Stelle
    -- in der "Wertelisten verwalten"-Liste (XML-Reihenfolge, 1-basiert).
    NULL AS Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name, 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('ValueListCatalog', getvariable('fm_file'), s.Object_UUID,
                           'vl_id=' || s.id::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'vl_id=' || s.id::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;


-- OptionsForValueLists (Details und Werte)
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS OptionsForValueLists (
    VL_ID BIGINT,
    VL_Name VARCHAR,
    VL_UUID VARCHAR,
    Source_Type VARCHAR,
    Custom_Values VARCHAR[],
    -- Primärfeld: FileMaker-Struktur ist Field/PrimaryField/FieldReference (NICHT
    -- Source/FieldReference — der alte Pfad lieferte durchweg NULL → 0 ValueList-Links).
    Field_ID BIGINT,
    Field_Name VARCHAR,
    Field_UUID VARCHAR,
    TO_ID BIGINT,
    TO_Name VARCHAR,
    TO_UUID VARCHAR,
    Field_Sort BOOLEAN,
    -- Zweitfeld (Field/SecondaryField): „auch Werte aus zweitem Feld anzeigen" +
    -- Sortierung (@sort). Echte Feldabhängigkeit → eigener source_field-Link (Subrole).
    Secondary_Field_ID BIGINT,
    Secondary_Field_Name VARCHAR,
    Secondary_Field_UUID VARCHAR,
    Secondary_TO_ID BIGINT,
    Secondary_TO_Name VARCHAR,
    Secondary_TO_UUID VARCHAR,
    Secondary_Sort BOOLEAN,
    -- External-Werteliste (Source value="External"): lokaler Wrapper auf eine VL einer
    -- anderen Datei. Die Ziel-ValueListReference trägt im XML eine LEERE UUID → P4 löst
    -- über DataSourceReference (→ Zieldatei) + VL-id (Fallback Name) auf und erzeugt
    -- ValueList→ValueList (source_valuelist) + ValueList→ExternalDataSource (data_source).
    External_DS_ID BIGINT,
    External_DS_Name VARCHAR,
    External_DS_UUID VARCHAR,
    External_VL_ID BIGINT,
    External_VL_Name VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (VL_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
ovl_records AS (
    -- Source-Wächter: record_element='ValueList' matcht NICHT nur die Einträge unter
    -- <OptionsForValueLists>, sondern auch die <ValueList>-Knoten des PrivilegeSet-
    -- access-Baums (Custom ValueList Privileges) — die tragen eine GÜLTIGE
    -- ValueListReference (gleiche VL-UUID!) und würden per last-write-wins die echten
    -- Options-Zeilen überschreiben (Source_Type=NULL). Echte Options-Einträge tragen
    -- IMMER ein <Source>-Element (FromField/Custom/External; Korpus: 0 Ausnahmen),
    -- die Privilege-Knoten nie → der Filter grenzt exakt ab. Vom Dup-Absorption-
    -- Zensus aufgedeckt (Test-Set: 4 Privilege-Zeilen kollabierten still).
    SELECT *
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='OptionsForValueLists',
        record_element='ValueList',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'ValueListReference': 'STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)',
            'Source': 'STRUCT(value VARCHAR)',
            'Field': 'STRUCT(
                "PrimaryField" STRUCT(
                    "show" BOOLEAN, "sort" BOOLEAN,
                    "FieldReference" STRUCT(
                        id BIGINT, name VARCHAR, UUID VARCHAR,
                        "TableOccurrenceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)
                    )
                ),
                "SecondaryField" STRUCT(
                    "show" BOOLEAN, "sort" BOOLEAN,
                    "FieldReference" STRUCT(
                        id BIGINT, name VARCHAR, UUID VARCHAR,
                        "TableOccurrenceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)
                    )
                )
            )',
            'CustomValues': 'STRUCT("Text" STRUCT("#text" VARCHAR)[])',
            'External': 'STRUCT(
                "DataSourceReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR),
                "ValueListReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)
            )'
        }
    )
    WHERE ValueListReference.id IS NOT NULL
      AND Source.value IS NOT NULL
),
ovl_healed AS (
    -- UUID-Healing (H1) — SONDERFALL: der PK VL_UUID ist hier zugleich Fremdschlüssel
    -- auf ValueListCatalog (1:1-Detailtabelle derselben Werteliste). Damit die
    -- Options-Zeile eines geheilten VL-Zwillings DIESELBE Ersatz-UUID trägt wie der
    -- Katalog-Eintrag, wird bewusst mit Namespace 'ValueListCatalog' (NICHT
    -- 'OptionsForValueLists'!) und dem identischen Diskriminator 'vl_id=<id>'
    -- geheilt — identischer md5-Input wie beim VL selbst → identische Ersatz-UUID,
    -- der Join ValueListCatalog↔OptionsForValueLists bleibt intakt. Survivor-Regel
    -- identisch (kleinste VL-ID je UUID). KEIN eigener Detail-Block: das
    -- Original↔Ersatz-Mapping steht bereits beim ValueListCatalog-Zensus.
    -- Zweiter Hash-Partition-Pass auf dem bereits gelesenen Rowset — kein XML-Re-Scan.
    SELECT vr.*,
           (vr.ValueListReference.UUID IS NULL
            OR vr.ValueListReference.id =
               MIN(vr.ValueListReference.id) OVER (PARTITION BY vr.ValueListReference.UUID)) AS is_survivor
    FROM ovl_records vr
)
INSERT INTO OptionsForValueLists
SELECT
    ValueListReference.id AS VL_ID,
    xml_unescape(ValueListReference.name) AS VL_Name,
    -- Heilung im ValueListCatalog-Namespace (s. Kommentar in ovl_healed oben).
    fm_heal_pick(is_survivor, 'ValueListCatalog', fn.File_Name,
                 ValueListReference.UUID, 'vl_id=' || ValueListReference.id::VARCHAR) AS VL_UUID,
    Source.value AS Source_Type,
    [v."#text" for v in CustomValues.Text] AS Custom_Values,
    Field.PrimaryField.FieldReference.id AS Field_ID,
    xml_unescape(Field.PrimaryField.FieldReference.name) AS Field_Name,
    Field.PrimaryField.FieldReference.UUID AS Field_UUID,
    Field.PrimaryField.FieldReference.TableOccurrenceReference.id AS TO_ID,
    xml_unescape(Field.PrimaryField.FieldReference.TableOccurrenceReference.name) AS TO_Name,
    Field.PrimaryField.FieldReference.TableOccurrenceReference.UUID AS TO_UUID,
    Field.PrimaryField.sort AS Field_Sort,
    Field.SecondaryField.FieldReference.id AS Secondary_Field_ID,
    Field.SecondaryField.FieldReference.name AS Secondary_Field_Name,
    Field.SecondaryField.FieldReference.UUID AS Secondary_Field_UUID,
    Field.SecondaryField.FieldReference.TableOccurrenceReference.id AS Secondary_TO_ID,
    Field.SecondaryField.FieldReference.TableOccurrenceReference.name AS Secondary_TO_Name,
    Field.SecondaryField.FieldReference.TableOccurrenceReference.UUID AS Secondary_TO_UUID,
    Field.SecondaryField.sort AS Secondary_Sort,
    External.DataSourceReference.id AS External_DS_ID,
    xml_unescape(External.DataSourceReference.name) AS External_DS_Name,
    External.DataSourceReference.UUID AS External_DS_UUID,
    External.ValueListReference.id AS External_VL_ID,
    xml_unescape(External.ValueListReference.name) AS External_VL_Name,
    fn.File_Name as File_Name
FROM ovl_healed
CROSS JOIN filename_normalized fn
ON CONFLICT (VL_UUID, File_Name) DO UPDATE SET
    VL_ID = EXCLUDED.VL_ID,
    VL_Name = EXCLUDED.VL_Name,
    Source_Type = EXCLUDED.Source_Type,
    Custom_Values = EXCLUDED.Custom_Values,
    Field_ID = EXCLUDED.Field_ID,
    Field_Name = EXCLUDED.Field_Name,
    Field_UUID = EXCLUDED.Field_UUID,
    TO_ID = EXCLUDED.TO_ID,
    TO_Name = EXCLUDED.TO_Name,
    TO_UUID = EXCLUDED.TO_UUID,
    Field_Sort = EXCLUDED.Field_Sort,
    Secondary_Field_ID = EXCLUDED.Secondary_Field_ID,
    Secondary_Field_Name = EXCLUDED.Secondary_Field_Name,
    Secondary_Field_UUID = EXCLUDED.Secondary_Field_UUID,
    Secondary_TO_ID = EXCLUDED.Secondary_TO_ID,
    Secondary_TO_Name = EXCLUDED.Secondary_TO_Name,
    Secondary_TO_UUID = EXCLUDED.Secondary_TO_UUID,
    Secondary_Sort = EXCLUDED.Secondary_Sort,
    External_DS_ID = EXCLUDED.External_DS_ID,
    External_DS_Name = EXCLUDED.External_DS_Name,
    External_DS_UUID = EXCLUDED.External_DS_UUID,
    External_VL_ID = EXCLUDED.External_VL_ID,
    External_VL_Name = EXCLUDED.External_VL_Name;

-- Zensus (Dup-Absorption): geparste Quell-Records mit denselben Filtern wie der
-- Katalog-INSERT (ValueListReference.id + Source-Wächter, s. o.); minimaler Re-Read.
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'OptionsForValueLists', 'VL_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM read_xml(
    getvariable('fm_xml'),
    root_element='OptionsForValueLists',
    record_element='ValueList',
    max_depth=10,
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'ValueListReference': 'STRUCT(id BIGINT)', 'Source': 'STRUCT(value VARCHAR)'}
)
WHERE ValueListReference.id IS NOT NULL
  AND Source.value IS NOT NULL
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;


-- CustomFunctionsCatalog
-- @END_P1_SECTION@
-- Folder_Type / Is_Separator / Sequence_ID analog zu ScriptCatalog und Layouts:
-- der "Manage Custom Functions"-Dialog kennt Ordner und Trennlinien, und
-- FileMaker schreibt sie als gewöhnliche <CustomFunction>-Records mit
-- isFolder="True"/"Marker" (belegt ab FM 22 in den Test-Fixtures). Ohne diese
-- Spalten sind Ordner und Trenner im Katalog von echten Custom Functions
-- ununterscheidbar — sie zählen in jeder CF-Kennzahl mit und haben, wie eine
-- parameterlose CF, Parameters = NULL.
-- Sequence_ID = laufende Nummer in XML-Reihenfolge, NICHT CF_ID (das ist die
-- Anlege-Reihenfolge): die Folder-Stack-Logik in FolderHierarchy rechnet in
-- XML-Reihenfolge und stünde nach CF_ID sortiert falsch.
CREATE TABLE IF NOT EXISTS CustomFunctionsCatalog (
    CF_ID BIGINT,
    CF_Name VARCHAR,
    CF_Display VARCHAR,
    CF_UUID VARCHAR,
    Parameters VARCHAR[],
    DDR_Hash VARCHAR,  -- DDR-Hash für Custom Functions (ab FM21+)
    Folder_Type VARCHAR,
    Is_Separator BOOLEAN,
    Sequence_ID BIGINT,
    File_Name VARCHAR,
    PRIMARY KEY (CF_UUID, File_Name)
);

-- Additive Migration für Bestands-DBs (idempotent — neuer Bau setzt sie via CREATE).
ALTER TABLE CustomFunctionsCatalog ADD COLUMN IF NOT EXISTS Folder_Type VARCHAR;
ALTER TABLE CustomFunctionsCatalog ADD COLUMN IF NOT EXISTS Is_Separator BOOLEAN;
ALTER TABLE CustomFunctionsCatalog ADD COLUMN IF NOT EXISTS Sequence_ID BIGINT;

-- Ein einziger Parse des CustomFunctionsCatalog-Zweigs, einmal materialisiert und
-- unten doppelt genutzt: für den Katalog UND (ab SaXML v2.3.0.0 / FM 26+) für die
-- eingebetteten Formelkörper. So kostet der Embedded-Pfad keinen zusätzlichen XML-Parse.
-- Die Spalte `Calculation` ist NULL für SaXML ≤ v2.2.x (FM ≤ 22) — dort liegen die
-- Formeln in einer separaten Top-Level-Sektion <CalcsForCustomFunctions> (weiter unten).
-- UUID-Healing (H1): die Heilung sitzt EINMAL hier in der TEMP-Stufe — Katalog-INSERT
-- (unten) UND der Embedded-Calc-Feed (CalcsForCustomFunctions, FM 26+) lesen beide
-- CF_UUID aus _cf_catalog_raw und bleiben damit automatisch konsistent (identische
-- Ersatz-UUID in beiden Tabellen). CF_UUID_Orig (roh) + CF_Is_Survivor bleiben für
-- den Detail-Zensus unten erhalten; Konsumenten nutzen ausschließlich CF_UUID.
-- @P1_SECTION:main@
CREATE OR REPLACE TEMP TABLE _cf_catalog_raw AS
WITH cf_records AS (
    SELECT
        id AS CF_ID,
        xml_unescape(name) AS CF_Name,
        Display AS CF_Display,
        UUID->>'#text' AS CF_UUID_Orig,
        [p.name for p in ObjectList.Parameter] AS Parameters,
        isFolder AS Folder_Type,
        COALESCE(isSeparatorItem, False) AS Is_Separator,
        ROW_NUMBER() OVER () + COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Sequence_ID,
        Calculation,
        getvariable('fm_file') AS File_Name
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='CustomFunctionsCatalog',
        record_element='CustomFunction',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'Display': 'VARCHAR',
            'isFolder': 'VARCHAR',
            'isSeparatorItem': 'BOOLEAN',
            'UUID': 'STRUCT("#text" VARCHAR, "modifications" BIGINT, "userName" VARCHAR, "timestamp" VARCHAR)',
            'ObjectList': 'STRUCT(Parameter STRUCT(name VARCHAR)[])',
            'Calculation': 'STRUCT("Text" VARCHAR, "DDRREF" STRUCT("kind" VARCHAR, "hash" VARCHAR, "#text" VARCHAR))'
        }
    )
),
cf_healed AS (
    -- Survivor = kleinste CF_ID je UUID behält die Original-UUID, weitere Zwillinge
    -- erhalten die deterministische Ersatz-UUID (fm_heal_pick, Prelude). Doppel-
    -- Serialisierung (gleiche UUID UND gleiche ID) kollabiert weiterhin korrekt:
    -- Zeilen mit identischem Diskriminator erhalten identische UUIDs → ON CONFLICT
    -- greift wie bisher. Zweiter Hash-Partition-Pass, kein XML-Re-Scan.
    SELECT cr.*,
           (cr.CF_UUID_Orig IS NULL OR cr.CF_ID IS NULL  -- NULL-id: kein Diskriminator → nie heilen
            OR cr.CF_ID = MIN(cr.CF_ID) OVER (PARTITION BY cr.CF_UUID_Orig)) AS CF_Is_Survivor
    FROM cf_records cr
)
SELECT ch.*,
       fm_heal_pick(ch.CF_Is_Survivor, 'CustomFunctionsCatalog', ch.File_Name,
                    ch.CF_UUID_Orig, 'cf_id=' || ch.CF_ID::VARCHAR) AS CF_UUID
FROM cf_healed ch;

INSERT INTO CustomFunctionsCatalog
SELECT
    CF_ID,
    CF_Name,
    CF_Display,
    CF_UUID,
    Parameters,
    NULL AS DDR_Hash,  -- Wird später von CalcsForCustomFunctions aktualisiert
    Folder_Type,
    Is_Separator,
    Sequence_ID,
    File_Name
FROM _cf_catalog_raw
ON CONFLICT (CF_UUID, File_Name) DO UPDATE SET
    CF_ID = EXCLUDED.CF_ID,
    CF_Name = EXCLUDED.CF_Name,
    CF_Display = EXCLUDED.CF_Display,
    Parameters = EXCLUDED.Parameters,
    DDR_Hash = EXCLUDED.DDR_Hash,
    Folder_Type = EXCLUDED.Folder_Type,
    Is_Separator = EXCLUDED.Is_Separator,
    Sequence_ID = EXCLUDED.Sequence_ID;

-- Zensus (Dup-Absorption): liest aus der bereits materialisierten TEMP-Stufe
-- _cf_catalog_raw (kein zweiter XML-Parse; der Katalog-INSERT hat keinen Filter).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'CustomFunctionsCatalog', 'CF_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM _cf_catalog_raw
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (CustomFunctionsCatalog): Typ + Name der kollidierenden
-- Custom Functions je doppelt vergebener UUID. Liest die bereits materialisierte
-- TEMP-Stufe _cf_catalog_raw (kein zweiter XML-Parse) — dort liegen ROH-UUID
-- (CF_UUID_Orig) und geheilte UUID nebeneinander. DELETE-vor-INSERT hält den
-- Detail-Satz je (Katalog, Datei) beim Re-Import frisch (analog zum per-Datei-
-- Overwrite des Zensus). Bit-identisch zum Katalog-INSERT (rein additiv).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'CustomFunctionsCatalog'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        CF_ID AS id,
        CF_UUID_Orig AS Object_UUID,
        CF_Name AS Object_Name,
        CASE WHEN Folder_Type = 'True' THEN 'Folder'
             WHEN Is_Separator THEN 'Separator'
             ELSE 'CustomFunction' END AS Object_Type,
        ROW_NUMBER() OVER (ORDER BY Sequence_ID) AS xml_ord
    FROM _cf_catalog_raw
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H1): Survivor-/Heal-Markierung, identische Logik wie in _cf_catalog_raw
-- oben (Survivor = kleinste ID; Doppel-Serialisierung — gleiche UUID+ID — bleibt
-- 'absorbed', nur das jeweils erste Vorkommen einer (UUID, ID)-Identität trägt den
-- Katalog-Status). Der Zensus ist damit das persistierte Mapping Original↔Ersatz.
marked AS (
    SELECT s.*,
           (s.id IS NULL  -- NULL-id: kein Diskriminator → wie Survivor behandeln (nie 'healed')
            OR s.id = MIN(s.id) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.id ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'CustomFunctionsCatalog' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    -- Kontext: Custom Functions sind Top-Level → kein Container; Position = Stelle
    -- in der "Eigene Funktionen verwalten"-Liste (XML-Reihenfolge, 1-basiert).
    NULL AS Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name, 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('CustomFunctionsCatalog', getvariable('fm_file'), s.Object_UUID,
                           'cf_id=' || s.id::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'cf_id=' || s.id::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;


-- CalcsForCustomFunctions
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS CalcsForCustomFunctions (
    CF_ID BIGINT,
    CF_Name VARCHAR,
    CF_UUID VARCHAR,
    Calculation_Code VARCHAR,
    Code_Chunks STRUCT(type VARCHAR, content VARCHAR)[],
    DDR_Hash VARCHAR,
    DDR_UUID VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (CF_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
)
INSERT INTO CalcsForCustomFunctions
SELECT
    CustomFunctionReference.id AS CF_ID,
    xml_unescape(CustomFunctionReference.name) AS CF_Name,
    CustomFunctionReference.UUID AS CF_UUID,
    ws_restore(Calculation.Text) AS Calculation_Code,
    [ {'type': c.type, 'content': c."#text"} for c in Calculation.ChunkList.Chunk ] AS Code_Chunks,
    Calculation.DDRREF.hash AS DDR_Hash,
    regexp_replace(
        Calculation.DDRREF."#text",
        '^_',
        ''
    ) AS DDR_UUID,
    fn.File_Name as File_Name
FROM read_xml(
    getvariable('fm_xml'),
    root_element='CalcsForCustomFunctions',
    record_element='CustomFunctionCalc',
    max_depth=10,
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={
        'CustomFunctionReference': 'STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR)',
        'Calculation': 'STRUCT(
            "Text" VARCHAR,
            "ChunkList" STRUCT(
                "Chunk" STRUCT(type VARCHAR, "#text" VARCHAR)[]
            ),
            "DDRREF" STRUCT(
                "kind" VARCHAR,
                "hash" VARCHAR,
                "#text" VARCHAR
            )
        )'
    }
)
CROSS JOIN filename_normalized fn
ON CONFLICT (CF_UUID, File_Name) DO UPDATE SET
    CF_ID = EXCLUDED.CF_ID,
    CF_Name = EXCLUDED.CF_Name,
    Calculation_Code = EXCLUDED.Calculation_Code,
    Code_Chunks = EXCLUDED.Code_Chunks,
    DDR_Hash = EXCLUDED.DDR_Hash,
    DDR_UUID = EXCLUDED.DDR_UUID;


-- Embedded-Pfad SaXML v2.3.0.0 (FM 26+): <Calculation> ist direkt in jedes
-- <CustomFunction> eingebettet; die separate <CalcsForCustomFunctions>-Sektion entfällt.
-- Quelle ist das oben bereits geparste _cf_catalog_raw → KEIN zusätzlicher XML-Parse.
-- Code_Chunks = NULL: das eingebettete <Calculation> trägt keine <ChunkList> (verifiziert
-- an der v26-Test-XML unter tools/tests/fixtures/xml/) — die Chunks bleiben über DDR_Hash → DDR_Calculations erreichbar.
-- ON CONFLICT DO NOTHING: trägt eine Datei je beide Formen, gewinnt der Legacy-Pfad oben
-- (kein Datenverlust). Bei FM ≤ 22 ist Calculation NULL → 0 Zeilen, also ein No-Op.
INSERT INTO CalcsForCustomFunctions
SELECT
    CF_ID,
    CF_Name,
    CF_UUID,
    ws_restore(Calculation.Text) AS Calculation_Code,
    NULL::STRUCT(type VARCHAR, content VARCHAR)[] AS Code_Chunks,
    Calculation.DDRREF.hash AS DDR_Hash,
    regexp_replace(Calculation.DDRREF."#text", '^_', '') AS DDR_UUID,
    File_Name
FROM _cf_catalog_raw
WHERE Calculation IS NOT NULL AND Calculation.Text IS NOT NULL
ON CONFLICT (CF_UUID, File_Name) DO NOTHING;


-- Update CustomFunctionsCatalog with DDR_Hash from CalcsForCustomFunctions
UPDATE CustomFunctionsCatalog cf
SET DDR_Hash = calc.DDR_Hash
FROM CalcsForCustomFunctions calc
WHERE cf.CF_UUID = calc.CF_UUID
  AND cf.File_Name = calc.File_Name
  AND calc.DDR_Hash IS NOT NULL;


-- ScriptCatalog
-- Sequence_ID: laufende Nummer in der XML-Reihenfolge (kritisch für Folder-Hierarchie!).
-- Script_ID ist NICHT die UI-Reihenfolge — FileMaker numeriert Scripts sequentiell beim
-- Anlegen, nicht beim Ordnen. Für korrekte Stack-Berechnung der Folder muss die echte
-- XML-Reihenfolge erhalten bleiben.
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS ScriptCatalog (
    Script_ID BIGINT,
    Script_Name VARCHAR,
    Folder_Type VARCHAR,
    Is_Separator BOOLEAN,
    Script_UUID VARCHAR,
    Modifications BIGINT,
    Last_Modified_By VARCHAR,
    Last_Modified_At VARCHAR,
    Option_Bitmask BIGINT,
    Is_Hidden BOOLEAN,
    Full_Access BOOLEAN,
    Sequence_ID BIGINT,
    File_Name VARCHAR,
    PRIMARY KEY (Script_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
script_records AS (
    -- Pro Datei: ROW_NUMBER() in der read_xml-Reihenfolge (= XML-Reihenfolge).
    SELECT
        ROW_NUMBER() OVER () + getvariable('seq_offset')::BIGINT AS Sequence_ID,
        id, name, isFolder, isSeparatorItem, UUID, Options
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='ScriptCatalog',
        record_element='Script',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'isFolder': 'VARCHAR',
            'isSeparatorItem': 'BOOLEAN',
            'UUID': 'STRUCT("#text" VARCHAR, modifications BIGINT, userName VARCHAR, accountName VARCHAR, timestamp VARCHAR)',
            'Options': 'STRUCT("#text" BIGINT, hidden BOOLEAN, access VARCHAR, SiriShortcutVisible BOOLEAN, runwithfullaccess BOOLEAN, compatibility BIGINT)'
        }
    )
    WHERE id IS NOT NULL
),
script_healed AS (
    -- UUID-Healing (H1): Survivor = kleinste Script_ID je UUID behält die Original-UUID,
    -- weitere Zwillinge erhalten im INSERT unten die deterministische Ersatz-UUID
    -- (fm_heal_pick, Prelude). Doppel-Serialisierung (gleiche UUID UND gleiche ID)
    -- kollabiert weiterhin korrekt: Zeilen mit identischem Diskriminator erhalten
    -- identische UUIDs → ON CONFLICT greift wie bisher (3A-Weiche automatisch).
    -- Zweiter Hash-Partition-Pass auf dem bereits gelesenen Rowset — kein XML-Re-Scan.
    SELECT sr.*,
           (sr.UUID."#text" IS NULL
            OR sr.id = MIN(sr.id) OVER (PARTITION BY sr.UUID."#text")) AS is_survivor
    FROM script_records sr
)
INSERT INTO ScriptCatalog
SELECT
    sr.id AS Script_ID,
    xml_unescape(sr.name) AS Script_Name,
    sr.isFolder AS Folder_Type,
    COALESCE(sr.isSeparatorItem, False) AS Is_Separator,
    fm_heal_pick(sr.is_survivor, 'ScriptCatalog', fn.File_Name,
                 sr.UUID."#text", 'script_id=' || sr.id::VARCHAR) AS Script_UUID,
    sr.UUID.modifications AS Modifications,
    sr.UUID.userName AS Last_Modified_By,
    sr.UUID.timestamp AS Last_Modified_At,
    sr.Options."#text" AS Option_Bitmask,
    sr.Options.hidden AS Is_Hidden,
    sr.Options.runwithfullaccess AS Full_Access,
    sr.Sequence_ID,
    fn.File_Name as File_Name
FROM script_healed sr
CROSS JOIN filename_normalized fn
ON CONFLICT (Script_UUID, File_Name) DO UPDATE SET
    Script_ID = EXCLUDED.Script_ID,
    Script_Name = EXCLUDED.Script_Name,
    Folder_Type = EXCLUDED.Folder_Type,
    Is_Separator = EXCLUDED.Is_Separator,
    Modifications = EXCLUDED.Modifications,
    Last_Modified_By = EXCLUDED.Last_Modified_By,
    Last_Modified_At = EXCLUDED.Last_Modified_At,
    Option_Bitmask = EXCLUDED.Option_Bitmask,
    Is_Hidden = EXCLUDED.Is_Hidden,
    Full_Access = EXCLUDED.Full_Access,
    Sequence_ID = EXCLUDED.Sequence_ID;

-- Dup-Absorption-DETAILS (ScriptCatalog): Typ + Name der kollidierenden Scripts je
-- doppelt vergebener UUID. Liest denselben Quell-Rowset wie der Katalog-
-- INSERT oben (ScriptCatalog ist NICHT sub-gechunkt → Feed nur aus 'main', kein Turbo-
-- Multifed-Sonderfall). DELETE-vor-INSERT hält den Detail-Satz je (Katalog, Datei) beim
-- Re-Import frisch (analog zum per-Datei-Overwrite des Zensus). Bit-identisch zum
-- Katalog-INSERT (rein additiv, eigene Tabelle, keine Änderung bestehender Statements).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'ScriptCatalog'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        id,
        UUID->>'#text' AS Object_UUID,
        xml_unescape(name) AS Object_Name,
        CASE WHEN isFolder = 'True' THEN 'Folder'
             WHEN COALESCE(isSeparatorItem, False) THEN 'Separator'
             ELSE 'Script' END AS Object_Type,
        ROW_NUMBER() OVER () AS xml_ord
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='ScriptCatalog',
        record_element='Script',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'isFolder': 'VARCHAR',
            'isSeparatorItem': 'BOOLEAN',
            'UUID': 'STRUCT("#text" VARCHAR, modifications BIGINT, userName VARCHAR, accountName VARCHAR, timestamp VARCHAR)'
        }
    )
    WHERE id IS NOT NULL
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H1): Survivor-/Heal-Markierung, identische Logik wie im Katalog-INSERT
-- oben (Survivor = kleinste ID; Doppel-Serialisierung — gleiche UUID+ID — bleibt
-- 'absorbed', nur das jeweils erste Vorkommen einer (UUID, ID)-Identität trägt den
-- Katalog-Status). Der Zensus ist damit das persistierte Mapping Original↔Ersatz.
marked AS (
    SELECT s.*,
           (s.id IS NULL  -- NULL-id: kein Diskriminator → wie Survivor behandeln (nie 'healed')
            OR s.id = MIN(s.id) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.id ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'ScriptCatalog' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    -- Kontext (1.17.0): Scripts sind Top-Level → kein Container; Position = Stelle
    -- in der "Skripts verwalten"-Liste (XML-Reihenfolge, 1-basiert wie Sequence_ID).
    NULL AS Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name, 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('ScriptCatalog', getvariable('fm_file'), s.Object_UUID,
                           'script_id=' || s.id::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'script_id=' || s.id::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;


-- StepsForScripts
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS StepsForScripts (
    Script_ID BIGINT,
    Script_Name VARCHAR,
    Script_UUID VARCHAR,
    Step_Index BIGINT,
    Step_ID BIGINT,
    Step_Name VARCHAR,
    Is_Enabled BOOLEAN,
    Step_UUID VARCHAR,
    DDR_Hash VARCHAR,
    DDR_UUID VARCHAR,
    Parameters_XML VARCHAR,
    Step_XML VARCHAR,
    Parameter_Type VARCHAR,
    Variable_Name VARCHAR,
    Calculation_Text VARCHAR,
    Boolean_Type VARCHAR,
    Boolean_Value VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Step_UUID, File_Name)
);

-- Step_XML: vollständiges <Step>-Element.
-- Parameters_XML deckt nur /Step/ParameterValues ab; manche Step-Typen (z.B.
-- "Unknown external script step from missing plug-in") legen Referenzen AUSSERHALB
-- von ParameterValues ab. Phase 2 (XMLStepReferences) liest daher aus Step_XML.
-- ADD COLUMN für inkrementelle DBs ohne Force-Rebuild.
ALTER TABLE StepsForScripts ADD COLUMN IF NOT EXISTS Step_XML VARCHAR;

-- @P1_SECTION:StepsForScripts@
-- @STREAMIFY_BLOCK:stepsforscripts@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_scripts AS (
    SELECT
        unnest(xml_extract_elements(xml, '//StepsForScripts/Script')) as script_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
-- Performance (B-1): Script-Level-Felder
-- EINMAL pro Script auflösen, BEVOR die Steps unnested werden. Stehen scalar-
-- xml_extract auf dem großen script_xml-Fragment im SELBEN SELECT wie unnest(),
-- wertet DuckDB sie pro expandierter Step-Zeile aus (O(steps × script_größe)) und
-- re-parst script_xml je Step. Eigene CTE-Ebene davor → ~48× schneller, bit-
-- identische Ausgabe (verifiziert: Zeilenzahl + Content-Hash).
scripts_resolved AS (
    SELECT
        xml_extract_text(script_xml, '/Script/ScriptReference/@id')[1]::BIGINT as Script_ID,
        xml_extract_text(script_xml, '/Script/ScriptReference/@name')[1] as Script_Name,
        xml_extract_text(script_xml, '/Script/ScriptReference/@UUID')[1] as Script_UUID,
        script_xml
    FROM raw_scripts
),
script_steps AS (
    SELECT
        Script_ID,
        Script_Name,
        Script_UUID,
        unnest(xml_extract_elements(script_xml, '/Script/ObjectList/Step')) as step_xml
    FROM scripts_resolved
),
-- UUID-Healing (H2): Step_UUID + Identitätsfelder EINMAL extrahieren (der finale
-- SELECT liest sie als Spalten — kein Doppel-Parse), dann Survivor-Window.
-- Steps haben im SaXML KEINE Instanz-ID (/Step/@id ist die Step-TYP-ID!) —
-- Identität ist (Script_ID, Step_Index); nur positions-stabil (dokumentierte
-- Einschränkung). Doppel-Serialisierung (gleiche UUID UND gleiche
-- Identität) kollabiert weiterhin: identischer Diskriminator → identische
-- Ersatz-UUID → ON CONFLICT greift wie bisher (3A-Weiche automatisch).
-- Intra-Chunk-Sicht: chunk-übergreifende Paare heilt der catmerge-Nachschlag.
steps_extracted AS (
    SELECT
        Script_ID, Script_Name, Script_UUID, step_xml,
        xml_extract_text(step_xml, '/Step/@index')[1]::BIGINT as Step_Index,
        xml_extract_text(step_xml, '/Step/@id')[1]::BIGINT as Step_ID,
        xml_extract_text(step_xml, '/Step/UUID')[1] as Step_UUID
    FROM script_steps
),
steps_healed AS (
    SELECT s.*,
           (s.Step_UUID IS NULL OR s.Script_ID IS NULL OR s.Step_Index IS NULL  -- kein Diskriminator → nie heilen
            OR (s.Script_ID, s.Step_Index) =
               MIN((s.Script_ID, s.Step_Index)) OVER (PARTITION BY s.Step_UUID)) AS is_survivor
    FROM steps_extracted s
)
-- Explizite Spaltenliste (18 P1-Spalten): P3 verbreitert die Tabelle um die
-- abgeleitete Spalte Inserted_Text (ALTER TABLE, details:~1037). Ein spaltenloser
-- INSERT bricht dann auf dem sequentiellen Incremental-Pfad (P1 direkt gegen die
-- bestehende Master-/Test-DB, JOBS=1) mit "excluded has 18 columns … 19 specified".
-- Der Parallel-Pfad (frische Teil-DBs + INSERT BY NAME) war nie betroffen.
INSERT INTO StepsForScripts (
    Script_ID, Script_Name, Script_UUID, Step_Index, Step_ID, Step_Name,
    Is_Enabled, Step_UUID, DDR_Hash, DDR_UUID, Parameters_XML, Step_XML,
    Parameter_Type, Variable_Name, Calculation_Text, Boolean_Type, Boolean_Value,
    File_Name)
SELECT
    Script_ID,
    Script_Name,
    Script_UUID,
    Step_Index,
    Step_ID,
    xml_extract_text(step_xml, '/Step/@name')[1] as Step_Name,
    xml_extract_text(step_xml, '/Step/@enable')[1] = 'True' as Is_Enabled,
    fm_heal_pick(is_survivor, 'StepsForScripts', fn.File_Name, Step_UUID,
                 'script_id=' || Script_ID::VARCHAR || '·step_index=' || Step_Index::VARCHAR) as Step_UUID,
    xml_extract_text(step_xml, '/Step/DDRREF[@kind="StepText"]/@hash')[1] as DDR_Hash,
    regexp_replace(
        xml_extract_text(step_xml, '/Step/DDRREF[@kind="StepText"]')[1],
        '^_',
        ''
    ) as DDR_UUID,
    -- Roh-XML-Fragmente: ws_restore() holt den 0x7F-Sentinel zu LF zurueck (sonst
    -- leakte das DEL-Byte in die gespeicherte Roh-XML; native CR->LF im Sentinel-OFF-Pfad).
    ws_restore(xml_extract_elements(step_xml, '/Step/ParameterValues')[1]::VARCHAR) as Parameters_XML,
    ws_restore(step_xml::VARCHAR) as Step_XML,
    xml_extract_text(step_xml, '//Parameter/@type')[1] as Parameter_Type,
    xml_extract_text(step_xml, '//Parameter[@type="Variable"]/Name/@value')[1] as Variable_Name,
    -- not(ancestor::repetition): die Ziel-Feldreferenz eines Steps kann eine
    -- BERECHNETE Repetition tragen (<repetition><Calculation>…</Calculation></repetition>),
    -- die in Dokument-Reihenfolge VOR der eigentlichen Berechnung steht. Ein blankes
    -- '//Calculation/Text'[1] griffe dann den Repetitions-Ausdruck statt des zu setzenden
    -- Werts (betrifft Set Field, Replace Field Contents, Insert Calculated Result,
    -- Insert from URL u.a.). Der Prädikatsfilter schließt den Repetitions-Teilbaum aus und
    -- ist step-typ-unabhängig (die echte Berechnung ist je Step unterschiedlich verschachtelt).
    -- not(ancestor::Bounds): gleicher Fehlermodus bei Fensterschritten (New Window,
    -- Go to Related Record mit "New window"-Option, Move/Resize Window): trägt der Step
    -- KEINE Namens-Berechnung (leeres <Name/>), rückte sonst die erste Geometrie-
    -- Berechnung (<Bounds><height>…) nach — die Spalte meldete eine Fensterhöhe als
    -- vermeintlichen Fensternamen. Semantik der Spalte bleibt "erste Berechnung des
    -- Steps in Dokument-Reihenfolge, ohne Repetitions-/Geometrie-Slots"; ALLE
    -- Berechnungs-Slots eines Steps inkl. Slot-Kontext liefert StepCalculations (P3).
    ws_restore(xml_extract_text(step_xml, '//Calculation[not(ancestor::repetition)][not(ancestor::Bounds)]/Text')[1]) as Calculation_Text,
    xml_extract_text(step_xml, '//Boolean/@type')[1] as Boolean_Type,
    xml_extract_text(step_xml, '//Boolean/@value')[1] as Boolean_Value,
    fn.File_Name as File_Name
FROM steps_healed
CROSS JOIN filename_normalized fn
ON CONFLICT (Step_UUID, File_Name) DO UPDATE SET
    Script_ID = EXCLUDED.Script_ID,
    Script_Name = EXCLUDED.Script_Name,
    Script_UUID = EXCLUDED.Script_UUID,
    Step_Index = EXCLUDED.Step_Index,
    Step_ID = EXCLUDED.Step_ID,
    Step_Name = EXCLUDED.Step_Name,
    Is_Enabled = EXCLUDED.Is_Enabled,
    DDR_Hash = EXCLUDED.DDR_Hash,
    DDR_UUID = EXCLUDED.DDR_UUID,
    Parameters_XML = EXCLUDED.Parameters_XML,
    Step_XML = EXCLUDED.Step_XML,
    Parameter_Type = EXCLUDED.Parameter_Type,
    Variable_Name = EXCLUDED.Variable_Name,
    Calculation_Text = EXCLUDED.Calculation_Text,
    Boolean_Type = EXCLUDED.Boolean_Type,
    Boolean_Value = EXCLUDED.Boolean_Value;

-- Zensus (Dup-Absorption): geparste Step-Records dieses Laufs/Chunks. Leichter
-- Zweit-Read (Script-Fragmente unnesten, Steps nur ZÄHLEN — keine Spalten-Extrakte,
-- DOM bleibt pro Script-Fragment beschränkt). Kein staged-Refactor des bewährten
-- Katalog-INSERTs: Materialisieren der Step-Fragmente (TEMP-Stage) würde die größte
-- Roh-Spalte doppelt durch die Storage schreiben und die Upsert-Reihenfolge riskieren.
-- Beim Sub-Chunking schreibt jeder Chunk seine eigene Zeile (Chunk_Seq=seq_offset);
-- der P6-Check summiert — grenz-robust (zählt schlicht alle geparsten Records).
-- Liegt INNERHALB des STREAMIFY-Blocks: die SAX-Fassung führt ihren eigenen,
-- quellgleichen Zensus (ingestion/sql/streamify/stepsforscripts.sql).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'StepsForScripts', 'Step_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT,
       COALESCE(SUM(len(xml_extract_elements(script_xml, '/Script/ObjectList/Step'))), 0)
FROM (
    SELECT unnest(xml_extract_elements(xml, '//StepsForScripts/Script')) as script_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (StepsForScripts, 1.17.0): UUID-genaue Zeilen je doppelt
-- vergebener Step-UUID, mit Container-Script, Step-Position und Klartext — die
-- absorbierten Steps fehlen nach dem Upsert im Katalog, dieser Satz ist ihre einzige
-- Spur. Aufbau analog ScriptCatalog-Details: dups zuerst (nur UUID-Extrakt pro Step),
-- die teuren Extrakte (Name/Index/Calc/Payload) laufen NUR auf den Dup-Zeilen.
-- Script_Name auf eigener CTE-Ebene VOR dem unnest (Perf-Muster B-1, s. Katalog-INSERT).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'StepsForScripts'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH det_scripts AS (
    SELECT
        xml_extract_text(script_xml, '/Script/ScriptReference/@id')[1]::BIGINT as Script_ID,
        xml_extract_text(script_xml, '/Script/ScriptReference/@name')[1] as Script_Name,
        script_xml
    FROM (
        SELECT unnest(xml_extract_elements(xml, '//StepsForScripts/Script')) as script_xml
        FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
    )
),
det_steps AS (
    SELECT
        Script_ID,
        Script_Name,
        unnest(xml_extract_elements(script_xml, '/Script/ObjectList/Step')) as step_xml
    FROM det_scripts
),
src AS (
    SELECT
        Script_ID,
        Script_Name,
        step_xml,
        xml_extract_text(step_xml, '/Step/UUID')[1] AS Object_UUID,
        xml_extract_text(step_xml, '/Step/@index')[1]::BIGINT AS Step_Index,
        ROW_NUMBER() OVER () AS xml_ord
    FROM det_steps
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H2): Survivor-/Heal-Markierung, identische Logik wie im Katalog-
-- INSERT oben (Identität = (Script_ID, Step_Index); Doppel-Serialisierung —
-- gleiche UUID+Identität — bleibt 'absorbed'). Chunk-lokale Sicht: chunk-
-- übergreifende Paare erfasst der catmerge-Nachschlag (Chunk_Seq = -1).
marked AS (
    SELECT s.*,
           (s.Script_ID IS NULL OR s.Step_Index IS NULL
            OR (s.Script_ID, s.Step_Index) =
               MIN((s.Script_ID, s.Step_Index)) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.Script_ID, s.Step_Index
                              ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'StepsForScripts' AS Catalog,
    s.Object_UUID,
    xml_extract_text(s.step_xml, '/Step/@name')[1] AS Object_Name,
    'ScriptStep' AS Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    xml_unescape(s.Script_Name) AS Parent_Name,
    -- @index ist 0-basiert; user-facing Step-Nummer = index + 1 (Konvention Step_Index).
    'Step ' || (s.Step_Index + 1)::VARCHAR AS Position,
    left(
        xml_extract_text(s.step_xml, '/Step/@name')[1]
        || COALESCE(' — ' || ws_restore(xml_extract_text(s.step_xml,
               '//Calculation[not(ancestor::repetition)][not(ancestor::Bounds)]/Text')[1]), ''),
        500) AS Display_Text,
    left(ws_restore(s.step_xml::VARCHAR), 4000) AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('StepsForScripts', getvariable('fm_file'), s.Object_UUID,
                           'script_id=' || s.Script_ID::VARCHAR || '·step_index=' || s.Step_Index::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'script_id=' || s.Script_ID::VARCHAR || '·step_index=' || s.Step_Index::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;
-- @END_STREAMIFY_BLOCK@




-- Layouts
-- Folder_Type / Is_Separator analog zu ScriptCatalog: Layouts können im
-- "Manage Layouts"-Dialog Ordner und Trennlinien enthalten (isFolder="True"/"Marker").
-- Sequence_ID: laufende Nummer in der XML-Reihenfolge (siehe Hinweis bei ScriptCatalog).
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS Layouts (
    L_ID BIGINT,
    L_Name VARCHAR,
    L_UUID VARCHAR,
    L_TO_Name VARCHAR,
    -- Layout-Metadaten (Schema 1.5.0)
    L_TO_UUID VARCHAR,       -- Kontext-TO per UUID (statt fragiler Namens-Auflösung)
    L_Width BIGINT,         -- Layout-Breite in px
    L_Theme_ID BIGINT,       -- LayoutThemeReference (→ uses_theme-Kante)
    L_Theme_Name VARCHAR,
    L_Theme_UUID VARCHAR,
    -- Layout-MenuSet (Schema 1.5.1): CustomMenuSetReference im Layout-Tail
    -- (nach GridStyle/Options). id=0 / name="[File Default]" / UUID="" ist der
    -- Built-in-Default (kein Custom-MenuSet) → wird bereits hier auf NULL
    -- normalisiert; nur echte Referenzen (id≠0) → uses_menuset-Kante in P4.
    L_MenuSet_ID BIGINT,
    L_MenuSet_Name VARCHAR,
    L_MenuSet_UUID VARCHAR,
    -- Layout-Ansichten / Darstellungsform (Schema 1.8.0): bit-gepackt im <Options>-
    -- Integer des Layout-Tails (kein explizites XML-Element). Options_Raw = Rohwert
    -- (für spätere Bit-Ableitungen ohne Reimport). Decoder an 5 Layouts verifiziert:
    --   Bit1/2/3 = Form/Liste/Tabelle NICHT verfügbar (daher invertiert),
    --   Default_View = Bit14?'Table':Bit9?'List':'Form'.
    -- Nur für echte Layouts befüllt; Ordner/Trenner → NULL.
    Options_Raw BIGINT,
    View_Form_Available BOOLEAN,
    View_List_Available BOOLEAN,
    View_Table_Available BOOLEAN,
    Default_View VARCHAR,     -- 'Form' | 'List' | 'Table'
    -- Layout „Allgemein"-Optionen aus dem <Options>-Bitfeld (Schema 1.11.0), an 6
    -- Kalibrier-Layouts verifiziert. Nur echte Layouts; TRUE = Checkbox angehakt.
    Auto_Save_Changes BOOLEAN,          -- Bit4 invertiert: Datensatzänderungen automatisch speichern
    Show_Field_Frames BOOLEAN,          -- Bit5: Feldrahmen zeigen, wenn Datensatz aktiv ist
    Frame_Current_Record_Only BOOLEAN,  -- Bit0: Felder nur im aktuellen Datensatz umreißen
    Show_Current_Record_List BOOLEAN,   -- Bit28 invertiert: aktuelle Datensatzanzeige in der Listenansicht
    Quick_Find_Enabled BOOLEAN,         -- Bit15 invertiert: Schnellsuche aktivieren
    -- Layout-Metadaten (Schema 1.9.0):
    Is_Hidden BOOLEAN,        -- <Options @hidden> — "In Layout-Menüs aufnehmen" INVERTIERT
    L_Theme_Base VARCHAR,     -- LayoutThemeReference@Base (Basis-Theme des Custom-Themes)
    Modified_By VARCHAR,      -- <UUID @userName> — zuletzt geändert von
    Modified_At VARCHAR,      -- <UUID @timestamp> — ISO-Zeitstempel (roh als Text)
    Modifications BIGINT,    -- <UUID @modifications> — Änderungszähler
    Folder_Type VARCHAR,
    Is_Separator BOOLEAN,
    Sequence_ID BIGINT,
    File_Name VARCHAR,
    PRIMARY KEY (L_UUID, File_Name)
);

-- @P1_SECTION:LayoutCatalog@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
layout_records AS (
    SELECT
        ROW_NUMBER() OVER () + getvariable('seq_offset')::BIGINT AS Sequence_ID,
        id, name, width, isFolder, isSeparatorItem, UUID, TableOccurrenceReference,
        LayoutThemeReference, MenuSet,
        TRY_CAST(Options."#text" AS BIGINT) AS Options_Raw,
        Options.hidden AS Options_Hidden
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='LayoutCatalog',
        record_element='Layout',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'width': 'BIGINT',
            'isFolder': 'VARCHAR',
            'isSeparatorItem': 'BOOLEAN',
            -- UUID trägt Autoren-Metadaten als Attribute (bare names, kein "@"-Präfix)
            'UUID': 'STRUCT("#text" VARCHAR, userName VARCHAR, timestamp VARCHAR, modifications BIGINT)',
            'TableOccurrenceReference': 'STRUCT(name VARCHAR, UUID VARCHAR)',
            'LayoutThemeReference': 'STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR, Base VARCHAR)',
            'MenuSet': 'STRUCT("CustomMenuSetReference" STRUCT(id BIGINT, name VARCHAR, UUID VARCHAR))',
            -- <Options hidden="…">INT</Options> im Layout-Tail: bit-gepackte Ansichten-Config
            -- (#text) + @hidden (bare) = "In Layout-Menüs aufnehmen" invertiert.
            'Options': 'STRUCT("#text" VARCHAR, hidden VARCHAR)'
        }
    )
    -- Folder-Records (isFolder='True'/'Marker') haben keine TableOccurrenceReference;
    -- daher nur auf id filtern, sonst werden Ordner und Trennlinien ausgeschlossen.
    WHERE id IS NOT NULL
),
-- UUID-Healing (H2): Survivor = kleinste L_ID je UUID behält die Original-UUID.
-- Layouts ist SUB-GECHUNKT (SUBCHUNK_RECMAP LayoutCatalog:Layout) — das Window sieht
-- nur den eigenen Chunk; chunk-übergreifende Paare heilt der catmerge-Nachschlag
-- mit identischer Formel (deterministisch gleiche Ersatz-UUID). Doppel-Serialisierung
-- (gleiche UUID UND gleiche L_ID) kollabiert weiterhin (3A-Weiche automatisch).
layouts_healed AS (
    SELECT lr.*,
           (lr.UUID."#text" IS NULL OR lr.id IS NULL  -- kein Diskriminator → nie heilen
            OR lr.id = MIN(lr.id) OVER (PARTITION BY lr.UUID."#text")) AS is_survivor
    FROM layout_records lr
)
-- Explizite Spaltenliste zwingend: P3 erweitert Layouts um abgeleitete Spalten
-- (L_Theme_Resolved_Name/_UUID) — eine bestehende Master-DB hat also MEHR Spalten
-- als das DDL oben. Ein positionaler INSERT bindet dann nicht mehr (Binder Error
-- am excluded-Binding des UPSERT) und bricht jeden inkrementellen Lauf ab, der
-- P1 direkt gegen die Master-DB fährt (Einzeldatei-Modus).
INSERT INTO Layouts (
    L_ID, L_Name, L_UUID, L_TO_Name, L_TO_UUID, L_Width,
    L_Theme_ID, L_Theme_Name, L_Theme_UUID,
    L_MenuSet_ID, L_MenuSet_Name, L_MenuSet_UUID,
    Options_Raw, View_Form_Available, View_List_Available, View_Table_Available,
    Default_View, Auto_Save_Changes, Show_Field_Frames, Frame_Current_Record_Only,
    Show_Current_Record_List, Quick_Find_Enabled, Is_Hidden, L_Theme_Base,
    Modified_By, Modified_At, Modifications,
    Folder_Type, Is_Separator, Sequence_ID, File_Name
)
SELECT
    lr.id AS L_ID,
    xml_unescape(lr.name) AS L_Name,
    fm_heal_pick(lr.is_survivor, 'Layouts', fn.File_Name,
                 lr.UUID."#text", 'layout_id=' || lr.id::VARCHAR) AS L_UUID,
    xml_unescape(lr.TableOccurrenceReference.name) AS L_TO_Name,
    lr.TableOccurrenceReference.UUID AS L_TO_UUID,
    lr.width AS L_Width,
    lr.LayoutThemeReference.id AS L_Theme_ID,
    lr.LayoutThemeReference.name AS L_Theme_Name,
    lr.LayoutThemeReference.UUID AS L_Theme_UUID,
    -- Built-in-Default (id=0, "[File Default]") → NULL-Trio
    CASE WHEN lr.MenuSet.CustomMenuSetReference.id != 0
         THEN lr.MenuSet.CustomMenuSetReference.id END AS L_MenuSet_ID,
    CASE WHEN lr.MenuSet.CustomMenuSetReference.id != 0
         THEN xml_unescape(lr.MenuSet.CustomMenuSetReference.name) END AS L_MenuSet_Name,
    CASE WHEN lr.MenuSet.CustomMenuSetReference.id != 0
         THEN NULLIF(lr.MenuSet.CustomMenuSetReference.UUID, '') END AS L_MenuSet_UUID,
    -- Ansichten / Darstellungsform aus dem <Options>-Bitfeld (Schema 1.8.0).
    -- Rohwert immer, abgeleitete View-Spalten nur für echte Layouts (Ordner/Trenner
    -- tragen ein bedeutungsloses Bitmuster → NULL). Bit1/2/3 = Ansicht NICHT verfügbar.
    lr.Options_Raw AS Options_Raw,
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN ((lr.Options_Raw >> 1) & 1) = 0 END AS View_Form_Available,
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN ((lr.Options_Raw >> 2) & 1) = 0 END AS View_List_Available,
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN ((lr.Options_Raw >> 3) & 1) = 0 END AS View_Table_Available,
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN CASE WHEN ((lr.Options_Raw >> 14) & 1) = 1 THEN 'Table'
                   WHEN ((lr.Options_Raw >>  9) & 1) = 1 THEN 'List'
                   ELSE 'Form' END END AS Default_View,
    -- „Allgemein"-Optionen (Schema 1.11.0), nur echte Layouts. TRUE = angehakt.
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN ((lr.Options_Raw >>  4) & 1) = 0 END AS Auto_Save_Changes,
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN ((lr.Options_Raw >>  5) & 1) = 1 END AS Show_Field_Frames,
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN ((lr.Options_Raw >>  0) & 1) = 1 END AS Frame_Current_Record_Only,
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN ((lr.Options_Raw >> 28) & 1) = 0 END AS Show_Current_Record_List,
    CASE WHEN lr.isFolder IS NULL AND NOT COALESCE(lr.isSeparatorItem, False)
         THEN ((lr.Options_Raw >> 15) & 1) = 0 END AS Quick_Find_Enabled,
    -- Layout-Metadaten (Schema 1.9.0): @hidden ist "True"/"False" (Text) → Boolean.
    (lr.Options_Hidden = 'True') AS Is_Hidden,
    lr.LayoutThemeReference.Base AS L_Theme_Base,
    xml_unescape(lr.UUID.userName) AS Modified_By,
    lr.UUID.timestamp AS Modified_At,
    lr.UUID.modifications AS Modifications,
    lr.isFolder AS Folder_Type,
    COALESCE(lr.isSeparatorItem, False) AS Is_Separator,
    lr.Sequence_ID,
    fn.File_Name as File_Name
FROM layouts_healed lr
CROSS JOIN filename_normalized fn
ON CONFLICT (L_UUID, File_Name) DO UPDATE SET
    L_ID = EXCLUDED.L_ID,
    L_Name = EXCLUDED.L_Name,
    L_TO_Name = EXCLUDED.L_TO_Name,
    L_TO_UUID = EXCLUDED.L_TO_UUID,
    L_Width = EXCLUDED.L_Width,
    L_Theme_ID = EXCLUDED.L_Theme_ID,
    L_Theme_Name = EXCLUDED.L_Theme_Name,
    L_Theme_UUID = EXCLUDED.L_Theme_UUID,
    L_MenuSet_ID = EXCLUDED.L_MenuSet_ID,
    L_MenuSet_Name = EXCLUDED.L_MenuSet_Name,
    L_MenuSet_UUID = EXCLUDED.L_MenuSet_UUID,
    Options_Raw = EXCLUDED.Options_Raw,
    View_Form_Available = EXCLUDED.View_Form_Available,
    View_List_Available = EXCLUDED.View_List_Available,
    View_Table_Available = EXCLUDED.View_Table_Available,
    Default_View = EXCLUDED.Default_View,
    Auto_Save_Changes = EXCLUDED.Auto_Save_Changes,
    Show_Field_Frames = EXCLUDED.Show_Field_Frames,
    Frame_Current_Record_Only = EXCLUDED.Frame_Current_Record_Only,
    Show_Current_Record_List = EXCLUDED.Show_Current_Record_List,
    Quick_Find_Enabled = EXCLUDED.Quick_Find_Enabled,
    Is_Hidden = EXCLUDED.Is_Hidden,
    L_Theme_Base = EXCLUDED.L_Theme_Base,
    Modified_By = EXCLUDED.Modified_By,
    Modified_At = EXCLUDED.Modified_At,
    Modifications = EXCLUDED.Modifications,
    Folder_Type = EXCLUDED.Folder_Type,
    Is_Separator = EXCLUDED.Is_Separator,
    Sequence_ID = EXCLUDED.Sequence_ID;

-- Dup-Absorption-DETAILS (Layouts, 1.17.0): UUID-genaue Zeilen je doppelt vergebener
-- Layout-UUID (Muster ScriptCatalog-Details; Zweit-Read minimal: id/name/Flags/UUID/TO).
-- Läuft in der LayoutCatalog-Section, Chunk-fähig via Chunk_Seq/seq_offset.
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'Layouts'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        id,
        UUID."#text" AS Object_UUID,
        xml_unescape(name) AS Object_Name,
        CASE WHEN isFolder = 'True' THEN 'Layout Folder'
             WHEN isFolder = 'Marker' OR COALESCE(isSeparatorItem, False) THEN 'Layout Separator'
             ELSE 'Layout' END AS Object_Type,
        xml_unescape(TableOccurrenceReference.name) AS TO_Name,
        ROW_NUMBER() OVER () + COALESCE(getvariable('seq_offset'), 0)::BIGINT AS xml_ord
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='LayoutCatalog',
        record_element='Layout',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'id': 'BIGINT',
            'name': 'VARCHAR',
            'isFolder': 'VARCHAR',
            'isSeparatorItem': 'BOOLEAN',
            'UUID': 'STRUCT("#text" VARCHAR, userName VARCHAR, timestamp VARCHAR, modifications BIGINT)',
            'TableOccurrenceReference': 'STRUCT(name VARCHAR, UUID VARCHAR)'
        }
    )
    WHERE id IS NOT NULL
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H2): Survivor-/Heal-Markierung analog Katalog-INSERT (Survivor =
-- kleinste L_ID; chunk-lokale Sicht — chunk-übergreifende Paare erfasst der
-- catmerge-Nachschlag mit Chunk_Seq = -1).
marked AS (
    SELECT s.*,
           (s.id IS NULL
            OR s.id = MIN(s.id) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.id ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'Layouts' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    NULL AS Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name || COALESCE(' — context TO: ' || s.TO_Name, ''), 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('Layouts', getvariable('fm_file'), s.Object_UUID,
                           'layout_id=' || s.id::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'layout_id=' || s.id::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;

-- Hinweis: Layout-Ebene Script-Trigger liegen bereits in der vorhandenen Tabelle
-- ScriptTriggers (Owner_Type='Layout', Owner_UUID=L_UUID; multi-fed Merge via
-- convert_turbo.sh). Keine eigene Layout-Trigger-Tabelle nötig.

-- LayoutParts
-- @END_P1_SECTION@
-- Part_Seq (Schema 1.5.1): laufende Part-Nummer je Layout (XML-Reihenfolge,
-- 1-basiert). Der alte PK (Layout_ID, Part_Kind, File_Name) kollabierte mehrere
-- Parts gleicher Art (z.B. 3× Leading Sub-summary, kind=3) auf eine Zeile.
-- Break_*-Spalten: Umbruchfeld einer Sub-Summary aus Part/Definition/FieldReference
-- (+ TableOccurrenceReference-Kind) → breaks_on_field-Kante in P4.
CREATE TABLE IF NOT EXISTS LayoutParts (
    Layout_ID BIGINT,
    Layout_Name VARCHAR,
    Part_Seq BIGINT,
    Part_Type VARCHAR,
    Part_Kind BIGINT,
    Definition_Type VARCHAR,
    Definition_Kind BIGINT,
    Part_Size BIGINT,
    Part_Absolute BIGINT,
    Part_Options BIGINT,
    Object_Count BIGINT,
    Break_Field_ID BIGINT,
    Break_Field_Name VARCHAR,
    Break_Field_UUID VARCHAR,
    Break_TO_Name VARCHAR,
    Break_TO_UUID VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Layout_ID, Part_Seq, File_Name)
);

-- @P1_SECTION:LayoutCatalog@
-- @STREAMIFY_BLOCK:layoutparts@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_layouts AS (
    SELECT
        unnest(xml_extract_elements(xml, '//LayoutCatalog/Layout')) as layout_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
-- Performance (B-2): Layout-Level-Felder
-- EINMAL pro Layout auflösen, BEVOR die Parts unnested werden (Anti-Pattern wie
-- B-1: scalar-xml_extract auf layout_xml im selben SELECT wie unnest() → pro Part
-- re-evaluiert). Eigene CTE-Ebene davor.
layouts_resolved AS (
    SELECT
        xml_extract_text(layout_xml, '/Layout/@id')[1]::BIGINT as Layout_ID,
        xml_extract_text(layout_xml, '/Layout/@name')[1] as Layout_Name,
        layout_xml
    FROM raw_layouts
    WHERE xml_extract_text(layout_xml, '/Layout/@id')[1] IS NOT NULL
),
layout_parts_list AS (
    SELECT
        Layout_ID,
        Layout_Name,
        xml_extract_elements(layout_xml, '/Layout/PartsList/Part') as parts
    FROM layouts_resolved
),
layout_parts AS (
    -- Zip-Unnest: unnest() und generate_subscripts() laufen positionsgleich →
    -- Part_Seq = Listenposition (XML-Reihenfolge, 1-basiert).
    SELECT
        Layout_ID,
        Layout_Name,
        unnest(parts) as part_xml,
        generate_subscripts(parts, 1) as Part_Seq
    FROM layout_parts_list
),
parts_extracted AS (
    SELECT
        Layout_ID,
        Layout_Name,
        Part_Seq,
        xml_extract_text(part_xml, '/Part/@type')[1] as Part_Type,
        xml_extract_text(part_xml, '/Part/@kind')[1]::BIGINT as Part_Kind,
        xml_extract_text(part_xml, '/Part/Definition/@type')[1] as Definition_Type,
        xml_extract_text(part_xml, '/Part/Definition/@kind')[1]::BIGINT as Definition_Kind,
        xml_extract_text(part_xml, '/Part/Definition/@size')[1]::BIGINT as Part_Size,
        xml_extract_text(part_xml, '/Part/Definition/@absolute')[1]::BIGINT as Part_Absolute,
        xml_extract_text(part_xml, '/Part/Definition/@Options')[1]::BIGINT as Part_Options,
        list_count(xml_extract_elements(part_xml, '/Part/ObjectList/LayoutObject')) as Object_Count,
        xml_extract_text(part_xml, '/Part/Definition/FieldReference/@id')[1]::BIGINT as Break_Field_ID,
        xml_unescape(xml_extract_text(part_xml, '/Part/Definition/FieldReference/@name')[1]) as Break_Field_Name,
        xml_extract_text(part_xml, '/Part/Definition/FieldReference/@UUID')[1] as Break_Field_UUID,
        xml_unescape(xml_extract_text(part_xml, '/Part/Definition/FieldReference/TableOccurrenceReference/@name')[1]) as Break_TO_Name,
        xml_extract_text(part_xml, '/Part/Definition/FieldReference/TableOccurrenceReference/@UUID')[1] as Break_TO_UUID
    FROM layout_parts
)
INSERT INTO LayoutParts
SELECT
    Layout_ID,
    Layout_Name,
    Part_Seq,
    Part_Type,
    Part_Kind,
    Definition_Type,
    Definition_Kind,
    Part_Size,
    Part_Absolute,
    Part_Options,
    Object_Count,
    -- Leere Platzhalter-Referenz (id=0, leerer Name — Body/Header/Footer tragen
    -- sie flächig) → NULL-Quintett; nur echte FieldReferences bleiben stehen.
    CASE WHEN Break_Field_ID != 0 THEN Break_Field_ID END as Break_Field_ID,
    CASE WHEN Break_Field_ID != 0 THEN Break_Field_Name END as Break_Field_Name,
    CASE WHEN Break_Field_ID != 0 THEN Break_Field_UUID END as Break_Field_UUID,
    CASE WHEN Break_Field_ID != 0 THEN Break_TO_Name END as Break_TO_Name,
    CASE WHEN Break_Field_ID != 0 THEN Break_TO_UUID END as Break_TO_UUID,
    fn.File_Name as File_Name
FROM parts_extracted
CROSS JOIN filename_normalized fn
ON CONFLICT (Layout_ID, Part_Seq, File_Name) DO UPDATE SET
    Layout_Name = EXCLUDED.Layout_Name,
    Part_Type = EXCLUDED.Part_Type,
    Part_Kind = EXCLUDED.Part_Kind,
    Definition_Type = EXCLUDED.Definition_Type,
    Definition_Kind = EXCLUDED.Definition_Kind,
    Part_Size = EXCLUDED.Part_Size,
    Part_Absolute = EXCLUDED.Part_Absolute,
    Part_Options = EXCLUDED.Part_Options,
    Object_Count = EXCLUDED.Object_Count,
    Break_Field_ID = EXCLUDED.Break_Field_ID,
    Break_Field_Name = EXCLUDED.Break_Field_Name,
    Break_Field_UUID = EXCLUDED.Break_Field_UUID,
    Break_TO_Name = EXCLUDED.Break_TO_Name,
    Break_TO_UUID = EXCLUDED.Break_TO_UUID;
-- @END_STREAMIFY_BLOCK@


-- ========================================
-- LayoutObjects
-- ========================================
-- Alle Layout-Objekte mit rekursiver Verschachtelung
-- (Portal, Group, Tab Control, Panel, Container, etc.)
--
-- Verwendet WITH RECURSIVE für verschachtelte Objekte:
-- - Level 0: Root-Objekte direkt in Parts
-- - Level 1+: Verschachtelte Objekte in Portals, Groups, Tab Controls, etc.
-- ========================================

-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS LayoutObjects (
    Layout_ID BIGINT,
    Part_Type VARCHAR,
    Object_ID BIGINT,
    Object_Type VARCHAR,
    Object_Name VARCHAR,
    Object_Kind BIGINT,
    Object_Hash VARCHAR,
    Object_UUID VARCHAR,
    Bounds_Top BIGINT,
    Bounds_Left BIGINT,
    Bounds_Bottom BIGINT,
    Bounds_Right BIGINT,
    Parent_Object_ID BIGINT,
    Nesting_Level BIGINT,
    Z_Order BIGINT,
    Hide_Calculation_Text VARCHAR,
    Tooltip_Calculation_Text VARCHAR,
    Label_Calculation_Text VARCHAR,
    ScriptTrigger_Parameter_Text VARCHAR,
    Text_Content VARCHAR,
    Object_XML VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Object_UUID, File_Name)
);

-- @P1_SECTION:LayoutCatalog@
-- @STREAMIFY_BLOCK:layoutobjects@
WITH RECURSIVE filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_layouts AS (
    SELECT
        unnest(xml_extract_elements(xml, '//LayoutCatalog/Layout')) as layout_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
-- Performance (B-2): Layout- und Part-Level-
-- Felder jeweils EINMAL auflösen, BEVOR genested wird (Anti-Pattern wie B-1).
-- layout_xml bzw. part_xml sind große Fragmente; scalar-xml_extract im selben
-- SELECT wie das unnest würde pro Part bzw. pro Objekt re-evaluiert.
layouts_resolved AS (
    SELECT
        xml_extract_text(layout_xml, '/Layout/@id')[1]::BIGINT as Layout_ID,
        xml_extract_text(layout_xml, '/Layout/@name')[1] as Layout_Name,
        xml_extract_text(layout_xml, '/Layout/UUID/@*')[1] as Layout_UUID,
        layout_xml
    FROM raw_layouts
),
layout_parts AS (
    SELECT
        Layout_ID,
        Layout_Name,
        Layout_UUID,
        unnest(xml_extract_elements(layout_xml, '/Layout/PartsList/Part')) as part_xml
    FROM layouts_resolved
),
parts_resolved AS (
    SELECT
        Layout_ID,
        xml_extract_text(part_xml, '/Part/@type')[1] as Part_Type,
        part_xml
    FROM layout_parts
),
root_objects AS (
    SELECT
        Layout_ID,
        Part_Type,
        xml_extract_text(object_xml, '/LayoutObject/@id')[1]::BIGINT as Object_ID,
        fm_canon_layout_type(
            xml_extract_text(object_xml, '/LayoutObject/@type')[1],
            xml_extract_text(object_xml, '/LayoutObject/@kind')[1]::BIGINT,
            object_xml) as Object_Type,
        xml_unescape(xml_extract_text(object_xml, '/LayoutObject/@name')[1]) as Object_Name,
        xml_extract_text(object_xml, '/LayoutObject/@kind')[1]::BIGINT as Object_Kind,
        xml_extract_text(object_xml, '/LayoutObject/@hash')[1] as Object_Hash,
        xml_extract_text(object_xml, '/LayoutObject/UUID')[1] as Object_UUID,
        xml_extract_text(object_xml, '/LayoutObject/Bounds/@top')[1]::BIGINT as Bounds_Top,
        xml_extract_text(object_xml, '/LayoutObject/Bounds/@left')[1]::BIGINT as Bounds_Left,
        xml_extract_text(object_xml, '/LayoutObject/Bounds/@bottom')[1]::BIGINT as Bounds_Bottom,
        xml_extract_text(object_xml, '/LayoutObject/Bounds/@right')[1]::BIGINT as Bounds_Right,
        NULL::BIGINT as Parent_Object_ID,
        0 as Nesting_Level,
        t.z_order::BIGINT as Z_Order,
        -- Calculation Text Extraction (CDATA aus XML)
        xml_extract_text(object_xml, '/LayoutObject/Conditions/Hide/Calculation/Text')[1] as Hide_Calculation_Text,
        xml_extract_text(object_xml, '/LayoutObject/Tooltip/Calculation/Text')[1] as Tooltip_Calculation_Text,
        COALESCE(
            xml_extract_text(object_xml, '/LayoutObject/Button/Label/Calculation/Text')[1],
            xml_extract_text(object_xml, '/LayoutObject/GroupedButton/Label/Calculation/Text')[1],
            xml_extract_text(object_xml, '/LayoutObject/PopoverButton/Label/Calculation/Text')[1]
        ) as Label_Calculation_Text,
        array_to_string(
            xml_extract_text(object_xml, '/LayoutObject/ScriptTriggers/ScriptTrigger/ScriptReference/Calculation/Text'),
            E'\n'
        ) as ScriptTrigger_Parameter_Text,
        xml_extract_text(object_xml, '/LayoutObject/Text/StyledText/Data')[1] as Text_Content,
        object_xml
    FROM parts_resolved
    CROSS JOIN LATERAL unnest(
        xml_extract_elements(part_xml, '/Part/ObjectList/LayoutObject')
    ) WITH ORDINALITY AS t(object_xml, z_order)
),
nested_objects AS (
    SELECT
        Layout_ID,
        Part_Type,
        Object_ID,
        Object_Type,
        Object_Name,
        Object_Kind,
        Object_Hash,
        Object_UUID,
        Bounds_Top,
        Bounds_Left,
        Bounds_Bottom,
        Bounds_Right,
        Parent_Object_ID,
        Nesting_Level,
        Z_Order,
        Hide_Calculation_Text,
        Tooltip_Calculation_Text,
        Label_Calculation_Text,
        ScriptTrigger_Parameter_Text,
        Text_Content,
        object_xml
    FROM root_objects

    UNION ALL

    SELECT
        parent.Layout_ID,
        parent.Part_Type,
        xml_extract_text(child_xml, '/LayoutObject/@id')[1]::BIGINT as Object_ID,
        fm_canon_layout_type(
            xml_extract_text(child_xml, '/LayoutObject/@type')[1],
            xml_extract_text(child_xml, '/LayoutObject/@kind')[1]::BIGINT,
            child_xml) as Object_Type,
        xml_unescape(xml_extract_text(child_xml, '/LayoutObject/@name')[1]) as Object_Name,
        xml_extract_text(child_xml, '/LayoutObject/@kind')[1]::BIGINT as Object_Kind,
        xml_extract_text(child_xml, '/LayoutObject/@hash')[1] as Object_Hash,
        xml_extract_text(child_xml, '/LayoutObject/UUID')[1] as Object_UUID,
        xml_extract_text(child_xml, '/LayoutObject/Bounds/@top')[1]::BIGINT as Bounds_Top,
        xml_extract_text(child_xml, '/LayoutObject/Bounds/@left')[1]::BIGINT as Bounds_Left,
        xml_extract_text(child_xml, '/LayoutObject/Bounds/@bottom')[1]::BIGINT as Bounds_Bottom,
        xml_extract_text(child_xml, '/LayoutObject/Bounds/@right')[1]::BIGINT as Bounds_Right,
        parent.Object_ID as Parent_Object_ID,
        parent.Nesting_Level + 1 as Nesting_Level,
        t.z_order::BIGINT as Z_Order,
        -- Calculation Text Extraction (CDATA aus XML)
        xml_extract_text(child_xml, '/LayoutObject/Conditions/Hide/Calculation/Text')[1] as Hide_Calculation_Text,
        xml_extract_text(child_xml, '/LayoutObject/Tooltip/Calculation/Text')[1] as Tooltip_Calculation_Text,
        COALESCE(
            xml_extract_text(child_xml, '/LayoutObject/Button/Label/Calculation/Text')[1],
            xml_extract_text(child_xml, '/LayoutObject/GroupedButton/Label/Calculation/Text')[1],
            xml_extract_text(child_xml, '/LayoutObject/PopoverButton/Label/Calculation/Text')[1]
        ) as Label_Calculation_Text,
        array_to_string(
            xml_extract_text(child_xml, '/LayoutObject/ScriptTriggers/ScriptTrigger/ScriptReference/Calculation/Text'),
            E'\n'
        ) as ScriptTrigger_Parameter_Text,
        -- PopoverPanel-Titel (Feldreferenzen) per Title/Text-Fallback
        -- mitführen; reguläre Objekte haben nur StyledText/Data.
        COALESCE(
            xml_extract_text(child_xml, '/LayoutObject/Text/StyledText/Data')[1],
            xml_extract_text(child_xml, '/LayoutObject/Title/Text')[1]
        ) as Text_Content,
        child_xml as object_xml
    FROM nested_objects parent
    CROSS JOIN LATERAL unnest(
        -- Achsen-Wahl pro Parent-Typ (ein einziger rekursiver Term, da
        -- WITH RECURSIVE nur einen rekursiven Term erlaubt). DIREKTE Kind-Achsen:
        -- die frühere Descendant-Achse '//ObjectList/LayoutObject'
        -- emittierte JEDEN Nachfahren am obersten Container; das min-Nesting-
        -- Dedup unten machte daraus eine systematisch flachgeklopfte Hierarchie
        -- (Panels korpus-weit 0 Kinder, max. Nesting 2 statt 4).
        --   * 'Popover Button': exakter Kind-Pfad zum PopoverPanel, das
        --     direktes Kind von <PopoverButton> ist (NICHT unter <ObjectList>).
        --   * 'PopoverPanel': seine ObjectList ist DIREKTES Kind des
        --     <LayoutObject> (einziger Typ ohne Wrapper-Element).
        --   * alle anderen Container: '/LayoutObject/*/ObjectList/LayoutObject'
        --     — genau EIN typspezifisches Wrapper-Element (<Portal>, <Group>,
        --     <TabControlObj>, <GroupedButton>, …) zwischen LayoutObject und
        --     ObjectList; korpus-verifiziert (kein Typ mit 2 Wrapper-Ebenen,
        --     Summe Root+direkte Kinder == Objektbestand, 12 bekannte
        --     Doppel-Serialisierungen fängt das Dedup unten).
        CASE
            WHEN parent.Object_Type = 'Popover Button'
                THEN xml_extract_elements(parent.object_xml, '/LayoutObject/PopoverButton/LayoutObject')
            WHEN parent.Object_Type = 'PopoverPanel'
                THEN xml_extract_elements(parent.object_xml, '/LayoutObject/ObjectList/LayoutObject')
            ELSE xml_extract_elements(parent.object_xml, '/LayoutObject/*/ObjectList/LayoutObject')
        END
    ) WITH ORDINALITY AS t(child_xml, z_order)
    WHERE parent.Object_Type IN (
        'Portal',
        'Group',
        'Tab Control',
        'Panel',
        'Container',
        'Button Bar',
        'Slide Control',
        'Grouped Button',
        'PopoverPanel',
        'Popover Button'
    )
)
INSERT INTO LayoutObjects
SELECT
    Layout_ID,
    Part_Type,
    Object_ID,
    Object_Type,
    Object_Name,
    Object_Kind,
    Object_Hash,
    -- NULL-PK-Guard: der PK (Object_UUID, File_Name) verbietet NULL —
    -- ein einziges Objekt ohne UUID bräche sonst das GESAMTE INSERT. Deterministischer,
    -- serialisierungs-unabhängiger md5-Fallback aus extrahierten Identitätsfeldern
    -- (Muster ScriptTriggers-Owner_UUID; Roh-XML hashen würde unter SAX divergieren).
    -- UUID-Healing (H2): fm_heal_pick um den Guard herum — bei NULL-UUID ist
    -- _is_survivor TRUE (Guard-md5 ist bereits zeilen-eindeutig und wird NIE
    -- geheilt); Copy-Paste-Zwillinge (gleiche UUID, verschiedene (Layout_ID,
    -- Object_ID)) erhalten die deterministische Ersatz-UUID. Identität =
    -- (Layout_ID, Object_ID) — die S0-3-Zähl-Identität des Zensus.
    fm_heal_pick(_is_survivor, 'LayoutObjects', fn.File_Name,
        COALESCE(Object_UUID, md5(
            'LayoutObjectNoUUID|' ||
            COALESCE(Layout_ID::VARCHAR, '') || '|' ||
            COALESCE(Object_ID::VARCHAR, '') || '|' ||
            COALESCE(Object_Type, '') || '|' ||
            COALESCE(Part_Type, '') || '|' ||
            COALESCE(Nesting_Level::VARCHAR, '') || '|' ||
            COALESCE(Z_Order::VARCHAR, '')
        )),
        'layout_id=' || COALESCE(Layout_ID::VARCHAR, '') ||
        '·object_id=' || COALESCE(Object_ID::VARCHAR, '')) as Object_UUID,
    Bounds_Top,
    Bounds_Left,
    Bounds_Bottom,
    Bounds_Right,
    Parent_Object_ID,
    Nesting_Level,
    Z_Order,
    -- chr(127) -> chr(10): Preprocessing-Sentinel für CR zurück zu LF
    ws_restore(Hide_Calculation_Text) as Hide_Calculation_Text,
    ws_restore(Tooltip_Calculation_Text) as Tooltip_Calculation_Text,
    ws_restore(Label_Calculation_Text) as Label_Calculation_Text,
    ws_restore(ScriptTrigger_Parameter_Text) as ScriptTrigger_Parameter_Text,
    ws_restore(Text_Content) as Text_Content,
    -- Roh-XML-Fragment: 0x7F-Sentinel -> LF (siehe Parameters_XML/Step_XML oben).
    ws_restore(object_xml::VARCHAR) as Object_XML,
    fn.File_Name as File_Name
-- DETERMINISTISCHES DEDUP (Chunk-Invarianz): Mit den direkten
-- Kind-Achsen (s. o.) wird jedes Objekt strukturell genau EINMAL emittiert —
-- mit einer korpus-realen Ausnahme: FileMaker serialisiert manche Objekte doppelt
-- (am Part-Root UND in einer GroupedButton-ObjectList; 12 Fälle im Korpus). Das
-- Dedup wählt pro Identität deterministisch die FLACHSTE Emission (min Nesting_Level
-- → Root gewinnt, identisch zum bisherigen Ergebnis) und bleibt damit reihenfolge-/
-- chunk-invariant. NULL-UUID-Objekte (kein Conflict-Key) bleiben alle erhalten;
-- ihr PK entsteht per md5-Fallback im SELECT oben.
-- UUID-Healing (H2): Partition um Object_ID ERWEITERT — (Layout_ID, Object_UUID,
-- Object_ID) ist exakt der Doppel-Serialisierungs-Schlüssel (S0-3): die 12 Korpus-
-- Fälle (gleiche Object_ID) kollabieren weiterhin, echte Copy-Paste-Zwillinge
-- (gleiche UUID, VERSCHIEDENE Object_ID) überleben jetzt bis zur Heilung statt
-- vor dem Upsert verworfen zu werden. _is_survivor über die Roh-Emissionen ist
-- äquivalent zur Sicht nach dem Dedup (identische Identität → identisches MIN).
FROM (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY Layout_ID, Object_UUID, Object_ID
                           ORDER BY Nesting_Level ASC, Parent_Object_ID NULLS FIRST, Z_Order DESC) AS _dedup_rn,
        (Object_UUID IS NULL OR Layout_ID IS NULL OR Object_ID IS NULL  -- kein Diskriminator → nie heilen
         OR (Layout_ID, Object_ID) =
            MIN((Layout_ID, Object_ID)) OVER (PARTITION BY Object_UUID)) AS _is_survivor
    FROM nested_objects
) nested_objects
CROSS JOIN filename_normalized fn
WHERE Object_UUID IS NULL OR _dedup_rn = 1
ON CONFLICT (Object_UUID, File_Name) DO UPDATE SET
    Layout_ID = EXCLUDED.Layout_ID,
    Part_Type = EXCLUDED.Part_Type,
    Object_ID = EXCLUDED.Object_ID,
    Object_Type = EXCLUDED.Object_Type,
    Object_Name = EXCLUDED.Object_Name,
    Object_Kind = EXCLUDED.Object_Kind,
    Object_Hash = EXCLUDED.Object_Hash,
    Bounds_Top = EXCLUDED.Bounds_Top,
    Bounds_Left = EXCLUDED.Bounds_Left,
    Bounds_Bottom = EXCLUDED.Bounds_Bottom,
    Bounds_Right = EXCLUDED.Bounds_Right,
    Parent_Object_ID = EXCLUDED.Parent_Object_ID,
    Nesting_Level = EXCLUDED.Nesting_Level,
    Z_Order = EXCLUDED.Z_Order,
    Hide_Calculation_Text = EXCLUDED.Hide_Calculation_Text,
    Tooltip_Calculation_Text = EXCLUDED.Tooltip_Calculation_Text,
    Label_Calculation_Text = EXCLUDED.Label_Calculation_Text,
    ScriptTrigger_Parameter_Text = EXCLUDED.ScriptTrigger_Parameter_Text,
    Text_Content = EXCLUDED.Text_Content,
    Object_XML = EXCLUDED.Object_XML;

-- Zensus (Dup-Absorption): Emissionsmenge des LayoutObjects-INSERTs. Schlanke
-- Zweit-Rekursion (gleiche Kind-Achsen/Container-Typen wie oben), aber OHNE die
-- ~15 Spalten-Extrakte je Objekt — nur Layout/ID/Typ/Name/UUID. Seit 1.17.0 als
-- TEMP-Stage materialisiert, damit Zensus UND Detail-Erfassung EINE Rekursion
-- teilen (statt einer dritten Voll-Rekursion für die Details).
-- Zähl-Semantik (S0-3): je (Layout_ID, Object_UUID, Object_ID) EINE Emission —
-- FileMakers Doppel-Serialisierung (gleiches Objekt, gleiche id, Root + Container-
-- ObjectList; 12 Fälle im Korpus) zählt weiterhin nicht als Verlust, aber echte
-- Copy-Paste-Dups (gleiche UUID an VERSCHIEDENEN Object_IDs) zählen
-- jetzt — die waren bis 1.16 systematisch unsichtbar. NULL-UUID-Objekte einzeln
-- (md5-Fallback-PK, kollisionsfrei). Differenz zur gespeicherten Zeilenzahl =
-- kollabierte UUID-Dubletten (layout-übergreifend UND intra-Layout).
-- Liegt INNERHALB des STREAMIFY-Blocks: die SAX-Fassung führt ihre eigene,
-- quellgleiche Stage (ingestion/sql/streamify/layoutobjects.sql).
CREATE OR REPLACE TEMP TABLE _lo_census AS
WITH RECURSIVE census_parts AS (
    SELECT
        xml_extract_text(layout_xml, '/Layout/@id')[1]::BIGINT as Layout_ID,
        xml_unescape(xml_extract_text(layout_xml, '/Layout/@name')[1]) as Layout_Name,
        unnest(xml_extract_elements(layout_xml, '/Layout/PartsList/Part')) as part_xml
    FROM (
        SELECT unnest(xml_extract_elements(xml, '//LayoutCatalog/Layout')) as layout_xml
        FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
    )
),
census_objects AS (
    SELECT
        Layout_ID,
        Layout_Name,
        xml_extract_text(object_xml, '/LayoutObject/@id')[1]::BIGINT as Object_ID,
        fm_canon_layout_type(
            xml_extract_text(object_xml, '/LayoutObject/@type')[1],
            xml_extract_text(object_xml, '/LayoutObject/@kind')[1]::BIGINT,
            object_xml) as Object_Type,
        xml_unescape(xml_extract_text(object_xml, '/LayoutObject/@name')[1]) as Object_Name,
        xml_extract_text(object_xml, '/LayoutObject/UUID')[1] as Object_UUID,
        object_xml
    FROM census_parts
    CROSS JOIN LATERAL unnest(
        xml_extract_elements(part_xml, '/Part/ObjectList/LayoutObject')
    ) AS t(object_xml)

    UNION ALL

    SELECT
        parent.Layout_ID,
        parent.Layout_Name,
        xml_extract_text(child_xml, '/LayoutObject/@id')[1]::BIGINT as Object_ID,
        fm_canon_layout_type(
            xml_extract_text(child_xml, '/LayoutObject/@type')[1],
            xml_extract_text(child_xml, '/LayoutObject/@kind')[1]::BIGINT,
            child_xml) as Object_Type,
        xml_unescape(xml_extract_text(child_xml, '/LayoutObject/@name')[1]) as Object_Name,
        xml_extract_text(child_xml, '/LayoutObject/UUID')[1] as Object_UUID,
        child_xml as object_xml
    FROM census_objects parent
    CROSS JOIN LATERAL unnest(
        CASE
            WHEN parent.Object_Type = 'Popover Button'
                THEN xml_extract_elements(parent.object_xml, '/LayoutObject/PopoverButton/LayoutObject')
            WHEN parent.Object_Type = 'PopoverPanel'
                THEN xml_extract_elements(parent.object_xml, '/LayoutObject/ObjectList/LayoutObject')
            ELSE xml_extract_elements(parent.object_xml, '/LayoutObject/*/ObjectList/LayoutObject')
        END
    ) AS t(child_xml)
    WHERE parent.Object_Type IN (
        'Portal',
        'Group',
        'Tab Control',
        'Panel',
        'Container',
        'Button Bar',
        'Slide Control',
        'Grouped Button',
        'PopoverPanel',
        'Popover Button'
    )
)
SELECT Layout_ID, Layout_Name, Object_ID, Object_Type, Object_Name, Object_UUID
FROM census_objects;

INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'LayoutObjects', 'Object_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT,
       COUNT(*) FILTER (WHERE Object_UUID IS NULL)
         + COUNT(DISTINCT (Layout_ID, Object_UUID, Object_ID)) FILTER (WHERE Object_UUID IS NOT NULL)
FROM _lo_census
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (LayoutObjects, 1.17.0): eine Zeile je ECHTEM Vorkommen
-- einer doppelt vergebenen Objekt-UUID. Gruppierung auf (Layout_ID, Object_ID)
-- kollabiert FileMakers Doppel-Serialisierung (kein Defekt); >1 verbleibende
-- Vorkommen je UUID = echte Kollision (Copy-Paste intra-Layout ODER layout-
-- übergreifend in derselben Datei).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'LayoutObjects'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH occ AS (
    SELECT
        Object_UUID,
        Layout_ID,
        any_value(Layout_Name) AS Layout_Name,
        Object_ID,
        any_value(Object_Type) AS Object_Type,
        any_value(Object_Name) AS Object_Name
    FROM _lo_census
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID, Layout_ID, Object_ID
),
dups AS (
    SELECT Object_UUID FROM occ
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H2): Survivor-/Heal-Markierung analog Katalog-INSERT (Identität =
-- (Layout_ID, Object_ID) — occ ist bereits je Identität dedupliziert, daher kein
-- occ_within_id nötig; Doppel-Serialisierung ist hier schon kollabiert). Chunk-
-- lokale Sicht: chunk-übergreifende Paare erfasst der catmerge-Nachschlag.
marked AS (
    SELECT o.*,
           (o.Layout_ID IS NULL OR o.Object_ID IS NULL
            OR (o.Layout_ID, o.Object_ID) =
               MIN((o.Layout_ID, o.Object_ID)) OVER (PARTITION BY o.Object_UUID)) AS is_min_id
    FROM occ o
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'LayoutObjects' AS Catalog,
    o.Object_UUID,
    o.Object_Name,
    o.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY o.Object_UUID ORDER BY o.Layout_ID, o.Object_ID) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    o.Layout_Name AS Parent_Name,
    'Layout ' || COALESCE(o.Layout_ID::VARCHAR, '?') || ' · object id ' || COALESCE(o.Object_ID::VARCHAR, '?') AS Position,
    left(o.Object_Type || COALESCE(' "' || NULLIF(o.Object_Name, '') || '"', ''), 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT o.is_min_id
         THEN fm_heal_uuid('LayoutObjects', getvariable('fm_file'), o.Object_UUID,
                           'layout_id=' || COALESCE(o.Layout_ID::VARCHAR, '') ||
                           '·object_id=' || COALESCE(o.Object_ID::VARCHAR, '')) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN o.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'layout_id=' || COALESCE(o.Layout_ID::VARCHAR, '') ||
    '·object_id=' || COALESCE(o.Object_ID::VARCHAR, '') AS Discriminator
FROM marked o
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;

DROP TABLE IF EXISTS _lo_census;
-- @END_STREAMIFY_BLOCK@




-- AccountsCatalog
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS AccountsCatalog (
    Account_ID BIGINT,
    Account_Kind BIGINT,
    Account_Type VARCHAR,
    Is_Enabled BOOLEAN,
    Account_UUID VARCHAR,
    Description VARCHAR,
    Account_Name VARCHAR,
    Password_Encrypted VARCHAR,
    PrivilegeSet_ID BIGINT,
    PrivilegeSet_Name VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Account_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
account_records AS (
    -- Rowset NACH UNNEST + Zeilenfilter — identischer Zeilen-Scope wie der bisherige
    -- Katalog-INSERT (das Survivor-Window unten MUSS auf dem entfalteten, gefilterten
    -- Rowset laufen, nicht auf den ObjectList-Records).
    SELECT a
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='AccountsCatalog',
        record_element='ObjectList',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'Account': 'STRUCT(
                id BIGINT,
                kind BIGINT,
                type VARCHAR,
                enable BOOLEAN,
                "UUID" STRUCT("#text" VARCHAR, modifications BIGINT, userName VARCHAR, accountName VARCHAR, timestamp VARCHAR),
                "Description" VARCHAR,
                "Authentication" STRUCT(
                    "AccountName" VARCHAR,
                    "PasswordEncrypted" VARCHAR
                ),
                "PrivilegeSetReference" STRUCT(
                    id BIGINT,
                    name VARCHAR
                )
            )[]'
        }
    )
    CROSS JOIN UNNEST(Account) AS t(a)
    WHERE a.id IS NOT NULL
),
account_healed AS (
    -- UUID-Healing (H1): Survivor = kleinste Account_ID je UUID behält die Original-
    -- UUID, weitere Zwillinge erhalten im INSERT unten die deterministische Ersatz-
    -- UUID (fm_heal_pick, Prelude). Doppel-Serialisierung (gleiche UUID UND gleiche
    -- ID) kollabiert weiterhin korrekt: Zeilen mit identischem Diskriminator erhalten
    -- identische UUIDs → ON CONFLICT greift wie bisher.
    -- Zweiter Hash-Partition-Pass auf dem bereits gelesenen Rowset — kein XML-Re-Scan.
    SELECT ar.*,
           (ar.a.UUID."#text" IS NULL
            OR ar.a.id = MIN(ar.a.id) OVER (PARTITION BY ar.a.UUID."#text")) AS is_survivor
    FROM account_records ar
)
INSERT INTO AccountsCatalog
SELECT
    a.id AS Account_ID,
    a.kind AS Account_Kind,
    a.type AS Account_Type,
    a.enable AS Is_Enabled,
    fm_heal_pick(is_survivor, 'AccountsCatalog', fn.File_Name,
                 a.UUID."#text", 'account_id=' || a.id::VARCHAR) AS Account_UUID,
    ws_restore(a.Description) AS Description,
    xml_unescape(a.Authentication.AccountName) AS Account_Name,
    a.Authentication.PasswordEncrypted AS Password_Encrypted,
    a.PrivilegeSetReference.id AS PrivilegeSet_ID,
    a.PrivilegeSetReference.name AS PrivilegeSet_Name,
    fn.File_Name as File_Name
FROM account_healed
CROSS JOIN filename_normalized fn
ON CONFLICT (Account_UUID, File_Name) DO UPDATE SET
    Account_ID = EXCLUDED.Account_ID,
    Account_Kind = EXCLUDED.Account_Kind,
    Account_Type = EXCLUDED.Account_Type,
    Is_Enabled = EXCLUDED.Is_Enabled,
    Description = EXCLUDED.Description,
    Account_Name = EXCLUDED.Account_Name,
    Password_Encrypted = EXCLUDED.Password_Encrypted,
    PrivilegeSet_ID = EXCLUDED.PrivilegeSet_ID,
    PrivilegeSet_Name = EXCLUDED.PrivilegeSet_Name;

-- Zensus (Dup-Absorption): Quell-Rowset = ein Record je Account (UNNEST) mit
-- demselben id-Filter wie der Katalog-INSERT; minimaler Re-Read (nur Account-id).
INSERT INTO DuplicateAbsorptions
SELECT getvariable('fm_file'), 'AccountsCatalog', 'Account_UUID,File_Name',
       COALESCE(getvariable('seq_offset'), 0)::BIGINT, COUNT(*)
FROM read_xml(
    getvariable('fm_xml'),
    root_element='AccountsCatalog',
    record_element='ObjectList',
    max_depth=10,
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={'Account': 'STRUCT(id BIGINT)[]'}
)
CROSS JOIN UNNEST(Account) AS t(a)
WHERE a.id IS NOT NULL
ON CONFLICT (Catalog, File_Name, Chunk_Seq) DO UPDATE SET Source_Records = EXCLUDED.Source_Records;

-- Dup-Absorption-DETAILS (AccountsCatalog): Name der kollidierenden Konten je
-- doppelt vergebener UUID. Liest denselben Quell-Rowset wie der Katalog-INSERT
-- oben (UNNEST + identischer id-Filter). DELETE-vor-INSERT hält den Detail-Satz
-- je (Katalog, Datei) beim Re-Import frisch (analog zum per-Datei-Overwrite des
-- Zensus). Bit-identisch zum Katalog-INSERT (rein additiv, eigene Tabelle).
DELETE FROM DuplicateAbsorptionDetails
WHERE Catalog = 'AccountsCatalog'
  AND File_Name = getvariable('fm_file')
  AND Chunk_Seq = COALESCE(getvariable('seq_offset'), 0)::BIGINT;

INSERT INTO DuplicateAbsorptionDetails
    (File_Name, Catalog, Object_UUID, Object_Name, Object_Type, Occurrence_Seq, Chunk_Seq,
     Parent_Name, Position, Display_Text, Payload_XML, Healed_UUID, Heal_Status, Discriminator)
WITH src AS (
    SELECT
        a.id AS id,
        a.UUID."#text" AS Object_UUID,
        xml_unescape(a.Authentication.AccountName) AS Object_Name,
        'Account' AS Object_Type,
        ROW_NUMBER() OVER () AS xml_ord
    FROM read_xml(
        getvariable('fm_xml'),
        root_element='AccountsCatalog',
        record_element='ObjectList',
        max_depth=10,
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={
            'Account': 'STRUCT(
                id BIGINT,
                "UUID" STRUCT("#text" VARCHAR),
                "Authentication" STRUCT("AccountName" VARCHAR)
            )[]'
        }
    )
    CROSS JOIN UNNEST(Account) AS t(a)
    WHERE a.id IS NOT NULL
),
dups AS (
    SELECT Object_UUID FROM src
    WHERE Object_UUID IS NOT NULL
    GROUP BY Object_UUID HAVING COUNT(*) > 1
),
-- UUID-Healing (H1): Survivor-/Heal-Markierung, identische Logik wie im Katalog-INSERT
-- oben (Survivor = kleinste ID; Doppel-Serialisierung — gleiche UUID+ID — bleibt
-- 'absorbed', nur das jeweils erste Vorkommen einer (UUID, ID)-Identität trägt den
-- Katalog-Status). Der Zensus ist damit das persistierte Mapping Original↔Ersatz.
marked AS (
    SELECT s.*,
           (s.id IS NULL  -- NULL-id: kein Diskriminator → wie Survivor behandeln (nie 'healed')
            OR s.id = MIN(s.id) OVER (PARTITION BY s.Object_UUID)) AS is_min_id,
           ROW_NUMBER() OVER (PARTITION BY s.Object_UUID, s.id ORDER BY s.xml_ord) AS occ_within_id
    FROM src s
    JOIN dups d USING (Object_UUID)
)
SELECT
    getvariable('fm_file') AS File_Name,
    'AccountsCatalog' AS Catalog,
    s.Object_UUID,
    s.Object_Name,
    s.Object_Type,
    ROW_NUMBER() OVER (PARTITION BY s.Object_UUID ORDER BY s.xml_ord) AS Occurrence_Seq,
    COALESCE(getvariable('seq_offset'), 0)::BIGINT AS Chunk_Seq,
    -- Kontext: Konten sind Top-Level → kein Container; Position = Stelle in der
    -- "Sicherheit verwalten"-Kontenliste (XML-Reihenfolge, 1-basiert).
    NULL AS Parent_Name,
    'List position ' || s.xml_ord::VARCHAR AS Position,
    left(s.Object_Name, 500) AS Display_Text,
    NULL AS Payload_XML,
    CASE WHEN fm_heal_enabled() AND NOT s.is_min_id AND s.occ_within_id = 1
         THEN fm_heal_uuid('AccountsCatalog', getvariable('fm_file'), s.Object_UUID,
                           'account_id=' || s.id::VARCHAR) END AS Healed_UUID,
    CASE WHEN NOT fm_heal_enabled() THEN 'absorbed'
         WHEN s.occ_within_id > 1   THEN 'absorbed'
         WHEN s.is_min_id           THEN 'kept-original'
         ELSE 'healed' END AS Heal_Status,
    'account_id=' || s.id::VARCHAR AS Discriminator
FROM marked s
ON CONFLICT (Catalog, File_Name, Object_UUID, Occurrence_Seq, Chunk_Seq) DO NOTHING;


-- PrivilegeSetsCatalog
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS PrivilegeSetsCatalog (
    PrivilegeSet_ID BIGINT,
    PrivilegeSet_Name VARCHAR,
    PrivilegeSet_UUID VARCHAR,
    Description VARCHAR,
    Is_Default_Access BOOLEAN,
    Records_Create BOOLEAN,
    Records_Edit BOOLEAN,
    Records_Delete BOOLEAN,
    Records_View VARCHAR,
    Layouts_Create BOOLEAN,
    Layouts_Edit BOOLEAN,
    Layouts_Delete BOOLEAN,
    Layouts_View VARCHAR,
    Layouts_Custom BOOLEAN,
    ValueLists_Create BOOLEAN,
    ValueLists_Edit BOOLEAN,
    ValueLists_Delete BOOLEAN,
    ValueLists_View VARCHAR,
    Scripts_Create BOOLEAN,
    Scripts_Edit BOOLEAN,
    Scripts_Delete BOOLEAN,
    Scripts_View VARCHAR,
    Other_Value BIGINT,
    Allow_Print BOOLEAN,
    Allow_Export BOOLEAN,
    Manage_Database BOOLEAN,
    Manage_Custom_Menus BOOLEAN,
    Manage_Accounts BOOLEAN,
    Manage_Ext_Privs BOOLEAN,
    Allow_Override BOOLEAN,
    Allow_Open_Quickly BOOLEAN,
    Disconnect_Idle BOOLEAN,
    Commands VARCHAR,
    Password_Prohibit_Modification BOOLEAN,
    File_Name VARCHAR,
    PRIMARY KEY (PrivilegeSet_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
privilege_sets AS (
    SELECT
        unnest(xml_extract_elements(xml, '//PrivilegeSetsCatalog/ObjectList/PrivilegeSet')) as ps_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO PrivilegeSetsCatalog
SELECT
    xml_extract_text(ps_xml, '/PrivilegeSet/@id')[1]::BIGINT as PrivilegeSet_ID,
    xml_extract_text(ps_xml, '/PrivilegeSet/@name')[1] as PrivilegeSet_Name,
    xml_extract_text(ps_xml, '/PrivilegeSet/UUID')[1] as PrivilegeSet_UUID,
    ws_restore(xml_extract_text(ps_xml, '/PrivilegeSet/Description')[1]) as Description,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/@default')[1] = 'True' as Is_Default_Access,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Records/@Create')[1] = 'True' as Records_Create,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Records/@Edit')[1] = 'True' as Records_Edit,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Records/@Delete')[1] = 'True' as Records_Delete,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Records/@View')[1] as Records_View,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Layouts/@Create')[1] = 'True' as Layouts_Create,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Layouts/@Edit')[1] = 'True' as Layouts_Edit,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Layouts/@Delete')[1] = 'True' as Layouts_Delete,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Layouts/@View')[1] as Layouts_View,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Layouts/@Custom')[1] = 'True' as Layouts_Custom,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/ValueLists/@Create')[1] = 'True' as ValueLists_Create,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/ValueLists/@Edit')[1] = 'True' as ValueLists_Edit,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/ValueLists/@Delete')[1] = 'True' as ValueLists_Delete,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/ValueLists/@View')[1] as ValueLists_View,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Scripts/@Create')[1] = 'True' as Scripts_Create,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Scripts/@Edit')[1] = 'True' as Scripts_Edit,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Scripts/@Delete')[1] = 'True' as Scripts_Delete,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Scripts/@View')[1] as Scripts_View,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@value')[1]::BIGINT as Other_Value,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@Print')[1] = 'True' as Allow_Print,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@Export')[1] = 'True' as Allow_Export,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@manageDatabase')[1] = 'True' as Manage_Database,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@manageCustomMenus')[1] = 'True' as Manage_Custom_Menus,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@manageAccounts')[1] = 'True' as Manage_Accounts,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@manageExtPrivs')[1] = 'True' as Manage_Ext_Privs,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@allowOverride')[1] = 'True' as Allow_Override,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@allowOpenQuickly')[1] = 'True' as Allow_Open_Quickly,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@disconnectIdle')[1] = 'True' as Disconnect_Idle,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/@commands')[1] as Commands,
    xml_extract_text(ps_xml, '/PrivilegeSet/access/Other/Password/@prohibitModification')[1] = 'True' as Password_Prohibit_Modification,
    fn.File_Name as File_Name
FROM privilege_sets
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(ps_xml, '/PrivilegeSet/@id')[1] IS NOT NULL
ON CONFLICT (PrivilegeSet_UUID, File_Name) DO UPDATE SET
    PrivilegeSet_ID = EXCLUDED.PrivilegeSet_ID,
    PrivilegeSet_Name = EXCLUDED.PrivilegeSet_Name,
    Description = EXCLUDED.Description,
    Is_Default_Access = EXCLUDED.Is_Default_Access,
    Records_Create = EXCLUDED.Records_Create,
    Records_Edit = EXCLUDED.Records_Edit,
    Records_Delete = EXCLUDED.Records_Delete,
    Records_View = EXCLUDED.Records_View,
    Layouts_Create = EXCLUDED.Layouts_Create,
    Layouts_Edit = EXCLUDED.Layouts_Edit,
    Layouts_Delete = EXCLUDED.Layouts_Delete,
    Layouts_View = EXCLUDED.Layouts_View,
    Layouts_Custom = EXCLUDED.Layouts_Custom,
    ValueLists_Create = EXCLUDED.ValueLists_Create,
    ValueLists_Edit = EXCLUDED.ValueLists_Edit,
    ValueLists_Delete = EXCLUDED.ValueLists_Delete,
    ValueLists_View = EXCLUDED.ValueLists_View,
    Scripts_Create = EXCLUDED.Scripts_Create,
    Scripts_Edit = EXCLUDED.Scripts_Edit,
    Scripts_Delete = EXCLUDED.Scripts_Delete,
    Scripts_View = EXCLUDED.Scripts_View,
    Other_Value = EXCLUDED.Other_Value,
    Allow_Print = EXCLUDED.Allow_Print,
    Allow_Export = EXCLUDED.Allow_Export,
    Manage_Database = EXCLUDED.Manage_Database,
    Manage_Custom_Menus = EXCLUDED.Manage_Custom_Menus,
    Manage_Accounts = EXCLUDED.Manage_Accounts,
    Manage_Ext_Privs = EXCLUDED.Manage_Ext_Privs,
    Allow_Override = EXCLUDED.Allow_Override,
    Allow_Open_Quickly = EXCLUDED.Allow_Open_Quickly,
    Disconnect_Idle = EXCLUDED.Disconnect_Idle,
    Commands = EXCLUDED.Commands,
    Password_Prohibit_Modification = EXCLUDED.Password_Prohibit_Modification;


-- ========================================
-- PrivilegeSetRecordAccess (Custom Record Privileges, Tabellen-Ebene)
--
-- Custom Record Privileges, Stufe 1: Bei <Records Custom="True"> liegt
-- der Detailbaum unter Records/Custom/ObjectList/Table und wurde von
-- PrivilegeSetsCatalog (nur Attribut-Lesung am <Records>-Element) bisher
-- ignoriert. Diese Tabelle parst den Custom-Subtree auf Tabellen-Ebene:
-- eine Zeile je Privilege Set × Tabelle × Operation (View/Edit/Create/Delete).
--
-- <Table type="New"> ist die Default-Regel für künftige, noch nicht existierende
-- Tabellen (BaseTable_* = NULL, Table_Type = 'New'). Access_Mode bleibt VARCHAR
-- (keine Enum), damit unbekannte @access-Modi nicht verloren gehen.
-- ========================================
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS PrivilegeSetRecordAccess (
    PrivilegeSet_ID BIGINT,
    PrivilegeSet_Name VARCHAR,
    PrivilegeSet_UUID VARCHAR,
    BaseTable_ID BIGINT,
    BaseTable_Name VARCHAR,
    BaseTable_UUID VARCHAR,
    Table_Type VARCHAR,        -- 'existing' | 'New' (Default-Regel für künftige Tabellen)
    Operation VARCHAR,         -- 'View' | 'Edit' | 'Create' | 'Delete'
    Access_Mode VARCHAR,       -- NoAccess | ReadOnly | ReadWrite | Calculation | Custom | … (VARCHAR, keine Enum)
    Calculation_Text VARCHAR,  -- Klartext-Formel (CDATA) bei @access="Calculation", normalisiert
    DDR_Hash VARCHAR,          -- Calculation/DDRREF/@hash → JOIN mit DDR_Calculations.Calc_Hash
    Context_TO_Name VARCHAR,   -- Auswertungskontext (Calculation/TableOccurrenceReference)
    Context_TO_UUID VARCHAR,
    Fields_Access VARCHAR,     -- <Fields>@access der Tabelle (ein Wert je Tabelle)
    File_Name VARCHAR
);

-- Idempotenz: bestehende Einträge der aktuellen Datei entfernen (1:N, kein PK).
-- BaseTable_UUID ist bei type="New" NULL, daher DELETE-by-File statt ON CONFLICT.
-- Chunk-Guard (I2): nur löschen, wenn der aktuelle
-- XML-Input (= Chunk) den PrivilegeSetsCatalog-Branch enthält. Ohne Guard würde ein
-- Chunk OHNE diesen Branch die von einem anderen Chunk derselben Datei eingefügten
-- Zeilen löschen (DELETE-then-INSERT, kein UPSERT). Nicht-gesplittet: Branch immer
-- präsent → Verhalten unverändert.
-- @P1_SECTION:main@
DELETE FROM PrivilegeSetRecordAccess WHERE File_Name IN (
    SELECT regexp_replace(
        xml_extract_text(xml, '/FMSaveAsXML/@File')[1], '\.fmp12$', ''
    ) FROM read_xml_objects(getvariable('fm_xml'),
        maximum_file_size=getvariable('max_filesize'))
    WHERE len(xml_extract_elements(xml, '//PrivilegeSetsCatalog')) > 0
);

WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
privilege_sets AS (
    SELECT
        unnest(xml_extract_elements(xml, '//PrivilegeSetsCatalog/ObjectList/PrivilegeSet')) as ps_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
-- Zweistufiges unnest (analog StepsForScripts): Privilege-Set-Subtree →
-- Records/Custom/ObjectList/Table. Nur Sets mit Custom Record Privileges
-- besitzen diesen Subtree; einfache <Records …>-Attribut-Sets liefern keine Zeilen.
ps_tables AS (
    SELECT
        xml_extract_text(ps_xml, '/PrivilegeSet/@id')[1]::BIGINT as PrivilegeSet_ID,
        xml_extract_text(ps_xml, '/PrivilegeSet/@name')[1] as PrivilegeSet_Name,
        xml_extract_text(ps_xml, '/PrivilegeSet/UUID')[1] as PrivilegeSet_UUID,
        unnest(xml_extract_elements(ps_xml, '/PrivilegeSet/access/Records/Custom/ObjectList/Table')) as table_xml
    FROM privilege_sets
),
ps_table_info AS (
    SELECT
        PrivilegeSet_ID,
        PrivilegeSet_Name,
        PrivilegeSet_UUID,
        xml_extract_text(table_xml, '/Table/BaseTableReference/@id')[1]::BIGINT as BaseTable_ID,
        xml_extract_text(table_xml, '/Table/BaseTableReference/@name')[1] as BaseTable_Name,
        xml_extract_text(table_xml, '/Table/BaseTableReference/@UUID')[1] as BaseTable_UUID,
        xml_extract_text(table_xml, '/Table/@type')[1] as Table_Type,
        xml_extract_text(table_xml, '/Table/Fields/@access')[1] as Fields_Access,
        table_xml
    FROM ps_tables
),
-- Die vier Operationen je Table-Zeile flachklopfen. Jeder Operation entspricht
-- ein gleichnamiger Kindknoten (<View>/<Edit>/<Create>/<Delete>) mit @access und
-- optionalem <Calculation>-Block (TableOccurrenceReference + DDRREF + Text-CDATA).
ps_record_access AS (
    SELECT * FROM (
        SELECT
            ti.*,
            'View' as Operation,
            xml_extract_text(table_xml, '/Table/View/@access')[1] as Access_Mode,
            xml_extract_text(table_xml, '/Table/View/Calculation/Text')[1] as Calc_Text_Raw,
            xml_extract_text(table_xml, '/Table/View/Calculation/DDRREF/@hash')[1] as DDR_Hash,
            xml_extract_text(table_xml, '/Table/View/Calculation/TableOccurrenceReference/@name')[1] as Context_TO_Name,
            xml_extract_text(table_xml, '/Table/View/Calculation/TableOccurrenceReference/@UUID')[1] as Context_TO_UUID
        FROM ps_table_info ti
        UNION ALL
        SELECT
            ti.*,
            'Edit' as Operation,
            xml_extract_text(table_xml, '/Table/Edit/@access')[1],
            xml_extract_text(table_xml, '/Table/Edit/Calculation/Text')[1],
            xml_extract_text(table_xml, '/Table/Edit/Calculation/DDRREF/@hash')[1],
            xml_extract_text(table_xml, '/Table/Edit/Calculation/TableOccurrenceReference/@name')[1],
            xml_extract_text(table_xml, '/Table/Edit/Calculation/TableOccurrenceReference/@UUID')[1]
        FROM ps_table_info ti
        UNION ALL
        SELECT
            ti.*,
            'Create' as Operation,
            xml_extract_text(table_xml, '/Table/Create/@access')[1],
            xml_extract_text(table_xml, '/Table/Create/Calculation/Text')[1],
            xml_extract_text(table_xml, '/Table/Create/Calculation/DDRREF/@hash')[1],
            xml_extract_text(table_xml, '/Table/Create/Calculation/TableOccurrenceReference/@name')[1],
            xml_extract_text(table_xml, '/Table/Create/Calculation/TableOccurrenceReference/@UUID')[1]
        FROM ps_table_info ti
        UNION ALL
        SELECT
            ti.*,
            'Delete' as Operation,
            xml_extract_text(table_xml, '/Table/Delete/@access')[1],
            xml_extract_text(table_xml, '/Table/Delete/Calculation/Text')[1],
            xml_extract_text(table_xml, '/Table/Delete/Calculation/DDRREF/@hash')[1],
            xml_extract_text(table_xml, '/Table/Delete/Calculation/TableOccurrenceReference/@name')[1],
            xml_extract_text(table_xml, '/Table/Delete/Calculation/TableOccurrenceReference/@UUID')[1]
        FROM ps_table_info ti
    )
)
INSERT INTO PrivilegeSetRecordAccess
SELECT
    ra.PrivilegeSet_ID,
    ra.PrivilegeSet_Name,
    ra.PrivilegeSet_UUID,
    ra.BaseTable_ID,
    ra.BaseTable_Name,
    ra.BaseTable_UUID,
    ra.Table_Type,
    ra.Operation,
    ra.Access_Mode,
    -- chr(127) -> chr(10): Preprocessing-Sentinel für CR zurück zu LF
    ws_restore(ra.Calc_Text_Raw) as Calculation_Text,
    ra.DDR_Hash,
    ra.Context_TO_Name,
    ra.Context_TO_UUID,
    ra.Fields_Access,
    fn.File_Name
FROM ps_record_access ra
CROSS JOIN filename_normalized fn
WHERE ra.PrivilegeSet_UUID IS NOT NULL;


-- ========================================
-- PrivilegeSetFieldAccess (Custom Record Privileges, Feld-Ebene)
--
-- Custom Record Privileges, Stufe 2: Trägt eine Tabelle im Custom-Subtree
-- <Fields access="Custom">, öffnet sich darunter ein feld-granularer Detailbaum
-- aus <Field>-Einträgen mit eigenem @access. Eine Zeile je Privilege Set ×
-- Tabelle × Feld. Nur Tabellen mit Fields_Access='Custom' liefern Zeilen;
-- alle anderen tragen ihren einzelnen Fields-@access bereits in
-- PrivilegeSetRecordAccess.Fields_Access.
--
-- Graph-Integration: scoped restricts_field-Link in create_universal_catalogs.sql
-- (Block 35) — NUR Restriktionen (Access_Mode <> 'ReadWrite'), eigener Link_Role
-- statt reads_field. Voll-offene Felder (ReadWrite) erzeugen bewusst keine Links
-- (kein Signal). Die Where-Used-Lücke schließt weiterhin allein Stufe 1 (Calc-Refs);
-- restricts_field ist eine Einschränkung, keine Nutzung.
-- ========================================
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS PrivilegeSetFieldAccess (
    PrivilegeSet_ID BIGINT,
    PrivilegeSet_Name VARCHAR,
    PrivilegeSet_UUID VARCHAR,
    BaseTable_ID BIGINT,
    BaseTable_Name VARCHAR,
    BaseTable_UUID VARCHAR,
    Field_ID BIGINT,
    Field_Name VARCHAR,
    Field_UUID VARCHAR,
    Field_Type VARCHAR,        -- 'existing' | 'New' (Default-Regel für künftige Felder)
    Access_Mode VARCHAR,       -- NoAccess | ReadOnly | ReadWrite | … (VARCHAR, keine Enum)
    File_Name VARCHAR
);

-- Idempotenz: bestehende Einträge der aktuellen Datei entfernen (1:N, kein PK).
-- Chunk-Guard (I2): nur löschen, wenn der Chunk PrivilegeSetsCatalog enthält.
-- @P1_SECTION:main@
DELETE FROM PrivilegeSetFieldAccess WHERE File_Name IN (
    SELECT regexp_replace(
        xml_extract_text(xml, '/FMSaveAsXML/@File')[1], '\.fmp12$', ''
    ) FROM read_xml_objects(getvariable('fm_xml'),
        maximum_file_size=getvariable('max_filesize'))
    WHERE len(xml_extract_elements(xml, '//PrivilegeSetsCatalog')) > 0
);

WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
privilege_sets AS (
    SELECT
        unnest(xml_extract_elements(xml, '//PrivilegeSetsCatalog/ObjectList/PrivilegeSet')) as ps_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
-- Dreistufiges unnest: Privilege-Set → Table → Field. Nur Tabellen mit
-- <Fields access="Custom"> besitzen <Field>-Kinder; alle anderen liefern
-- eine leere Liste und fallen damit automatisch aus dem Ergebnis.
ps_tables AS (
    SELECT
        xml_extract_text(ps_xml, '/PrivilegeSet/@id')[1]::BIGINT as PrivilegeSet_ID,
        xml_extract_text(ps_xml, '/PrivilegeSet/@name')[1] as PrivilegeSet_Name,
        xml_extract_text(ps_xml, '/PrivilegeSet/UUID')[1] as PrivilegeSet_UUID,
        unnest(xml_extract_elements(ps_xml, '/PrivilegeSet/access/Records/Custom/ObjectList/Table')) as table_xml
    FROM privilege_sets
),
ps_table_fields AS (
    SELECT
        PrivilegeSet_ID,
        PrivilegeSet_Name,
        PrivilegeSet_UUID,
        xml_extract_text(table_xml, '/Table/BaseTableReference/@id')[1]::BIGINT as BaseTable_ID,
        xml_extract_text(table_xml, '/Table/BaseTableReference/@name')[1] as BaseTable_Name,
        xml_extract_text(table_xml, '/Table/BaseTableReference/@UUID')[1] as BaseTable_UUID,
        unnest(xml_extract_elements(table_xml, '/Table/Fields/Field')) as field_xml
    FROM ps_tables
)
INSERT INTO PrivilegeSetFieldAccess
SELECT
    f.PrivilegeSet_ID,
    f.PrivilegeSet_Name,
    f.PrivilegeSet_UUID,
    f.BaseTable_ID,
    f.BaseTable_Name,
    f.BaseTable_UUID,
    xml_extract_text(field_xml, '/Field/FieldReference/@id')[1]::BIGINT as Field_ID,
    xml_extract_text(field_xml, '/Field/FieldReference/@name')[1] as Field_Name,
    xml_extract_text(field_xml, '/Field/FieldReference/@UUID')[1] as Field_UUID,
    xml_extract_text(field_xml, '/Field/@type')[1] as Field_Type,
    xml_extract_text(field_xml, '/Field/@access')[1] as Access_Mode,
    fn.File_Name
FROM ps_table_fields f
CROSS JOIN filename_normalized fn
WHERE f.PrivilegeSet_UUID IS NOT NULL;


-- ========================================
-- PrivilegeSetObjectAccess (Custom Privileges für Layouts/ValueLists/Scripts)
--
-- Custom Privileges, Stufe 3: Dieselbe Custom="True"-Mechanik wie bei den
-- Record-Privilegien existiert für weitere Objektklassen. Bei
-- <Layouts|ValueLists|Scripts Custom="True"> listet <Custom>/ObjectList jedes
-- Objekt der Klasse mit eigenem @access. Eine Zeile je Privilege Set × Objekt.
--
-- Unified-Tabelle mit Object_Class-Diskriminator (statt drei fast identischer
-- Tabellen). Klassen ohne Custom-Subtree (einfache Attribut-Form wie
-- <ValueLists Create="True" …>) liefern keine Zeilen.
--
-- Records_Access ist nur bei Layouts belegt (Layout trägt zusätzlich zum
-- Layout-@access ein @records für den Datensatz-Zugriff auf dem Layout).
-- Class_Allow_Create spiegelt das <Custom Create="…">-Attribut der Klasse
-- (gilt für die ganze Klasse, der Bequemlichkeit halber je Zeile wiederholt).
--
-- Graph-Integration: scoped restricts_object-Link in create_universal_catalogs.sql
-- (Block 36) — analog zur Feld-Ebene NUR Restriktionen (Access_Mode <> 'ReadWrite');
-- voll-offene Objekte erzeugen keine Links (kein Signal bei hohem Volumen).
-- ========================================
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS PrivilegeSetObjectAccess (
    PrivilegeSet_ID BIGINT,
    PrivilegeSet_Name VARCHAR,
    PrivilegeSet_UUID VARCHAR,
    Object_Class VARCHAR,      -- 'Layout' | 'ValueList' | 'Script'
    Object_ID BIGINT,
    Object_Name VARCHAR,
    Object_UUID VARCHAR,
    Item_Type VARCHAR,         -- 'existing' | 'New' (Default-Regel für künftige Objekte)
    Access_Mode VARCHAR,       -- NoAccess | ReadOnly | ReadWrite | … (VARCHAR, keine Enum)
    Records_Access VARCHAR,    -- nur Layouts: @records (Datensatz-Zugriff auf dem Layout)
    Class_Allow_Create BOOLEAN, -- <Custom Create="…"> der Klasse (darf neue Objekte angelegt werden?)
    File_Name VARCHAR
);

-- Idempotenz: bestehende Einträge der aktuellen Datei entfernen (1:N, kein PK).
-- Chunk-Guard (I2): nur löschen, wenn der Chunk PrivilegeSetsCatalog enthält.
-- @P1_SECTION:main@
DELETE FROM PrivilegeSetObjectAccess WHERE File_Name IN (
    SELECT regexp_replace(
        xml_extract_text(xml, '/FMSaveAsXML/@File')[1], '\.fmp12$', ''
    ) FROM read_xml_objects(getvariable('fm_xml'),
        maximum_file_size=getvariable('max_filesize'))
    WHERE len(xml_extract_elements(xml, '//PrivilegeSetsCatalog')) > 0
);

WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
privilege_sets AS (
    SELECT
        unnest(xml_extract_elements(xml, '//PrivilegeSetsCatalog/ObjectList/PrivilegeSet')) as ps_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
ps_base AS (
    SELECT
        xml_extract_text(ps_xml, '/PrivilegeSet/@id')[1]::BIGINT as PrivilegeSet_ID,
        xml_extract_text(ps_xml, '/PrivilegeSet/@name')[1] as PrivilegeSet_Name,
        xml_extract_text(ps_xml, '/PrivilegeSet/UUID')[1] as PrivilegeSet_UUID,
        ps_xml
    FROM privilege_sets
),
-- Pro Objektklasse ein eigenes unnest (Item- und Reference-Elementnamen
-- unterscheiden sich je Klasse), anschließend per UNION ALL vereint.
layout_items AS (
    SELECT
        PrivilegeSet_ID, PrivilegeSet_Name, PrivilegeSet_UUID,
        'Layout' as Object_Class,
        xml_extract_text(ps_xml, '/PrivilegeSet/access/Layouts/Custom/@Create')[1] = 'True' as Class_Allow_Create,
        unnest(xml_extract_elements(ps_xml, '/PrivilegeSet/access/Layouts/Custom/ObjectList/Layout')) as item_xml
    FROM ps_base
),
valuelist_items AS (
    SELECT
        PrivilegeSet_ID, PrivilegeSet_Name, PrivilegeSet_UUID,
        'ValueList' as Object_Class,
        xml_extract_text(ps_xml, '/PrivilegeSet/access/ValueLists/Custom/@Create')[1] = 'True' as Class_Allow_Create,
        unnest(xml_extract_elements(ps_xml, '/PrivilegeSet/access/ValueLists/Custom/ObjectList/ValueList')) as item_xml
    FROM ps_base
),
script_items AS (
    SELECT
        PrivilegeSet_ID, PrivilegeSet_Name, PrivilegeSet_UUID,
        'Script' as Object_Class,
        xml_extract_text(ps_xml, '/PrivilegeSet/access/Scripts/Custom/@Create')[1] = 'True' as Class_Allow_Create,
        unnest(xml_extract_elements(ps_xml, '/PrivilegeSet/access/Scripts/Custom/ObjectList/Script')) as item_xml
    FROM ps_base
)
INSERT INTO PrivilegeSetObjectAccess
SELECT
    i.PrivilegeSet_ID,
    i.PrivilegeSet_Name,
    i.PrivilegeSet_UUID,
    i.Object_Class,
    -- Reference-Element trägt denselben Namen wie die Klasse (Layout→LayoutReference, …)
    xml_extract_text(i.item_xml, '/' || i.Object_Class || '/' || i.Object_Class || 'Reference/@id')[1]::BIGINT as Object_ID,
    xml_extract_text(i.item_xml, '/' || i.Object_Class || '/' || i.Object_Class || 'Reference/@name')[1] as Object_Name,
    xml_extract_text(i.item_xml, '/' || i.Object_Class || '/' || i.Object_Class || 'Reference/@UUID')[1] as Object_UUID,
    xml_extract_text(i.item_xml, '/' || i.Object_Class || '/@type')[1] as Item_Type,
    xml_extract_text(i.item_xml, '/' || i.Object_Class || '/@access')[1] as Access_Mode,
    xml_extract_text(i.item_xml, '/' || i.Object_Class || '/@records')[1] as Records_Access,
    i.Class_Allow_Create,
    fn.File_Name
FROM (
    SELECT * FROM layout_items
    UNION ALL
    SELECT * FROM valuelist_items
    UNION ALL
    SELECT * FROM script_items
) i
CROSS JOIN filename_normalized fn
WHERE i.PrivilegeSet_UUID IS NOT NULL;


-- ========================================
-- DDR_INFO Integration (FileMaker 21+)
--
-- HINWEIS: Diese Tabellen werden immer erstellt, bleiben aber leer,
-- wenn die XML-Datei kein Has_DDR_INFO="True" Attribut hat.
-- Prüfe XMLMetadata.Has_DDR_INFO um zu sehen, ob DDR-Info verfügbar ist.
-- ========================================

-- DDR_ScriptSteps: Lesbare Script-Schritte aus DDR_INFO
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS DDR_ScriptSteps (
    Step_UUID VARCHAR,
    Step_Hash VARCHAR,
    Step_Text VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Step_UUID, File_Name)
);

-- @P1_SECTION:Script,DDR_INFO@
-- @STREAMIFY_BLOCK:ddr_scriptsteps@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
ddr_script_raw AS (
    SELECT
        unnest(xml_extract_elements(xml, '//DDR_INFO/Script/ObjectList/*')) as step_elem
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO DDR_ScriptSteps
SELECT
    -- UUID-lose StepText-Records (button-eingebettete Einzel-Steps: <_ hash="…">, ohne
    -- Element-UUID) fallen auf 'hash:'||Step_Hash zurück. Ohne diesen Fallback kollidieren
    -- ALLE UUID-losen Records auf dem leeren PK (Step_UUID='') und ON CONFLICT behält pro
    -- Datei nur EINEN — die Button-Step-Klartexte gingen so verloren (via DDRREF-Hash
    -- auflösbar für die LayoutObject-Detailansicht).
    COALESCE(
        NULLIF(
            regexp_extract(
                step_elem::VARCHAR,
                '<_([0-9A-Fa-f-]+)',   -- Hex-Klasse case-tolerant wie die P2/P3-Anker ([0-9A-Fa-f-]{36})
                1
            ),
            ''
        ),
        'hash:' || xml_extract_text(step_elem, '//*/@hash')[1]
    ) as Step_UUID,
    xml_extract_text(step_elem, '//*/@hash')[1] as Step_Hash,
    ws_restore(xml_extract_text(step_elem, '//text()')[1]) as Step_Text,
    fn.File_Name as File_Name
FROM ddr_script_raw
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(step_elem, '//*/@datatype')[1] = 'StepText'
ON CONFLICT (Step_UUID, File_Name) DO UPDATE SET
    Step_Hash = EXCLUDED.Step_Hash,
    Step_Text = EXCLUDED.Step_Text;
-- @END_STREAMIFY_BLOCK@


-- DDR_Calculations: Formel-Chunks für Abhängigkeitsanalyse
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS DDR_Calculations (
    Calc_UUID VARCHAR,
    Calc_Hash VARCHAR,
    Chunk_Index BIGINT,
    Chunk_Type VARCHAR,
    Chunk_Content VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Calc_UUID, Chunk_Index, File_Name)
);

-- DDR_ChunkListContexts (Schema 1.27.0): eine Zeile pro ChunkList-Anker des
-- DDR_INFO-Teils — inkl. LEERER ChunkLists (Chunk_Count = 0), die in
-- DDR_Calculations naturgemäß keine Zeile hinterlassen (kein Chunk). Trägt die
-- Kontext-TO des Ankers (direktes TableOccurrenceReference-Kind neben der
-- ChunkList). Konsumenten: P2 A.5.1b/A.5.1c (Feld-Auflösung gegen die
-- Kontext-TO), P4 b_disp + Display-Anreicherung (Kontext-TO, Fallback),
-- P6 v_check_display_empty_chunklist. Der Join auf den Anker läuft IMMER über
-- Calc_UUID (Anker-Name) — nie über Calc_Hash: identische Formeln teilen den
-- Hash, aber jeder Anker trägt seine eigene Kontext-TO.
CREATE TABLE IF NOT EXISTS DDR_ChunkListContexts (
    Calc_UUID VARCHAR,          -- Anker-Name '_<Owner-UUID>_<Slot>' (wie DDR_Calculations)
    Calc_Hash VARCHAR,
    Chunk_Count BIGINT,         -- 0 = leere ChunkList (z. B. %X:-Layoutformel-Defekt)
    Context_TO_ID BIGINT,
    Context_TO_Name VARCHAR,
    Context_TO_UUID VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Calc_UUID, File_Name)
);

-- @P1_SECTION:Calculation,DDR_INFO@
-- @STREAMIFY_BLOCK:ddr_calculations@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
ddr_calc_raw AS (
    SELECT
        unnest(xml_extract_elements(xml, '//DDR_INFO/Calculation/ObjectList/*')) as calc_elem
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
-- Chunk-Index in XML-Dokumentreihenfolge:
-- Zwei parallele unnest()-Aufrufe iterieren synchron pro Zeile. Die Chunk-Liste
-- und ein begleitendes generate_series mit derselben Länge erzeugen einen
-- deterministischen, lesegerechten Chunk_Index. Vorgängerlösung mit
-- ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) war nicht-deterministisch.
calc_with_chunk_lists AS (
    SELECT
        -- Slot-Suffix erhalten: '_<UUID>_<Slot>' (numerisch UND benannt,
        -- formatunabhängig bis zum ersten Whitespace/'>'). Die alte Variante
        -- '<_([0-9A-F-]+)' schnitt den Slot ab → verschiedene Slots derselben
        -- UUID kollidierten im PK (Calc_UUID, Chunk_Index, File_Name) und
        -- überschrieben sich per ON CONFLICT DO UPDATE (~36-41% Definitionsverlust).
        -- Calc_UUID wird nirgends mit Objekt-UUIDs gejoint (alle Objekt-Joins
        -- laufen über Calc_Hash), daher ist die Bedeutungsänderung
        -- "Objekt-UUID" → "Berechnungs-Instanz-ID (UUID+Slot)" unkritisch.
        regexp_extract(
            calc_elem::VARCHAR,
            '<(_[^\s>]+)',
            1
        ) as Calc_UUID,
        xml_extract_text(calc_elem, '//*/@hash')[1] as Calc_Hash,
        xml_extract_elements(calc_elem, '//ChunkList/Chunk') as chunks
    FROM ddr_calc_raw
    WHERE xml_extract_text(calc_elem, '//*/@datatype')[1] = 'ChunkList'
),
calc_with_chunks AS (
    SELECT
        Calc_UUID,
        Calc_Hash,
        unnest(chunks) as chunk_xml,
        unnest(generate_series(1, len(chunks))) as chunk_index
    FROM calc_with_chunk_lists
)
INSERT INTO DDR_Calculations
SELECT
    Calc_UUID,
    Calc_Hash,
    chunk_index as Chunk_Index,
    xml_extract_text(chunk_xml, '/Chunk/@type')[1] as Chunk_Type,
    -- ws_restore: Chunk_Content ist Formel-Text — ohne Restore leakte der
    -- 0x7F-Sentinel bei CR-haltigen Formeln in alle Downstream-Konsumenten
    -- (Variablen-Parser, Menü-Kanten, Referenz-Regexe).
    ws_restore(COALESCE(
        xml_extract_text(chunk_xml, 'text()')[1],
        chunk_xml::VARCHAR
    )) as Chunk_Content,
    fn.File_Name as File_Name
FROM calc_with_chunks
CROSS JOIN filename_normalized fn
ON CONFLICT (Calc_UUID, Chunk_Index, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Type = EXCLUDED.Chunk_Type,
    Chunk_Content = EXCLUDED.Chunk_Content;

-- DDR_ChunkListContexts: zweiter Pass über dieselben ObjectList-Einträge.
-- '/*/TableOccurrenceReference' greift NUR das direkte Kind des Ankers —
-- FieldRef-Chunks nesten eigene TableOccurrenceReferences tiefer (unter
-- ChunkList/Chunk/FieldReference) und bleiben bewusst außen vor.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
ddr_calc_raw AS (
    SELECT
        unnest(xml_extract_elements(xml, '//DDR_INFO/Calculation/ObjectList/*')) as calc_elem
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
chunk_list_ctx AS (
    SELECT
        regexp_extract(calc_elem::VARCHAR, '<(_[^\s>]+)', 1) as Calc_UUID,
        xml_extract_text(calc_elem, '//*/@hash')[1] as Calc_Hash,
        len(xml_extract_elements(calc_elem, '//ChunkList/Chunk')) as Chunk_Count,
        TRY_CAST(NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@id')[1], '') AS BIGINT) as Context_TO_ID,
        NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@name')[1], '') as Context_TO_Name,
        NULLIF(xml_extract_text(calc_elem, '/*/TableOccurrenceReference/@UUID')[1], '') as Context_TO_UUID
    FROM ddr_calc_raw
    WHERE xml_extract_text(calc_elem, '//*/@datatype')[1] = 'ChunkList'
)
INSERT INTO DDR_ChunkListContexts
SELECT
    c.Calc_UUID,
    c.Calc_Hash,
    c.Chunk_Count,
    c.Context_TO_ID,
    c.Context_TO_Name,
    c.Context_TO_UUID,
    fn.File_Name
FROM chunk_list_ctx c
CROSS JOIN filename_normalized fn
WHERE c.Calc_UUID IS NOT NULL AND c.Calc_UUID <> ''
ON CONFLICT (Calc_UUID, File_Name) DO UPDATE SET
    Calc_Hash = EXCLUDED.Calc_Hash,
    Chunk_Count = EXCLUDED.Chunk_Count,
    Context_TO_ID = EXCLUDED.Context_TO_ID,
    Context_TO_Name = EXCLUDED.Context_TO_Name,
    Context_TO_UUID = EXCLUDED.Context_TO_UUID;
-- @END_STREAMIFY_BLOCK@




-- ============================================
-- PHASE 4: OPTIONALE KATALOGE
-- ============================================


-- ============================================
-- 20. PasteIndexList
-- ============================================
-- Sehr einfach: Liste von Object-IDs
-- Wird verwendet für Copy/Paste Operations
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS PasteIndexList (
    Object_ID BIGINT,
    List_Index BIGINT,
    File_Name VARCHAR,
    PRIMARY KEY (Object_ID, File_Name)
);

-- @P1_SECTION:main@
-- @STREAMIFY_BLOCK:pasteindexlist@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
paste_objects AS (
    SELECT
        unnest(xml_extract_elements(xml, '//PasteIndexList/Object')) as object_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO PasteIndexList
SELECT
    xml_extract_text(object_xml, '/Object/@id')[1]::BIGINT as Object_ID,
    ROW_NUMBER() OVER (ORDER BY Object_ID) as List_Index,
    fn.File_Name as File_Name
FROM paste_objects
CROSS JOIN filename_normalized fn
WHERE Object_ID IS NOT NULL
ON CONFLICT (Object_ID, File_Name) DO UPDATE SET
    List_Index = EXCLUDED.List_Index;
-- @END_STREAMIFY_BLOCK@


-- ============================================
-- 21. BaseDirectoryCatalog
-- ============================================
-- Basis-Directory der FileMaker-Datei
-- Pattern: XPath für nested Element
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS BaseDirectoryCatalog (
    BD_Name VARCHAR,
    BD_ID BIGINT,
    BD_RelativeTo VARCHAR,
    BD_UUID VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (BD_UUID, File_Name)
);

-- @P1_SECTION:main@
-- @STREAMIFY_BLOCK:basedirectorycatalog@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_dir AS (
    SELECT
        unnest(xml_extract_elements(xml, '//BaseDirectoryCatalog/BaseDirectory')) as dir_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO BaseDirectoryCatalog
SELECT
    xml_extract_text(dir_xml, '/BaseDirectory/@name')[1] as BD_Name,
    xml_extract_text(dir_xml, '/BaseDirectory/@id')[1]::BIGINT as BD_ID,
    xml_extract_text(dir_xml, '/BaseDirectory/@relativeTo')[1] as BD_RelativeTo,
    xml_extract_text(dir_xml, '/BaseDirectory/UUID/text()')[1] as BD_UUID,
    fn.File_Name as File_Name
FROM raw_dir
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(dir_xml, '/BaseDirectory/@id')[1] IS NOT NULL
ON CONFLICT (BD_UUID, File_Name) DO UPDATE SET
    BD_Name = EXCLUDED.BD_Name,
    BD_ID = EXCLUDED.BD_ID,
    BD_RelativeTo = EXCLUDED.BD_RelativeTo;
-- @END_STREAMIFY_BLOCK@


-- ============================================
-- 22. ScriptTriggers
-- ============================================
-- Script Trigger (OnFirstWindowOpen, OnLastWindowClose, etc.)
-- Pattern: XPath für nested Element in Metadata
-- Owner-Kontext (Owner_UUID, Owner_Type) ist Teil der Trigger-Identität:
-- Trigger_ID ist bei Object-Level-Triggern nur ein Slot innerhalb des Owner-
-- Kontexts (kein globaler Identifier). Mit dem alten PK (Trigger_ID, File_Name)
-- kollabierte ON CONFLICT DO UPDATE beliebig viele Trigger-Instanzen auf eine
-- Row ("letzter gewinnt", ~96% Verlust). Der Trigger wird erst durch
-- (Trigger_ID, Owner_UUID, File_Name) eindeutig.
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS ScriptTriggers (
    Trigger_ID BIGINT,
    Trigger_Action VARCHAR,
    Trigger_BrowseMode VARCHAR,
    Script_ID BIGINT,
    Script_Name VARCHAR,
    Script_UUID VARCHAR,
    Owner_UUID VARCHAR,
    Owner_Type VARCHAR,
    File_Name VARCHAR,
    -- Roh-Fragment des Triggers (Schema 1.22.0) — NUR für Owner-Typen
    -- 'Layout'/'File' belegt: deren Parameter-Berechnungen (DDRREF-Hashes)
    -- liegen in KEINEM anderen persistierten Blob (Object-Level-Trigger
    -- stecken bereits in LayoutObjects.Object_XML). P2/A.12 erntet daraus
    -- die Trigger-Parameter-Referenzen. Inhalt kann zwischen DOM- und
    -- SAX-Pfad in Serialisierungs-Details divergieren (CDATA/Whitespace) —
    -- die A.12-Regex-Ernte liest nur Attribute + DDRREF-Text (robust);
    -- NIE als Identitätsquelle verwenden (PK bleibt serialisierungs-frei).
    Trigger_XML VARCHAR,
    -- Modus-Scope (Schema 1.24.0): SaXML schreibt NUR aktivierte Modi als
    -- Attribute — NULL heißt "Modus nicht aktiviert", nie "unbekannt".
    -- VARCHAR-Passthrough ('True'/NULL) analog Trigger_BrowseMode.
    Trigger_FindMode VARCHAR,
    Trigger_PreviewMode VARCHAR,
    -- Nur OnWindowTransaction (Schema 1.24.0): Feldname, dessen Inhalt in den
    -- JSON-Scriptparameter aufgenommen wird. Reine Namens-Referenz (keine
    -- Tabellen-Qualifizierung, keine ID/UUID), von FileMaker zur Laufzeit je
    -- auslösender Tabelle spät gebunden — deshalb hier nur persistiert, ohne
    -- aufgelöste Feld-Kante.
    Trigger_ScriptParameter_FieldName VARCHAR,
    -- Klartext der Parameter-Berechnung (Schema 1.26.0):
    -- /ScriptTrigger/ScriptReference/Calculation/Text, via xml_extract_text
    -- CDATA-/Entity-dekodiert — DOM- und SAX-Capture landen auf demselben Wert.
    -- Reiner Payload (NIE Identitätsquelle, PK bleibt serialisierungs-frei);
    -- P4 speist daraus Formula_Text der script_trigger_parameter-Instanzen
    -- inkl. per-Trigger-No-DDR-Fallback aller drei Owner-Ebenen.
    Trigger_Parameter_Text VARCHAR,
    PRIMARY KEY (Trigger_ID, Owner_UUID, File_Name)
);

-- Additive Migration für Bestands-DBs (Spalte ans Ende, positionsbasierte
-- INSERTs bleiben konsistent — Muster XMLCalcReferences).
ALTER TABLE ScriptTriggers ADD COLUMN IF NOT EXISTS Trigger_XML VARCHAR;
ALTER TABLE ScriptTriggers ADD COLUMN IF NOT EXISTS Trigger_FindMode VARCHAR;
ALTER TABLE ScriptTriggers ADD COLUMN IF NOT EXISTS Trigger_PreviewMode VARCHAR;
ALTER TABLE ScriptTriggers ADD COLUMN IF NOT EXISTS Trigger_ScriptParameter_FieldName VARCHAR;
ALTER TABLE ScriptTriggers ADD COLUMN IF NOT EXISTS Trigger_Parameter_Text VARCHAR;

-- Owner-getrennte Extraktion: das frühere flache '//ScriptTriggers/ScriptTrigger'
-- verwarf den Parent-Kontext. Drei Quellen per UNION ALL, jede trägt Owner_UUID
-- + Owner_Type mit. Die XPaths sind so geschnitten, dass kein Trigger doppelt
-- erfasst wird: Object-Level-Trigger liegen INNERHALB von Layouts, daher greift
-- die Layout-Stufe nur die DIREKTEN Trigger des <Layout> (Pfad /Layout/Script...),
-- nicht die der enthaltenen <LayoutObject>.
-- @P1_SECTION:main,LayoutCatalog@
-- @STREAMIFY_BLOCK:scripttriggers@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
-- File-Level (OnFirstWindowOpen, OnLastWindowClose, …) — eindeutig pro File
file_triggers AS (
    SELECT
        'File' as Owner_Type,
        xml_extract_text(xml, '/FMSaveAsXML/@UUID')[1] as Owner_UUID,
        unnest(xml_extract_elements(xml, '//Metadata/AddAction/ScriptTriggers/ScriptTrigger')) as trigger_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
-- Layout-Level (OnLayoutEnter, OnLayoutKeystroke, …) — nur DIREKTE <Layout>-Trigger
raw_layouts AS (
    SELECT unnest(xml_extract_elements(xml, '//LayoutCatalog/Layout')) as layout_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
layout_triggers AS (
    SELECT
        'Layout' as Owner_Type,
        xml_extract_text(layout_xml, '/Layout/UUID')[1] as Owner_UUID,
        unnest(xml_extract_elements(layout_xml, '/Layout/ScriptTriggers/ScriptTrigger')) as trigger_xml
    FROM raw_layouts
),
-- LayoutObject-Level (OnObjectSave, OnObjectEnter, …) — der kollidierende Fall:
-- viele Objekte teilen dieselbe lokale Trigger_ID. Der direkte Pfad greift nur
-- die eigenen Trigger jedes Objekts; verschachtelte Kinder liefern ihre Trigger
-- über ihre eigene //LayoutObject-Zeile (kein Doppelzählen).
raw_objects AS (
    SELECT unnest(xml_extract_elements(xml, '//LayoutObject')) as obj_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
),
object_triggers AS (
    SELECT
        'LayoutObject' as Owner_Type,
        xml_extract_text(obj_xml, '/LayoutObject/UUID')[1] as Owner_UUID,
        unnest(xml_extract_elements(obj_xml, '/LayoutObject/ScriptTriggers/ScriptTrigger')) as trigger_xml
    FROM raw_objects
),
all_triggers AS (
    SELECT * FROM file_triggers
    UNION ALL SELECT * FROM layout_triggers
    UNION ALL SELECT * FROM object_triggers
)
INSERT INTO ScriptTriggers
SELECT
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@id')[1]::BIGINT as Trigger_ID,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@action')[1] as Trigger_Action,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@browseMode')[1] as Trigger_BrowseMode,

    -- Script-Referenz
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/@id')[1]::BIGINT as Script_ID,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/@name')[1] as Script_Name,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/@UUID')[1] as Script_UUID,

    -- Deterministischer md5-Fallback verhindert eine NULL im PK, falls ein Owner
    -- ausnahmsweise keine UUID trägt (kein ROW_NUMBER, vgl. Slot-Fix oben).
    -- SERIALISIERUNGS-UNABHÄNGIG: hasht
    -- EXTRAHIERTE Identitätsfelder statt der Roh-Serialisierung trigger_xml::VARCHAR.
    -- Sonst divergierte der PK unter SAX-Streaming (CDATA/Entity/Whitespace) und
    -- erzwänge einen DOM-Fallback. Owner-lose Trigger sind ein Edge-Case (in den
    -- Testdaten 0 Zeilen → DOM-Baseline unverändert); der Schlüssel bleibt deterministisch.
    COALESCE(t.Owner_UUID, md5(
        COALESCE(xml_extract_text(t.trigger_xml, '/ScriptTrigger/@id')[1], '') || '|' ||
        COALESCE(xml_extract_text(t.trigger_xml, '/ScriptTrigger/@action')[1], '') || '|' ||
        COALESCE(xml_extract_text(t.trigger_xml, '/ScriptTrigger/@browseMode')[1], '') || '|' ||
        COALESCE(xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/@UUID')[1], '') || '|' ||
        t.Owner_Type
    )) as Owner_UUID,
    t.Owner_Type,

    fn.File_Name as File_Name,

    -- Trigger_XML nur für Layout-/File-Level (s. Spalten-Kommentar oben);
    -- Object-Level bleibt NULL (Blob liegt bereits in LayoutObjects.Object_XML).
    CASE WHEN t.Owner_Type IN ('Layout', 'File')
         THEN t.trigger_xml::VARCHAR END as Trigger_XML,

    -- Modus-Scope + Transaktions-Parameterfeld (Schema 1.24.0, s. Spalten-
    -- Kommentare oben): Attribut fehlt = Modus aus / kein Parameterfeld.
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@findMode')[1] as Trigger_FindMode,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@previewMode')[1] as Trigger_PreviewMode,
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/@scriptParameterFieldName')[1] as Trigger_ScriptParameter_FieldName,

    -- Parameter-Klartext (Schema 1.26.0, s. Spalten-Kommentar oben):
    -- xml_extract_text dekodiert CDATA/Entities → serialisierungs-unabhängig.
    xml_extract_text(t.trigger_xml, '/ScriptTrigger/ScriptReference/Calculation/Text')[1] as Trigger_Parameter_Text

FROM all_triggers t
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(t.trigger_xml, '/ScriptTrigger/@id')[1] IS NOT NULL
ON CONFLICT (Trigger_ID, Owner_UUID, File_Name) DO UPDATE SET
    Trigger_Action = EXCLUDED.Trigger_Action,
    Trigger_BrowseMode = EXCLUDED.Trigger_BrowseMode,
    Script_ID = EXCLUDED.Script_ID,
    Script_Name = EXCLUDED.Script_Name,
    Script_UUID = EXCLUDED.Script_UUID,
    Owner_Type = EXCLUDED.Owner_Type,
    Trigger_XML = EXCLUDED.Trigger_XML,
    Trigger_FindMode = EXCLUDED.Trigger_FindMode,
    Trigger_PreviewMode = EXCLUDED.Trigger_PreviewMode,
    Trigger_ScriptParameter_FieldName = EXCLUDED.Trigger_ScriptParameter_FieldName,
    Trigger_Parameter_Text = EXCLUDED.Trigger_Parameter_Text;
-- @END_STREAMIFY_BLOCK@


-- ============================================
-- 23. ExtendedPrivilegesCatalog
-- ============================================
-- Erweiterte Berechtigungen (fmwebdirect, fmxdbc, fmapp, etc.)
-- Pattern: XPath mit UNNEST für PrivilegeSetReferences
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS ExtendedPrivilegesCatalog (
    EP_ID BIGINT,
    EP_Name VARCHAR,
    EP_Description VARCHAR,
    EP_UUID VARCHAR,
    PrivilegeSet_IDs BIGINT[],
    PrivilegeSet_Names VARCHAR[],
    File_Name VARCHAR,
    PRIMARY KEY (EP_UUID, File_Name)
);

-- @P1_SECTION:main@
-- @STREAMIFY_BLOCK:extendedprivilegescatalog@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_privileges AS (
    SELECT
        unnest(xml_extract_elements(xml, '//ExtendedPrivilegesCatalog/ObjectList/ExtendedPrivilege')) as priv_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO ExtendedPrivilegesCatalog
SELECT
    xml_extract_text(priv_xml, '/ExtendedPrivilege/@id')[1]::BIGINT as EP_ID,
    xml_unescape(xml_extract_text(priv_xml, '/ExtendedPrivilege/@name')[1]) as EP_Name,
    ws_restore(xml_extract_text(priv_xml, '/ExtendedPrivilege/Description/text()')[1]) as EP_Description,
    xml_extract_text(priv_xml, '/ExtendedPrivilege/UUID/text()')[1] as EP_UUID,

    -- Array of PrivilegeSet IDs und Namen
    list(xml_extract_text(ps_xml, '/PrivilegeSetReference/@id')[1]::BIGINT) as PrivilegeSet_IDs,
    list(xml_extract_text(ps_xml, '/PrivilegeSetReference/@name')[1]) as PrivilegeSet_Names,

    fn.File_Name as File_Name

FROM raw_privileges
CROSS JOIN filename_normalized fn
LEFT JOIN LATERAL (
    SELECT unnest(xml_extract_elements(priv_xml, '//ObjectList/PrivilegeSetReference')) as ps_xml
) ps ON true
GROUP BY EP_ID, EP_Name, EP_Description, EP_UUID, fn.File_Name
ON CONFLICT (EP_UUID, File_Name) DO UPDATE SET
    EP_ID = EXCLUDED.EP_ID,
    EP_Name = EXCLUDED.EP_Name,
    EP_Description = EXCLUDED.EP_Description,
    PrivilegeSet_IDs = EXCLUDED.PrivilegeSet_IDs,
    PrivilegeSet_Names = EXCLUDED.PrivilegeSet_Names;
-- @END_STREAMIFY_BLOCK@


-- ============================================
-- 24. CustomMenuCatalog
-- ============================================
-- Benutzerdefinierte Menüs mit verschachtelter Hierarchie
-- Pattern: XPath mit JSON für polymorphe Strukturen
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS CustomMenuCatalog (
    Menu_ID BIGINT,
    Menu_Name VARCHAR,
    Menu_UUID VARCHAR,
    Menu_XML VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Menu_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_menus AS (
    SELECT
        unnest(xml_extract_elements(xml, '//CustomMenuCatalog/CustomMenu')) as menu_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO CustomMenuCatalog
SELECT
    xml_extract_text(menu_xml, '/CustomMenu/@id')[1]::BIGINT as Menu_ID,
    xml_unescape(xml_extract_text(menu_xml, '/CustomMenu/@name')[1]) as Menu_Name,
    xml_extract_text(menu_xml, '/CustomMenu/UUID/text()')[1] as Menu_UUID,

    -- Vollständige Menü-Struktur als XML (enthält verschachtelte Items).
    -- ws_restore: Menu_XML ist Calc-Anker der Menü-Kanten (CustomMenuItem-
    -- Extraktion + Install-/Title-Formeln) — Sentinel darf nicht persistieren.
    -- Item_XML (CustomMenuItemCatalog) liest aus DIESER Spalte → transitiv restauriert.
    ws_restore(menu_xml::VARCHAR) as Menu_XML,

    fn.File_Name as File_Name

FROM raw_menus
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(menu_xml, '/CustomMenu/@id')[1] IS NOT NULL
ON CONFLICT (Menu_UUID, File_Name) DO UPDATE SET
    Menu_ID = EXCLUDED.Menu_ID,
    Menu_Name = EXCLUDED.Menu_Name,
    Menu_XML = EXCLUDED.Menu_XML;


-- ============================================
-- 24a. CustomMenuItemCatalog (AP-3, D-2)
-- ============================================
-- Menü-Items als eigene Objekte (Voraussetzung dafür, dass die 8.177 Install-
-- + 426 Name-Anker der Items in v_calc_anchors auflösen und Item-Formel-Kanten
-- ein echtes Quell-Objekt bekommen). Ein <CustomMenuItem> trägt <UUID> (= der
-- _<UUID>_Install / _<UUID>_Name-Calc-Anker), @hash, @index, @isSubMenuItem,
-- @isSeparatorItem und <Command @name @id>. Extrahiert aus dem bereits in
-- CustomMenuCatalog abgelegten Menu_XML dieser Datei (kein Re-Parsing der XML).
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS CustomMenuItemCatalog (
    Item_UUID VARCHAR,
    Item_Hash VARCHAR,
    Item_Index BIGINT,
    Is_SubMenuItem BOOLEAN,
    Is_SeparatorItem BOOLEAN,
    Command_Name VARCHAR,
    Command_ID VARCHAR,
    Menu_ID BIGINT,
    Menu_UUID VARCHAR,
    Menu_Name VARCHAR,
    Item_XML VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Item_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH exploded AS (
    SELECT
        m.File_Name, m.Menu_ID, m.Menu_UUID, m.Menu_Name,
        unnest(xml_extract_elements(m.Menu_XML, '//CustomMenuItem'))::VARCHAR AS Item_XML
    FROM CustomMenuCatalog m
    WHERE m.File_Name = getvariable('fm_file')
)
INSERT INTO CustomMenuItemCatalog
SELECT
    upper(xml_extract_text(Item_XML, '/CustomMenuItem/UUID')[1])                 AS Item_UUID,
    xml_extract_text(Item_XML, '/CustomMenuItem/@hash')[1]                       AS Item_Hash,
    TRY_CAST(xml_extract_text(Item_XML, '/CustomMenuItem/@index')[1] AS BIGINT) AS Item_Index,
    xml_extract_text(Item_XML, '/CustomMenuItem/@isSubMenuItem')[1] = 'True'     AS Is_SubMenuItem,
    xml_extract_text(Item_XML, '/CustomMenuItem/@isSeparatorItem')[1] = 'True'   AS Is_SeparatorItem,
    xml_extract_text(Item_XML, '/CustomMenuItem/Command/@name')[1]               AS Command_Name,
    xml_extract_text(Item_XML, '/CustomMenuItem/Command/@id')[1]                 AS Command_ID,
    Menu_ID, Menu_UUID, Menu_Name, Item_XML, File_Name
FROM exploded
WHERE Item_XML IS NOT NULL
  AND xml_extract_text(Item_XML, '/CustomMenuItem/UUID')[1] IS NOT NULL
ON CONFLICT (Item_UUID, File_Name) DO UPDATE SET
    Item_Hash = EXCLUDED.Item_Hash,
    Item_Index = EXCLUDED.Item_Index,
    Is_SubMenuItem = EXCLUDED.Is_SubMenuItem,
    Is_SeparatorItem = EXCLUDED.Is_SeparatorItem,
    Command_Name = EXCLUDED.Command_Name,
    Command_ID = EXCLUDED.Command_ID,
    Menu_ID = EXCLUDED.Menu_ID,
    Menu_UUID = EXCLUDED.Menu_UUID,
    Menu_Name = EXCLUDED.Menu_Name,
    Item_XML = EXCLUDED.Item_XML;


-- ============================================
-- 24b. FileAccessAuthorizations
-- ============================================
-- Datei-Zugriffsschutz: welche Dateien/Plugins dürfen diese Datei referenzieren.
-- Struktur (Tiefe 3, bleibt in main): <FileAccessCatalog @sameHost @required>
--   <UUID/> <ObjectList> <Authorization @id @type=Local|External [@self]>
--   <Source @CreationAccountName @CreationTimestamp/> <UUID>#text</UUID>
--   <Display>CDATA</Display> <Authentication>hash</Authentication> <TagList/>.
-- read_xml_objects + XPath (kein typisiertes record_element → kein globales Leck).
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS FileAccessAuthorizations (
    Auth_ID BIGINT,
    Auth_Type VARCHAR,                  -- Local | External
    Is_Self BOOLEAN,
    Authorized_Name VARCHAR,            -- Display (CDATA): referenzierte Datei / Plugin
    Auth_UUID VARCHAR,
    Authentication_Hash VARCHAR,
    Source_CreationAccountName VARCHAR,
    Source_CreationTimestamp VARCHAR,
    Catalog_Required BOOLEAN,           -- FileAccessCatalog/@required (pro Datei konstant)
    Catalog_SameHost BOOLEAN,           -- FileAccessCatalog/@sameHost
    File_Name VARCHAR,
    PRIMARY KEY (Auth_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_auth AS (
    SELECT
        xml_extract_text(xml, '//FileAccessCatalog/@required')[1] as cat_required,
        xml_extract_text(xml, '//FileAccessCatalog/@sameHost')[1] as cat_samehost,
        unnest(xml_extract_elements(xml, '//FileAccessCatalog/ObjectList/Authorization')) as auth_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO FileAccessAuthorizations
SELECT
    xml_extract_text(auth_xml, '/Authorization/@id')[1]::BIGINT as Auth_ID,
    xml_extract_text(auth_xml, '/Authorization/@type')[1] as Auth_Type,
    (lower(coalesce(xml_extract_text(auth_xml, '/Authorization/@self')[1], '')) = 'true') as Is_Self,
    xml_extract_text(auth_xml, '/Authorization/Display/text()')[1] as Authorized_Name,
    xml_extract_text(auth_xml, '/Authorization/UUID/text()')[1] as Auth_UUID,
    xml_extract_text(auth_xml, '/Authorization/Authentication/text()')[1] as Authentication_Hash,
    xml_extract_text(auth_xml, '/Authorization/Source/@CreationAccountName')[1] as Source_CreationAccountName,
    xml_extract_text(auth_xml, '/Authorization/Source/@CreationTimestamp')[1] as Source_CreationTimestamp,
    (lower(coalesce(cat_required, '')) = 'true') as Catalog_Required,
    (lower(coalesce(cat_samehost, '')) = 'true') as Catalog_SameHost,
    fn.File_Name as File_Name
FROM raw_auth
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(auth_xml, '/Authorization/UUID/text()')[1] IS NOT NULL
ON CONFLICT (Auth_UUID, File_Name) DO UPDATE SET
    Auth_ID = EXCLUDED.Auth_ID,
    Auth_Type = EXCLUDED.Auth_Type,
    Is_Self = EXCLUDED.Is_Self,
    Authorized_Name = EXCLUDED.Authorized_Name,
    Authentication_Hash = EXCLUDED.Authentication_Hash,
    Source_CreationAccountName = EXCLUDED.Source_CreationAccountName,
    Source_CreationTimestamp = EXCLUDED.Source_CreationTimestamp,
    Catalog_Required = EXCLUDED.Catalog_Required,
    Catalog_SameHost = EXCLUDED.Catalog_SameHost;


-- ============================================
-- 24c. CustomMenuSetCatalog
-- ============================================
-- Menü-Sets = benannte Sammlungen von Custom Menus, die ein Layout aktivieren kann.
-- Struktur (Tiefe 3, bleibt in main): <CustomMenuSetCatalog> … <ObjectList>
--   <CustomMenuSet @name @id @comment> <UUID>#text</UUID> <TagList/>
--   <CustomMenuList> <CustomMenuReference @name @id/> … </CustomMenuList> </CustomMenuSet>.
-- (Der Top-Level <CustomMenuSetReference> unter dem Katalog = Default-Set-Verweis, NICHT
--  in ObjectList → vom XPath ausgeschlossen.) Member-IDs/-Namen als Arrays; P4 entfaltet
--  sie zu CustomMenuSet→CustomMenu-Links (Auflösung per @id + File_Name).
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS CustomMenuSetCatalog (
    MenuSet_ID BIGINT,
    MenuSet_Name VARCHAR,
    Comment VARCHAR,
    MenuSet_UUID VARCHAR,
    Member_Menu_IDs BIGINT[],
    Member_Menu_Names VARCHAR[],
    File_Name VARCHAR,
    PRIMARY KEY (MenuSet_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_menusets AS (
    SELECT
        unnest(xml_extract_elements(xml, '//CustomMenuSetCatalog/ObjectList/CustomMenuSet')) as ms_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO CustomMenuSetCatalog
SELECT
    xml_extract_text(ms_xml, '/CustomMenuSet/@id')[1]::BIGINT as MenuSet_ID,
    xml_unescape(xml_extract_text(ms_xml, '/CustomMenuSet/@name')[1]) as MenuSet_Name,
    ws_restore(xml_extract_text(ms_xml, '/CustomMenuSet/@comment')[1]) as Comment,
    xml_extract_text(ms_xml, '/CustomMenuSet/UUID/text()')[1] as MenuSet_UUID,
    list(xml_extract_text(ref_xml, '/CustomMenuReference/@id')[1]::BIGINT)
        FILTER (WHERE ref_xml IS NOT NULL) as Member_Menu_IDs,
    list(xml_extract_text(ref_xml, '/CustomMenuReference/@name')[1])
        FILTER (WHERE ref_xml IS NOT NULL) as Member_Menu_Names,
    fn.File_Name as File_Name
FROM raw_menusets
CROSS JOIN filename_normalized fn
LEFT JOIN LATERAL (
    SELECT unnest(xml_extract_elements(ms_xml, '/CustomMenuSet/CustomMenuList/CustomMenuReference')) as ref_xml
) r ON true
WHERE xml_extract_text(ms_xml, '/CustomMenuSet/UUID/text()')[1] IS NOT NULL
GROUP BY MenuSet_ID, MenuSet_Name, Comment, MenuSet_UUID, fn.File_Name
ON CONFLICT (MenuSet_UUID, File_Name) DO UPDATE SET
    MenuSet_ID = EXCLUDED.MenuSet_ID,
    MenuSet_Name = EXCLUDED.MenuSet_Name,
    Comment = EXCLUDED.Comment,
    Member_Menu_IDs = EXCLUDED.Member_Menu_IDs,
    Member_Menu_Names = EXCLUDED.Member_Menu_Names;


-- ============================================
-- 24d. LibraryReferences  (Inventar)
-- ============================================
-- Eingebettete Medien-Bibliothek: <LibraryCatalog> <BinaryData>
--   <LibraryReference @id @key> + <StreamList> (Blobs). Wir behalten NUR die
--   Referenz-Schlüssel (key = Inhalts-Hash, über den Layout-Objekte/Themes das Bild
--   referenzieren) als schlankes Inventar. Die Blobs (~9,6 MB/Korpus) tragen keinen
--   Analysewert; ihr Byte-Schnitt im Phase-S-Preprocessing ist ein separater Schritt
--   („Phase-S-Schnitt", gebündelt mit der Phase-S-Fusion). Diese
--   Tabelle ist unabhängig davon korrekt (parst die Referenzen, ob Blobs da sind oder nicht).
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS LibraryReferences (
    Library_ID BIGINT,
    Library_Key VARCHAR,                -- Inhalts-Hash (Where-used-Schlüssel für Bilder)
    File_Name VARCHAR,
    -- PK = (Library_ID, File_Name): eine Zeile je LibraryReference (@id eindeutig je Datei).
    -- NICHT nach Library_Key dedupen — dasselbe Bild (key) darf in mehreren Library-Slots
    -- liegen (Test-Set: key 8985…DB60 unter id 10/15/16). Der key ist der Where-used-Join-Schlüssel
    -- (Layout/Theme → key), nicht der Identitäts-Schlüssel.
    PRIMARY KEY (Library_ID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_libref AS (
    SELECT
        unnest(xml_extract_elements(xml, '//LibraryCatalog/BinaryData/LibraryReference')) as ref_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO LibraryReferences
SELECT
    xml_extract_text(ref_xml, '/LibraryReference/@id')[1]::BIGINT as Library_ID,
    xml_extract_text(ref_xml, '/LibraryReference/@key')[1] as Library_Key,
    fn.File_Name as File_Name
FROM raw_libref
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(ref_xml, '/LibraryReference/@id')[1] IS NOT NULL
ON CONFLICT (Library_ID, File_Name) DO UPDATE SET
    Library_Key = EXCLUDED.Library_Key;


-- ============================================
-- 25. ThemeCatalog
-- ============================================
-- CSS-Regelsätze für Layouts
-- Pattern: XPath mit JSON für CSS-Strukturen
-- HINWEIS: Theme-Struktur ist sehr komplex mit CSS-Definitionen
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS ThemeCatalog (
    Theme_ID BIGINT,
    Theme_Name VARCHAR,
    Theme_Display VARCHAR,   -- <Theme @Display>: lokalisierter Anzeigename (z.B. „Apex Blau")
    Theme_UUID VARCHAR,
    Theme_XML VARCHAR,
    File_Name VARCHAR,
    PRIMARY KEY (Theme_UUID, File_Name)
);

-- @P1_SECTION:main@
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_themes AS (
    SELECT
        unnest(xml_extract_elements(xml, '//ThemeCatalog/Theme')) as theme_xml
    FROM read_xml_objects(getvariable('fm_xml'), maximum_file_size=getvariable('max_filesize'))
)
INSERT INTO ThemeCatalog
SELECT
    xml_extract_text(theme_xml, '/Theme/@id')[1]::BIGINT as Theme_ID,
    xml_unescape(xml_extract_text(theme_xml, '/Theme/@name')[1]) as Theme_Name,
    xml_unescape(xml_extract_text(theme_xml, '/Theme/@Display')[1]) as Theme_Display,
    xml_extract_text(theme_xml, '/Theme/UUID/text()')[1] as Theme_UUID,

    -- Vollständige Theme-Struktur als JSON (enthält CSS-Regelsätze).
    -- ws_restore: Sentinel darf nicht in gespeichertem Roh-XML persistieren.
    ws_restore(theme_xml::VARCHAR) as Theme_XML,

    fn.File_Name as File_Name

FROM raw_themes
CROSS JOIN filename_normalized fn
WHERE xml_extract_text(theme_xml, '/Theme/@id')[1] IS NOT NULL
ON CONFLICT (Theme_UUID, File_Name) DO UPDATE SET
    Theme_ID = EXCLUDED.Theme_ID,
    Theme_Name = EXCLUDED.Theme_Name,
    Theme_Display = EXCLUDED.Theme_Display,
    Theme_XML = EXCLUDED.Theme_XML;


-- ============================================
-- FileOptionsCatalog (Metadata-Branch, Schema 1.5.0)
-- ============================================
-- Datei-Optionen aus <Metadata>/<AddAction>: Verschlüsselungsstatus, Mindest-
-- version, Auto-Login (SICHERHEITSRELEVANT: Login type='1' + AccountName =
-- automatische Anmeldung), Sharing-Sichtbarkeit, Default-Layout ("wechseln zu"
-- beim Öffnen → default_layout-Kante in P4, schließt eine Where-used-Lücke).
-- Die Metadata-ScriptTrigger (OnFirstWindowOpen etc.) werden separat vom
-- ScriptTriggers-Block erfasst (Owner = File). Genau ein <Metadata> pro Datei.
-- Login-Semantik: type='-1' = kein Auto-Login; type='1' = Auto-Login mit Konto.
-- @END_P1_SECTION@
CREATE TABLE IF NOT EXISTS FileOptionsCatalog (
    File_Name VARCHAR PRIMARY KEY,
    Encryption_Type VARCHAR,        -- '0' = unverschlüsselt
    Min_Version VARCHAR,            -- Mindest-FileMaker-Version (z.B. '12.0')
    Min_Version_Value VARCHAR,
    Login_Type VARCHAR,
    Login_AccountName VARCHAR,      -- nur bei Auto-Login (type='1')
    Show_SignIn_Fields BOOLEAN,
    Spelling_Underline BOOLEAN,
    Hide_WebDirect_Sharing BOOLEAN,
    Hide_Client_Sharing BOOLEAN,
    Default_Layout_ID BIGINT,       -- Defaults/LayoutReference (Start-Layout)
    Default_Layout_Name VARCHAR,
    Default_Layout_UUID VARCHAR,
    -- Schema 1.5.2: SavePassword ("Gespeicherte Anmeldeinformationen zulassen",
    -- eigenständig vom Auto-Login <Login>) + PageSetup (Druck-Standard)
    Save_Password_Keychain BOOLEAN,     -- keychain="True" → Speichern erlaubt
    Save_Password_RequireMobile BOOLEAN,-- auf Mobilgeräten erneut anfordern
    PageSetup_Orientation VARCHAR,      -- 'Portrait'/'Landscape'
    PageSetup_Scale VARCHAR,            -- Druck-Skalierung in %
    PageSetup_Width VARCHAR,            -- Papierbreite (1/100 Zoll)
    PageSetup_Height VARCHAR            -- Papierhöhe (1/100 Zoll)
);

-- @P1_SECTION:main@
DELETE FROM FileOptionsCatalog WHERE File_Name = getvariable('fm_file');

WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
)
INSERT INTO FileOptionsCatalog
SELECT
    fn.File_Name,
    m.AddAction.Encryption.type AS Encryption_Type,
    m.AddAction.Minimum.version AS Min_Version,
    m.AddAction.Minimum.value AS Min_Version_Value,
    m.AddAction.Login.type AS Login_Type,
    NULLIF(m.AddAction.Login.AccountName, '') AS Login_AccountName,
    m.AddAction.ShowSignInFields.enable AS Show_SignIn_Fields,
    m.AddAction.Spelling.underline AS Spelling_Underline,
    m.AddAction.HideWebDirectSharing.enable AS Hide_WebDirect_Sharing,
    m.AddAction.HideClientSharing.enable AS Hide_Client_Sharing,
    m.AddAction.Defaults.LayoutReference.id AS Default_Layout_ID,
    xml_unescape(m.AddAction.Defaults.LayoutReference.name) AS Default_Layout_Name,
    m.AddAction.Defaults.LayoutReference.UUID AS Default_Layout_UUID,
    m.AddAction.SavePassword.keychain AS Save_Password_Keychain,
    m.AddAction.SavePassword.requireMobile AS Save_Password_RequireMobile,
    m.AddAction.PageSetup.Orientation.name AS PageSetup_Orientation,
    m.AddAction.PageSetup.scale.value AS PageSetup_Scale,
    m.AddAction.PageSetup.size.width AS PageSetup_Width,
    m.AddAction.PageSetup.size.height AS PageSetup_Height
FROM read_xml(
    getvariable('fm_xml'),
    record_element='Metadata',
    maximum_file_size=getvariable('dom_threshold'),
    streaming=getvariable('use_streaming'),
    columns={
        'AddAction': 'STRUCT(
            "Encryption" STRUCT("type" VARCHAR),
            "Minimum" STRUCT("version" VARCHAR, "value" VARCHAR),
            "Login" STRUCT("type" VARCHAR, "AccountName" VARCHAR),
            "ShowSignInFields" STRUCT("enable" BOOLEAN),
            "Spelling" STRUCT("underline" BOOLEAN),
            "HideWebDirectSharing" STRUCT("enable" BOOLEAN),
            "HideClientSharing" STRUCT("enable" BOOLEAN),
            "Defaults" STRUCT(
                "LayoutReference" STRUCT("id" BIGINT, "name" VARCHAR, "UUID" VARCHAR)
            ),
            "SavePassword" STRUCT("keychain" BOOLEAN, "requireMobile" BOOLEAN),
            "PageSetup" STRUCT(
                "Orientation" STRUCT("name" VARCHAR, "value" VARCHAR),
                "size" STRUCT("height" VARCHAR, "width" VARCHAR),
                "scale" STRUCT("value" VARCHAR)
            )
        )'
    }
) m
CROSS JOIN filename_normalized fn
-- WICHTIG: record_element='Metadata' matcht AUCH die Theme-internen
-- <Metadata><namedstyles>-Blöcke (ThemeCatalog). Nur der echte Datei-Options-
-- Branch trägt <AddAction> → filtern; Ein-Zeilen-Guard gegen pathologische
-- Mehrfach-Treffer (Zeilen wären ohnehin identisch, PK-Schutz).
WHERE m.AddAction IS NOT NULL
QUALIFY ROW_NUMBER() OVER () = 1
ON CONFLICT (File_Name) DO UPDATE SET
    Encryption_Type = EXCLUDED.Encryption_Type,
    Min_Version = EXCLUDED.Min_Version,
    Min_Version_Value = EXCLUDED.Min_Version_Value,
    Login_Type = EXCLUDED.Login_Type,
    Login_AccountName = EXCLUDED.Login_AccountName,
    Show_SignIn_Fields = EXCLUDED.Show_SignIn_Fields,
    Spelling_Underline = EXCLUDED.Spelling_Underline,
    Hide_WebDirect_Sharing = EXCLUDED.Hide_WebDirect_Sharing,
    Hide_Client_Sharing = EXCLUDED.Hide_Client_Sharing,
    Default_Layout_ID = EXCLUDED.Default_Layout_ID,
    Default_Layout_Name = EXCLUDED.Default_Layout_Name,
    Default_Layout_UUID = EXCLUDED.Default_Layout_UUID,
    Save_Password_Keychain = EXCLUDED.Save_Password_Keychain,
    Save_Password_RequireMobile = EXCLUDED.Save_Password_RequireMobile,
    PageSetup_Orientation = EXCLUDED.PageSetup_Orientation,
    PageSetup_Scale = EXCLUDED.PageSetup_Scale,
    PageSetup_Width = EXCLUDED.PageSetup_Width,
    PageSetup_Height = EXCLUDED.PageSetup_Height;


-- ============================================
-- @END_P1_SECTION@
-- SchemaInfo aktualisieren
-- ============================================
-- Letzter Schritt: nach erfolgreichem Import den Schema-Stand persistieren.
-- Wenn der Lauf vorher abbricht, bleibt der alte SchemaInfo-Eintrag aktuell,
-- sodass die Detection beim nächsten Aufruf den Drift sauber erkennt.
INSERT INTO SchemaInfo (Schema_Version, Schema_Hash, Schema_Built_At, Builder_Notes)
VALUES (
    getvariable('schema_version'),
    getvariable('schema_hash'),
    CURRENT_TIMESTAMP,
    getvariable('schema_notes')
);


-- ============================================
-- IMPLEMENTIERUNGS-STATUS
-- ============================================
-- ✅ Phase 0: Basis-Kataloge (10 Tabellen)
-- ✅ Phase 1: Erweiterte Basis-Kataloge (5 Tabellen)
-- ✅ Phase 2: DDR_INFO Integration (3 Tabellen)
-- ✅ Phase 3: Layout-Objekte (1 Tabelle)
-- ✅ Phase 4: Optionale Kataloge (6 Tabellen)
-- ✅ Phase 5: SchemaInfo (Versionierung & Auto-Heal)
--
-- GESAMT: 26 Tabellen erfolgreich implementiert



