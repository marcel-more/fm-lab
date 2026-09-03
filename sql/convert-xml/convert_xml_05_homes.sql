-- ============================================
-- convert_xml_05_homes.sql — Phase 5 der XML-Konvertierungs-Pipeline
-- ============================================
-- Datei-übergreifende Heimat-Auflösungs-Tabellen.
-- Wird nach allen File-Imports vom Batch-Skript einmalig aufgerufen
-- (auch im Single-File-Modus). Vollständiger Neuaufbau, keine Migration.
--
-- Erzeugt:
--   - ObjectHomes: kanonische Heimat-Datei pro Object-UUID (alle Schema-Objekt-Typen)
--   - TableOccurrenceResolution: TO → BaseTable + Heimat-Datei (DS-basiert)

-- --------------------------------------------
-- ObjectHomes — Single Source of Truth pro Objekt
-- --------------------------------------------
DROP TABLE IF EXISTS ObjectHomes;
CREATE TABLE ObjectHomes (
    Object_UUID  VARCHAR PRIMARY KEY,
    Object_Type  VARCHAR NOT NULL,
    Object_Name  VARCHAR NOT NULL,
    Home_File    VARCHAR NOT NULL,
    Source       VARCHAR NOT NULL    -- 'direct' | 'resolved_via_basetable'
);

-- Block 1: Direkte Heimat aus ObjectCatalog.
-- Field-/Script-UUIDs sind global eindeutig — ein Eintrag pro Objekt.
-- Plugin-Functions sind kein FileMaker-Schema-Objekt → nicht enthalten.
-- Variables sind kein Schema-Objekt → nicht enthalten (siehe Validierungsfilter).
INSERT INTO ObjectHomes
SELECT
    oc.Object_UUID,
    oc.Object_Type,
    oc.Object_Name,
    oc.File_Name AS Home_File,
    'direct' AS Source
FROM ObjectCatalog oc
WHERE oc.Object_Type IN (
    'Field', 'Script', 'Layout', 'CustomFunction', 'ValueList',
    'Theme', 'CustomMenu', 'ScriptTrigger', 'Account', 'PrivilegeSet',
    'ExternalDataSource', 'BaseDirectory', 'LayoutPart',
    'BaseTable', 'TableOccurrence', 'Relationship',
    -- B-C6: Typenliste nachgezogen (fehlten seit ihrer Einführung)
    'CustomMenuSet', 'CustomMenuItem', 'ExtendedPrivilege'
)
-- B-C6: deterministischer Gewinner bei Klon-UUIDs (gleiche UUID in mehreren
-- Dateien) — vorher entschied die Scan-Reihenfolge über ON CONFLICT DO NOTHING.
QUALIFY ROW_NUMBER() OVER (PARTITION BY oc.Object_UUID
                           ORDER BY oc.File_Name, oc.Object_Type, oc.Object_Name) = 1
ON CONFLICT (Object_UUID) DO NOTHING;

-- Block 2: BaseTable-Heimat über Feld-Anzahl auflösen.
-- Schatten-BTs in referenzierenden Files können EINIGE Schatten-Felder haben
-- (typischerweise wenige, z.B. 3 Felder vs. 158 in der echten Heimat).
-- Die "lokal-Felder-Detektion" (NOT EXISTS) versagt deshalb. Stattdessen:
-- Unter allen gleichnamigen BTs ist diejenige mit den meisten Feldern die echte Heimat.
-- Falls mehrere BTs gleich viele Felder haben (Edge-Case): ORDER BY File_Name LIMIT 1
-- für Determinismus.
UPDATE ObjectHomes oh
SET Home_File = sub.real_home,
    Source    = 'resolved_via_basetable'
FROM (
    WITH bt_with_field_count AS (
        SELECT
            bt.BT_UUID,
            bt.BT_Name,
            bt.File_Name,
            (SELECT COUNT(*) FROM FieldsForTables ff
             WHERE ff.Table_UUID = bt.BT_UUID AND ff.File_Name = bt.File_Name) AS field_count
        FROM BaseTableCatalog bt
    ),
    bt_canonical AS (
        SELECT BT_Name, File_Name AS canonical_file, field_count
        FROM bt_with_field_count
        QUALIFY ROW_NUMBER() OVER (PARTITION BY BT_Name ORDER BY field_count DESC, File_Name) = 1
    )
    SELECT
        oh_inner.Object_UUID,
        bt_canonical.canonical_file AS real_home
    FROM ObjectHomes oh_inner
    JOIN BaseTableCatalog bt_self
      ON bt_self.BT_UUID = oh_inner.Object_UUID
    JOIN bt_canonical
      ON bt_canonical.BT_Name = bt_self.BT_Name
    WHERE oh_inner.Object_Type = 'BaseTable'
      AND oh_inner.Home_File <> bt_canonical.canonical_file
      AND bt_canonical.field_count > 0  -- echte BT muss mind. 1 Feld haben
) sub
WHERE oh.Object_UUID = sub.Object_UUID
  AND sub.real_home IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_objecthomes_type ON ObjectHomes(Object_Type);
