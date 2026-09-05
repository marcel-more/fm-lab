-- @title: Cluster Loader + Heuristic Naming (P5)
-- @description: communities.csv → ObjectClusters; aggregiert CommunityNames (Hints + Heuristik-Name)
-- @version: 2.1.0
-- @author: Marcel / Claude
-- @tags: graph, cluster, P5, community
-- @note: Läuft gegen die Master-DB (read-write).
-- @changelog 2.1.0: Hint-Degree aus edges.csv (logische Cluster-Degree) statt roher ObjectLinks-Degree.
-- @changelog 1.1.0: Semantic_Description fest ins Schema (fm-graph-cluster deep-research).
-- @changelog 2.0.0: Klon-Knoten-Key (Object_UUID, File_Name). communities.csv trägt
--        seit graph_export_logical.sql 3.0.0 composite IDs `uuid::file`; hier per
--        split_part zurück in zwei Spalten zerlegt. ObjectClusters-PK ist jetzt
--        (Object_UUID, File_Name); alle CommunityNames-Joins sind datei-genau, sodass
--        Klone derselben UUID NICHT mehr in der Aggregation verschmelzen.
--
-- ============================================================================
-- VORBEDINGUNG (von cluster.sh gesetzt)
-- ============================================================================
--   SET VARIABLE engine = 'louvain' | 'leiden';   -- Provenienz
--   communities.csv im CWD (Spalten: object_uuid,community) — object_uuid ist der
--   composite Knoten-Key `uuid::file` (NULL-File-Synthetics: bare `uuid`).
--   edges.csv im CWD (Spalten: source,target; derselbe Knoten-Key) — Grad-Basis der Hints.
--
-- ============================================================================
-- ZWEI-TABELLEN-MODELL
-- ============================================================================
--   ObjectClusters(Object_UUID, File_Name, Community, Engine)  — Zugehörigkeit,
--                                            konzeptueller PK (Object_UUID, File_Name)
--   CommunityNames(Community, Engine, …Hints…, Heuristic_Name, Semantic_Name)
-- Trennung, damit der optionale Claude-Skill Semantic_Name unabhängig von der
-- Zugehörigkeit nachpflegen kann (keine LLM-Vorbedingung). Anzeige im Explorer:
-- COALESCE(Semantic_Name, Heuristic_Name).

-- 1) Zugehörigkeit laden. CREATE OR REPLACE = re-runnable; Engine als Provenienz.
--    Composite Knoten-Key `uuid::file` zurück-splitten: split_part am ersten `::`.
--    NULL-File-Synthetics (PluginFunction) tragen kein `::` ⇒ split_part(…,2)='' ⇒
--    NULLIF → File_Name NULL (verträgt sich mit IS NOT DISTINCT FROM unten).
CREATE OR REPLACE TABLE ObjectClusters AS
SELECT
  split_part(object_uuid, '::', 1)               AS Object_UUID,
  NULLIF(split_part(object_uuid, '::', 2), '')   AS File_Name,
  CAST(community AS INTEGER)                      AS Community,
  CAST(getvariable('engine') AS VARCHAR)          AS Engine
FROM read_csv('communities.csv', header = true,
              columns = {'object_uuid': 'VARCHAR', 'community': 'INTEGER'});

-- 2) Operationaler Grad je Objekt (Anker-Wahl + Sample-Reihenfolge).
--    Voll-Aggregation über ObjectLinks — im Batch unkritisch. Datei-genau gekeyt
--    (id, file), damit der Grad einer geklonten UUID nicht über Dateien summiert.
CREATE OR REPLACE TABLE CommunityNames AS
WITH edges AS (
  -- The exact edge set the engine clustered (edges.csv in the CWD, composite
  -- `uuid::file` nodes). Degree on THIS graph ranks the hint columns
  -- (Top_Member_*, Sample_Labels) by logical cluster degree — the raw ObjectLinks
  -- degree over-reports multi-edges / un-hoisted sub-objects by up to ~77× and
  -- surfaced sort/portal artefacts as anchors (v2 hub analysis already fixed the
  -- report side; 2.1.0 aligns the hints). No view scan: edges.csv is materialised.
  SELECT source, target
  FROM read_csv('edges.csv', header = true,
                columns = {'source': 'VARCHAR', 'target': 'VARCHAR'})
),
deg AS (
  SELECT split_part(node, '::', 1)             AS id,
         NULLIF(split_part(node, '::', 2), '') AS file,
         COUNT(*)                              AS degree
  FROM (SELECT source AS node FROM edges UNION ALL SELECT target FROM edges)
  GROUP BY 1, 2
),
members AS (
  SELECT
    cl.Community, cl.Engine,
    oc.Object_UUID, oc.Object_Type, oc.File_Name, oc.Object_Name,
    COALESCE(d.degree, 0) AS degree
  FROM ObjectClusters cl
  -- Datei-genauer Katalog-Join (IS NOT DISTINCT FROM hält NULL-File-Synthetics).
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = cl.Object_UUID
   AND oc.File_Name IS NOT DISTINCT FROM cl.File_Name
  LEFT JOIN deg d
    ON d.id = cl.Object_UUID
   AND d.file IS NOT DISTINCT FROM cl.File_Name
)
SELECT
  Community,
  Engine,
  COUNT(*)                                          AS Member_Count,
  mode(Object_Type)                                 AS Dominant_Type,
  mode(File_Name)                                   AS Dominant_File,
  arg_max(Object_UUID, degree)                      AS Top_Member_UUID,
  arg_max(Object_Name, degree)                      AS Top_Member_Label,
  (list(Object_Name ORDER BY degree DESC, Object_Name))[1:8] AS Sample_Labels,
  -- Heuristik (immer, deterministisch, ohne LLM): Kontext-Datei · Anker (+Rest)
  COALESCE(mode(File_Name), '?') || ' · '
    || COALESCE(arg_max(Object_Name, degree), '(ohne Namen)')
    || ' (+' || (COUNT(*) - 1) || ')'               AS Heuristic_Name,
  -- Semantische Ebene (optional, per UPDATE gefüllt):
  --   Semantic_Name        — kurzer Modulname (Skill fm-graph-cluster)
  --   Semantic_Description  — 1–2 Sätze, was das Modul fachlich tut (Skill fm-deep-research)
  -- Fest im Schema (CREATE OR REPLACE baut sie bei jedem Lauf), damit der Skill
  -- ohne defensiven ALTER auskommt.
  CAST(NULL AS VARCHAR)                              AS Semantic_Name,
  CAST(NULL AS VARCHAR)                              AS Semantic_Description
FROM members
GROUP BY Community, Engine;
