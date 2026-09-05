-- @title: Logical Edge Export (Community-Detection input)
-- @description: Gesäuberte, ungerichtete Kantenliste (logische Sicht, ohne Builtins/Orphans) → edges.csv
-- @version: 3.0.0
-- @author: Marcel / Claude
-- @tags: graph, cluster, export, P5
-- @note: Input für cluster_louvain.mjs / cluster_leiden.py.
--        Liest weiterhin FROM ClusterEdges, exportiert aber seit 3.0.0 composite
--        Knoten-IDs `uuid::file` (Klon-Knoten-Key, s.u.) statt nackter UUIDs. Ab
--        Stufe C schließt die UPSTREAM-View
--        LogicalLinks lokale Variablen ($x) aus → edges.csv ist bewusst NICHT mehr
--        bit-identisch zu prä-C (einmaliges Re-Baseline der Partition/Farben). Die
--        Bit-Identitäts-Anforderung unten galt nur für den Stufe-B-Refactor (Inline-
--        CTE → View, 1.0.0→2.0.0), nicht über Stufe-C-Inhaltsänderungen hinweg.
--
-- @changelog 3.0.0: Composite Knoten-Key `uuid::file` (Klon-Dubletten). ClusterEdges
--        trägt jetzt Source_File/Target_File; der Export keyt Knoten als
--        `Source_UUID || COALESCE('::' || Source_File, '')` (synthetische NULL-File-
--        Knoten — PluginFunction — bleiben bare `uuid`). EXAKT das Format, das
--        graph_subgraph.sql/graph.service.js bereits verwenden ⇒ ein
--        einheitlicher Knoten-Key über den ganzen Graph-Stack. Bit-Identität bricht
--        bewusst (composite ≠ nackte UUID) → einmaliges Re-Baseline der Partition +
--        Farben (genau wie beim Stufe-C-Re-Baseline). Auf klon-freien Lösungen ist
--        jede UUID datei-eindeutig ⇒ `uuid::file` ist reine Knoten-Umbenennung =
--        strukturell identische Partition (Q/K unverändert), nur Label-Re-Baseline.
--        cluster_load.sql splittet die composite-ID per split_part beim Laden zurück.
--
-- ============================================================================
-- ZWECK
-- ============================================================================
-- Community-Detection (P5) läuft auf dem GESÄUBERTEN Graphen:
--   • operationale Links (keine Containment-Hierarchie),
--   • logische Sicht (Sub-Objekte auf ihren Container hochgezogen),
--   • OHNE Builtins (and/or/Case … sind God-Nodes, die Communities verschmelzen),
--   • OHNE Orphans (beide Endpunkte katalogisiert).
-- Genau dieser Graph ist das, was der Explorer in mode=logical rendert — die
-- Cluster-Färbung ist damit konsistent mit der gezeigten Topologie.
--
-- ============================================================================
-- 2.0.0 — View-Read statt Inline-CTE
-- ============================================================================
-- Der Kantensatz ist ab v2 als VIEW ClusterEdges materialisiert (in convert-xml
-- Phase 5, ingestion/sql/convert_xml_05_homes.sql — dort auch die kanonische
-- LogicalLinks-Definition). ClusterEdges = LogicalLinks minus Builtins, (a,b)-dedupl.
-- Dieselbe View speist auch die Skill-Grad-/Hub-Analyse und perspektivisch den
-- Explorer — EINE Single Source of Truth, keine 3-fach inline duplizierte Logik.
--
-- HARTE ANFORDERUNG: Das edges.csv aus der View ist BIT-IDENTISCH zum vorherigen
-- Inline-Stand (1.0.0). Andernfalls bräche die Determinismus-/Farb-Zusage
-- (gleicher Seed + Auflösung ⇒ identische Partition). ORDER BY source, target
-- bleibt zwingend (v1.2-Determinismus-Fix). Voraussetzung: ClusterEdges existiert
-- (frischer convert-xml --batch erzeugt sie in P5); cluster.sh ruft read-only auf.
--
-- AUSGABE: edges.csv (header: source,target) — eine Zeile je distinkter
-- (Quelle, Ziel)-Paarung. Knoten-IDs sind composite `uuid::file` (NULL-File ⇒ bare
-- `uuid`). Mehrfach-Rollen zwischen demselben Paar werden zu EINER Kante kollabiert
-- (ungewichteter, einfacher Graph; Louvain/Leiden behandeln den ungerichteten
-- Graphen, mergeEdge dedupliziert (a,b)/(b,a)). File_Name enthält kein Komma/`::`
-- (verifiziert) → die naive Louvain-Spaltung am ersten Komma bleibt sicher.
--
-- Pfad: relativ zum CWD des duckdb-Aufrufs (cluster.sh cd't ins Arbeitsverzeichnis).

COPY (
  SELECT DISTINCT
         Source_UUID || COALESCE('::' || Source_File, '') AS source,
         Target_UUID || COALESCE('::' || Target_File, '') AS target
  FROM ClusterEdges
  -- Stabile Zeilenreihenfolge: ohne ORDER BY liefert DuckDB dieselbe DISTINCT-Menge
  -- in wechselnder Reihenfolge (Hash/Parallelität), was Louvain/Leiden — die
  -- ordnungssensitiv sind — zwischen Läufen leicht abweichende Partitionen liefern
  -- lässt. Determinismus („Farben springen nicht"): gleicher Seed +
  -- gleiche Auflösung ⇒ bit-identische edges.csv ⇒ identische Partition.
  ORDER BY source, target
) TO 'edges.csv' (HEADER, DELIMITER ',');