CREATE INDEX IF NOT EXISTS idx_objecthomes_name ON ObjectHomes(Object_Name);


-- --------------------------------------------
-- TableOccurrenceResolution — TO Cross-File-Mapping
-- --------------------------------------------
DROP TABLE IF EXISTS TableOccurrenceResolution;
-- Local_BT_UUID/Canonical_BT_Name sind NULLable, weil verwaiste TableOccurrences
-- (TO ohne BaseTable-Verknüpfung — im XML mit fehlendem BT_UUID) vorkommen.
CREATE TABLE TableOccurrenceResolution (
    TO_UUID           VARCHAR NOT NULL,
    File_Name         VARCHAR NOT NULL,
    TO_Name           VARCHAR NOT NULL,
    Local_BT_UUID     VARCHAR,
    Canonical_BT_Name VARCHAR,
    Home_File         VARCHAR NOT NULL,
    Resolution_Type   VARCHAR NOT NULL,    -- 'local' | 'cross_file_ds' | 'orphan'
    Data_Source_Name  VARCHAR,
    PRIMARY KEY (TO_UUID, File_Name)
);

INSERT INTO TableOccurrenceResolution
SELECT
    toc.TO_UUID,
    toc.File_Name,
    toc.TO_Name,
    toc.BT_UUID  AS Local_BT_UUID,
    toc.BT_Name  AS Canonical_BT_Name,
    -- Path kann komplex sein: einzelner Pfad mit Leerzeichen im Dateinamen
    -- (z.B. 'file:Belegpositionen Einkauf'), Pfad mit Verzeichnis-Slashes
    -- ('file:../ERP/Artikel'), oder Multi-Path-Liste mit Fallbacks
    -- ('file:Artikel file:../ERP/Artikel'). Schritt 1: Alles ab '<space>file:'
    -- entfernen, damit nur der primäre Pfad bleibt. Schritt 2: 'file:'-Prefix
    -- abschneiden und letzten Path-Component (basename) extrahieren — Slashes
    -- markieren Verzeichnis-Hierarchie, der Dateiname kommt zuletzt.
    COALESCE(
        regexp_replace(
            regexp_extract(
                regexp_replace(eds.Path, '\s+file:.*$', ''),
                '^file:(?:.*/)?(.+)$',
                1
            ),
            '\.fmp12$', ''   -- Suffix entfernen, da File_Name in unseren Tabellen ohne ".fmp12" gespeichert ist
        ),
        toc.File_Name
    ) AS Home_File,
    CASE
        WHEN toc.DS_UUID IS NOT NULL AND eds.Path IS NOT NULL THEN 'cross_file_ds'
        WHEN toc.DS_UUID IS NULL                              THEN 'local'
        ELSE 'orphan'
    END AS Resolution_Type,
    toc.DS_Name AS Data_Source_Name
FROM TableOccurrenceCatalog toc
LEFT JOIN ExternalDataSourceCatalog eds
  ON toc.DS_UUID  = eds.DS_UUID
 AND toc.File_Name = eds.File_Name
ON CONFLICT (TO_UUID, File_Name) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_tor_to_uuid ON TableOccurrenceResolution(TO_UUID);
CREATE INDEX IF NOT EXISTS idx_tor_file    ON TableOccurrenceResolution(File_Name);


-- ============================================================================
-- Graph-Views: LogicalLinks + ClusterEdges
-- ============================================================================
-- EINE View-Definition als Single Source of Truth für den "logischen" Graphen.
-- Konsumenten: graph_export_logical.sql (Cluster-Engine-Input edges.csv),
-- die Skill-Grad-/Hub-Analyse (fm-graph-cluster), und perspektivisch der
-- Graph-Explorer (graph_subgraph.sql). Vor v2 lebte diese Logik 3× inline
-- dupliziert (Export, Subgraph, Skill-Adhoc) und driftete dadurch auseinander
-- — die Skill-Hub-Analyse rechnete auf rohem ObjectLinks und meldete God-Nodes,
-- die im tatsächlich geclusterten Graphen gar nicht so existieren.
--
-- WARUM IN P5: P5 ist table-only (kein read_xml), batch-weit und läuft NACH P4
-- (das ObjectCatalog/ObjectLinks erzeugt) — die View-Abhängigkeiten sind erfüllt.
-- Eine View materialisiert nichts (nur gespeicherte Query) → kein Speicher-/
-- Laufzeit-Kostenpunkt im Build. cluster.sh ruft den Export mit -readonly auf
-- (CREATE VIEW ginge dort nicht); P5 ist der ohnehin schreibende Lauf. Die Views
-- werden vom convert-xml-Sync automatisch in die READ_ONLY-API-Kopie gespiegelt.
--
-- KANONISCHE QUELLE: rest-api/templates/sql/graph_logical_links.sql (v1.5.0).
-- Diese LogicalLinks-Definition MUSS mit jener Datei deckungsgleich bleiben;
-- bei Änderung beide Stellen synchron halten (Drift bricht die Cluster-Färbung).

-- LogicalLinks — operationale Referenz-Kanten, Sub-Objekte auf ihren Container
-- hochgezogen, Containment-Gerüst + Waisen verworfen, (a,b)-dedupliziert. MIT
-- Builtins (and/or/Case …) — der Builtin-Filter sitzt erst in ClusterEdges.
--
-- STUFE C: lokale Variablen ($x) werden hier
-- ausgeschlossen. Ihr Knoten-UUID ist md5(Variable_Scope::Scope_Anchor::Name) und
-- der Scope_Anchor einer LOKALEN Variable ist das Script → sie ist an genau ein
-- Script gekettet ⇒ Degree-1-Pendant, kann NIE eine Brücke zwischen Modulen sein.
-- Strukturell inert fürs Clustering, reiner visueller Clutter im Explorer
-- („farbige Bündel um Scripte"): 33,9 % aller Cluster-Knoten, 10,8 % der Kanten.
-- GLOBALE ($$) und superglobale ($$$) Variablen BLEIBEN (Scope_Anchor=Datei bzw.
-- __global → über Scripte geteilt = echte Cross-Script-Brücken). Das semantische
-- Variablen-Signal bleibt erhalten: die Skills (fm-analyze/fm-graph-cluster) lesen
-- Variablennamen aus VariableUsages/VariablesCatalog (per Script), nicht aus dem
-- Graph. raw-Sicht + Basistabellen bleiben unberührt.
--
-- SPEZIALTYPEN (v1.5.0, Converter 2.22.0): Chart und Web Viewer werden NICHT
-- gehoisted. Ihre Feld-/Variablen-Bezüge kommen aus EIGENEN Calc-Slots (Chart-
-- Titel/Achsen/Serien, web_viewer_url) und sind unsichtbare Datenquellen von
-- OBJEKT-Eigenschaften — anders als die sichtbare Platzierung eines Feld-
-- Controls, für die „Layout zeigt Feld" wahr ist. Das pauschale Hoisting sagte
-- hier „Layout liest Feld" und attribuierte damit falsch. Kriterium ist die
-- kuratierte Typ-Liste (standalone-CTE), NICHT die Kanten-Rolle. Die eigene
-- parent_layout-Kante wird für diese Klasse im Rollen-Filter wieder zugelassen
-- und trägt den Knoten ins Layout (Layout → Objekt d1 → Felder/Variablen d2).
CREATE OR REPLACE VIEW LogicalLinks AS
WITH container AS (
  -- Sub-Objekt-UUID → Top-Level-Container-UUID (ein direkter Hop, keine Rekursion)
  SELECT Source_UUID AS child, Target_UUID AS parent
  FROM ObjectLinks
  WHERE Link_Role IN ('parent_layout', 'parent_script')
),
standalone AS (
  -- Spezialtypen (s. Kopf-Note v1.5.0): logisch eigenständige Rechen-Objekte.
  -- KURATIERTE Typ-Liste, bewusst KEIN Rollen-Kriterium (reads_field tragen auch
  -- Feld-Controls aus Hide-/Tooltip-Calcs; dort bleibt das Layout der Sprecher).
  -- Winzige Menge (Großkorpus: 0,04 % aller LayoutObjects) → billige Hash-Build-
  -- Seite im LEFT JOIN, kein Doppel-Scan-Risiko.
  -- INVARIANTE: Spezialtypen tragen kein displays_field (keine sichtbare Feld-
  -- Repräsentation ist genau das Abgrenzungs-Kriterium der Klasse) → der Feld-
  -- Anker-Zweig unten kollidiert nicht. Der Vorrang im CASE ist trotzdem gesetzt,
  -- damit ein künftiger Gegenbeispiel-Datensatz kein (a, a_file)-Mischtupel baut.
  SELECT Object_UUID, File_Name
  FROM LayoutObjects
  WHERE Object_Type IN ('Chart', 'Web Viewer')
),
field_anchor AS (
  -- Semantischer Anker der Objekt-Trigger-Spiegel (Converter 2.18.0): das vom
  -- Trigger-Owner ANGEZEIGTE Feld. Ein Objekt-Trigger sitzt in FileMaker am
  -- Layoutobjekt eines Felds — das Feld ist der Datenanker der Beziehung; das
  -- generische Container-Hoisting aufs Layout attribuierte sie falsch („Layout
  -- triggert Script"). Trigger-tragende Feld-Objekte zeigen ausnahmslos genau
  -- 1 Feld (korpusverifiziert 3260/3260); min()/arg_min() sichern den
  -- Determinismus für exotische Mehrfach-displays_field-Fälle ab. Owner ohne
  -- Feld (UI-Kontrollen: Popover/Tab/Buttons) fallen aufs Layout zurück.
  SELECT Source_UUID AS owner, Source_File AS owner_file,
         min(Target_UUID) AS fld,
         arg_min(Target_File, Target_UUID) AS fld_file
  FROM ObjectLinks
  WHERE Link_Role = 'displays_field' AND Source_Type = 'LayoutObject'
  GROUP BY 1, 2
),
local_var AS (
  -- Lokale Variablen: Prefix genau EIN '$' (global=$$, superglobal=$$$). Exhaustiv,
  -- da alle Variablen-Knoten mit '$' beginnen; Object_Type-Guard schützt vor
  -- '$'-benannten Nicht-Variablen.
  SELECT Object_UUID
  FROM ObjectCatalog
  WHERE Object_Type = 'Variable'
    AND Object_Name LIKE '$%'
    AND Object_Name NOT LIKE '$$%'
),
hoisted AS (
  -- Quell-Hoisting mit Feld-Anker-Sonderfall: Event-Spiegel (triggers_script,
  -- Subrole ≠ button_action) eines feld-gebundenen Owners wandern aufs FELD
  -- (Existenz-Semantik: „≥1 Platzierung dieses Felds trägt den Trigger");
  -- button_action bleibt layout-verankert (Aktion = UI-Angebot der Maske,
  -- kein Datenanker), alles andere hoisted wie bisher auf den Container.
  SELECT
    CASE WHEN sa.Object_UUID IS NOT NULL THEN ol.Source_UUID
         WHEN ol.Link_Role = 'triggers_script'
          AND ol.Link_Subrole IS DISTINCT FROM 'button_action'
          AND fa.fld IS NOT NULL
         THEN fa.fld
         ELSE COALESCE(cs.parent, ol.Source_UUID) END AS a,
    -- Klon-Robustheit: Datei der Source/Target mitführen. Containment (parent_layout/
    -- parent_script) ist datei-lokal → der hochgezogene Container liegt in DERSELBEN
    -- Datei wie das Sub-Objekt → a_file = ol.Source_File (analog b_file). Der
    -- FELD-Anker dagegen kann in einer ANDEREN Datei liegen (Related-Field-
    -- Platzierung) → a_file/Is_Cross_File werden für diesen Zweig neu bestimmt.
    CASE WHEN sa.Object_UUID IS NOT NULL THEN ol.Source_File
         WHEN ol.Link_Role = 'triggers_script'
          AND ol.Link_Subrole IS DISTINCT FROM 'button_action'
          AND fa.fld IS NOT NULL
         THEN fa.fld_file
         ELSE ol.Source_File END AS a_file,
    COALESCE(ct.parent, ol.Target_UUID) AS b,
    ol.Target_File AS b_file,
    ol.Link_Role,
    ol.Link_Subrole,
    ol.Link_Type,
    CASE WHEN sa.Object_UUID IS NOT NULL THEN ol.Is_Cross_File
         WHEN ol.Link_Role = 'triggers_script'
          AND ol.Link_Subrole IS DISTINCT FROM 'button_action'
          AND fa.fld IS NOT NULL
         THEN (fa.fld_file IS DISTINCT FROM ol.Target_File)
         ELSE ol.Is_Cross_File END AS Is_Cross_File
  FROM ObjectLinks ol
  LEFT JOIN container cs ON cs.child = ol.Source_UUID
  LEFT JOIN container ct ON ct.child = ol.Target_UUID
  LEFT JOIN standalone   sa ON sa.Object_UUID = ol.Source_UUID AND sa.File_Name = ol.Source_File
  LEFT JOIN field_anchor fa ON fa.owner = ol.Source_UUID AND fa.owner_file = ol.Source_File
  WHERE ol.Link_Type = 'operational'
    -- Containment-Gerüst raus (parent_table bleibt: echte Field→BaseTable-Referenz).
    -- trigger_script raus (Graph-Policy seit Converter 2.17.0): Trigger-Knoten
    -- hingen im Graph AUSSCHLIESSLICH an ihrem Script (trigger_owner ist
    -- structural) — reine Satelliten ohne eingehende Kanten, in großen Lösungen
    -- ein erheblicher Teil des Cluster-Universums. Die Owner↔Script-Affinität
    -- tragen seit 2.17.0 die triggers_script-Spiegel aller drei Owner-Ebenen
    -- (P4 Block 21a); Trigger-Knoten bleiben Katalog-/Navigationsobjekte, der
    -- Graph-Tab eines Trigger-Fokus läuft vollständig über die Fokus-Brücke
    -- (graph_subgraph.sql/graph_depth_profile.sql: trigger_owner + trigger_script).
    -- Gleiche Policy für die zweite trigger-verankerte Kanten-Familie: die
    -- OnWindowTransaction-Namens-Kandidaten (reads_field·transaction_parameter_field,
    -- P4 Block 18c) sind spekulative Late-Binding-Kandidaten — als Cluster-Affinität
    -- Trigger↔Feld wertlos und sie hielten den Trigger-Knoten sonst als Satellit im
    -- Graph. In ObjectLinks/Referenzlisten bleiben sie unberührt.
    AND (ol.Link_Role NOT IN
        ('parent_layout', 'parent_script', 'parent_object', 'parent_folder',
         'trigger_script')
         -- AUSNAHME Spezialtypen (v1.5.0): ihre eigene parent_layout-Kante ist die
         -- Verbindungs-Kante Objekt→Layout, die den un-gehoisteten Knoten im Graphen
         -- anschlussfähig hält (Layout → Objekt d1 → Felder/Variablen d2). Sie ist
         -- operational (LayoutObject→Layout; nur LayoutPart→Layout ist structural)
         -- und passiert den Link_Type-Filter oben. Jedes LayoutObject traegt genau
         -- eine solche Kante, auch verschachtelte (s. DATENBEFUND).
         OR (ol.Link_Role = 'parent_layout' AND sa.Object_UUID IS NOT NULL))
    AND NOT (ol.Link_Role = 'reads_field'
             AND ol.Link_Subrole = 'transaction_parameter_field')
    -- Waisen raus: beide Endpunkte müssen katalogisiert sein
    AND ol.Source_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
    AND ol.Target_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
)
SELECT DISTINCT
  a            AS Source_UUID,
  a_file       AS Source_File,
  b            AS Target_UUID,
  b_file       AS Target_File,
  Link_Role,
  Link_Subrole,
  Link_Type,
  Is_Cross_File
FROM hoisted
WHERE a <> b   -- durch Hochziehen entstandene Selbst-Schleifen verwerfen
  -- Stufe C: lokale Variablen-Pendants (beide Endpunkte) entfernen
  AND a NOT IN (SELECT Object_UUID FROM local_var)
  AND b NOT IN (SELECT Object_UUID FROM local_var);

-- ============================================================================
-- Cluster-Kantensatz — dreistufig (Stufe D)
-- ============================================================================
-- ClusterEdgesBase → ClusterGodNodes → ClusterEdges. Builtins sind God-Nodes,
-- die Communities verschmelzen würden → ausgeschlossen. STUFE D ergänzt einen
-- zweiten Ausschluss: querschneidende "God-Nodes" (Nachbarn über ≥8 Dateien UND
-- ≤40 % in der eigenen Datei) — generische MBS-Plugin-Utilities + globale Konfig-/
-- Auth-Felder, die die Modulgrenzen verwischen. Verifiziert: 33 Knoten raus ⇒
-- Q 0,9278→0,9324, K stabil (keine Fragmentierung). Schema-Anker (BaseTable Artikel,
-- own_file_share≈0,99) werden NICHT getroffen. Der Filter sitzt NUR hier in
-- ClusterEdges (Clustering + Skill-Hub-Analyse), NICHT in LogicalLinks — der
-- Explorer/where-used soll God-Nodes weiter zeigen.
--
-- KLON-ROBUSTHEIT (Cluster-Knoten-Key = (UUID, File_Name)): die Kette führt jetzt
-- Source_File/Target_File mit (LogicalLinks trägt sie). Der Export keyt
-- Knoten als composite `uuid::file` (graph_export_logical.sql) → zwei Klone DERSELBEN
-- UUID in verschiedenen Dateien bleiben getrennte Cluster-Knoten (vorher zu EINEM
-- kollabiert ⇒ verschmolzene Kanten = potenziell falsche Module). Auf klon-freien
-- Lösungen ist jede UUID datei-eindeutig ⇒ `uuid::file` ist reine Knoten-Umbenennung
-- (strukturell identische Partition). Der God-Node-Test bleibt UUID-aggregiert:
-- ein generischer MBS-Helper ist in JEDER Datei querschneidend; auf UUID-Ebene
-- erkannt, auf (uuid,file) zurück-ausgeschlossen — verifiziert god-node-set-identisch
-- zur UUID-only-Variante auf klon-freien wie geklonten Korpora.

-- ClusterEdgesBase — bisheriger Cluster-Kantensatz: LogicalLinks minus Builtins,
-- (source,target)-dedupliziert. Builtin-Filter lebt genau HIER (einmal). Führt
-- Source_File/Target_File mit (Klon-Knoten-Key).
--
-- MATERIALISIERT: als reine View-Kette wurde LogicalLinks von
-- ClusterGodNodes/ClusterEdges/Full-Graph-Queries bis ~5× pro Query evaluiert
-- (inkl. Anti-Joins) — das bekannte OOM-Muster der READ_ONLY-API (8 Threads/2 GB,
-- clusteredges-view-double-scan-oom). Die Materialisierung liegt in der TABLE
-- ClusterEdgesBaseMat (klein: 4 UUID-/Datei-Spalten, dedupliziert; bei jedem Batch
-- neu gebaut, volatil wie ClusterNodeUniverse, via Sync in der API-Kopie).
-- ClusterEdgesBase bleibt unter ihrem dokumentierten Namen eine DÜNNE VIEW über
-- der Mat-Tabelle — bewusst NICHT selbst als Tabelle: DuckDBs DROP … IF EXISTS
-- scheitert bei Typ-Mismatch (View↔Table) in BEIDEN Richtungen, eine In-Place-
-- Umwandlung des Namens ist also nicht idempotent skriptbar. Mit neuem Mat-Namen
-- sind alle Zustände sicher: fresh (nichts da), legacy (ClusterEdgesBase=View →
-- CREATE OR REPLACE VIEW ersetzt), steady (View über Mat). GodNodes/ClusterEdges
-- bleiben billige Views; LogicalLinks bleibt View (Explorer/where-used filtern
-- sie stark — Materialisierung brächte dort nichts).
CREATE OR REPLACE TABLE ClusterEdgesBaseMat AS
SELECT DISTINCT Source_UUID, Source_File, Target_UUID, Target_File
FROM LogicalLinks
WHERE Source_UUID NOT IN (SELECT Object_UUID FROM ObjectCatalog WHERE Object_Type = 'BuiltinFunction')
  AND Target_UUID NOT IN (SELECT Object_UUID FROM ObjectCatalog WHERE Object_Type = 'BuiltinFunction');

CREATE OR REPLACE VIEW ClusterEdgesBase AS
SELECT Source_UUID, Source_File, Target_UUID, Target_File FROM ClusterEdgesBaseMat;

-- ClusterGodNodes — querschneidende Knoten (Stufe D-Kriterium, partition-unabhängig).
-- file_spread = #distinkte Dateien unter den Nachbarn; own_file_share = Anteil der
-- Nachbarn in der eigenen Datei (Datei NULL bei Plugin-Nachbarn zählt nicht als
-- "eigene Datei" ⇒ 0). Eigene View (statt inline) → der Ausschluss ist queryfähig
-- (Report kann ihn ehrlich ausweisen). Schwellen 8 / 0.4 aus der Verifikation.
--
-- KLON-ROBUSTHEIT: die Erkennung aggregiert auf UUID-Ebene (GROUP BY a), NICHT
-- auf (uuid,file). Begründung: ein generischer Helper ist datei-übergreifend ein
-- God-Node; auf (uuid,file) zerfiele er in N datei-lokal-harmlose Knoten. Datei kommt
-- jetzt DIREKT von der Kante (a_file/b_file) statt aus einem ObjectCatalog-Join — das
-- vermeidet Klon-Fan-out im Nachbar-Join (mehrere Catalog-Zeilen je geklonter UUID)
-- und ist auf klon-freien Lösungen bit-identisch zur Catalog-Join-Variante. Der
-- Ausschluss in ClusterEdges greift per UUID ⇒ alle (uuid,file)-Instanzen eines
-- God-Nodes fallen raus ("auf (uuid,file) zurück-ausgeschlossen").
CREATE OR REPLACE VIEW ClusterGodNodes AS
WITH und AS (
  SELECT Source_UUID AS a, Source_File AS a_file, Target_File AS b_file FROM ClusterEdgesBase
  UNION ALL
  SELECT Target_UUID AS a, Target_File AS a_file, Source_File AS b_file FROM ClusterEdgesBase
)
SELECT
  a                                            AS Object_UUID,
  COUNT(DISTINCT b_file)                       AS File_Spread,
  SUM(CASE WHEN b_file = a_file THEN 1 ELSE 0 END)::DOUBLE / COUNT(*) AS Own_File_Share
FROM und
GROUP BY a
HAVING COUNT(DISTINCT b_file) >= 8
   AND SUM(CASE WHEN b_file = a_file THEN 1 ELSE 0 END)::DOUBLE / COUNT(*) <= 0.4;

-- ClusterEdges — finaler Cluster-Kantensatz: Base minus God-Nodes. EXAKT die
-- Engine-Eingabe (edges.csv) und die "logische Grad"-Definition der Skill-Hub-Analyse.
-- Führt Source_File/Target_File mit (composite Knoten-Key im Export). Der God-Node-
-- Ausschluss ist per UUID (s. Klon-Robustheit oben).
CREATE OR REPLACE VIEW ClusterEdges AS
SELECT DISTINCT Source_UUID, Source_File, Target_UUID, Target_File
FROM ClusterEdgesBase
WHERE Source_UUID NOT IN (SELECT Object_UUID FROM ClusterGodNodes)
  AND Target_UUID NOT IN (SELECT Object_UUID FROM ClusterGodNodes);

-- ============================================================================
-- ClusterNodeUniverse — aktueller Knotenraum U (Drift-Nenner, jeder Import)
-- ============================================================================
-- Endpunkte der ClusterEdges-View = der AKTUELLE Knotenraum (frisch je Import),
-- gegen den die zwischen zwei Cluster-Läufen veraltende ObjectClusters-Partition
-- gemessen wird (Struktur-/Benennungs-Drift). Materialisiert (Tabelle,
-- nicht View), klein (2 Spalten), via Sync in die Copy mitkopiert.
--
-- OOM-Schutz: Die ClusterEdges-View ist eine teure View-Kette (LogicalLinks →
-- ClusterEdgesBase → ClusterGodNodes → ClusterEdges). Ein naiver UNION über
-- Source-/Target-Endpunkte scannt sie ZWEIMAL → OOM bei 8 Threads/2 GB
-- (clusteredges-view-double-scan-oom). Deshalb GENAU EINE Materialisierung der
-- Kanten (WITH … AS MATERIALIZED) und der billige Knoten-Unnest darüber.
CREATE OR REPLACE TABLE ClusterNodeUniverse AS
WITH edges AS MATERIALIZED (
    SELECT Source_UUID, Source_File, Target_UUID, Target_File FROM ClusterEdges
)
SELECT DISTINCT Object_UUID, File_Name FROM (
    SELECT Source_UUID AS Object_UUID, Source_File AS File_Name FROM edges
    UNION ALL
    SELECT Target_UUID AS Object_UUID, Target_File AS File_Name FROM edges
);
