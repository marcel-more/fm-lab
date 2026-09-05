-- @title: Hubs / god-nodes by logical cluster degree
-- @description: Top-N nodes of the clustered graph (ClusterEdges), with their community.
-- @version: 1.0.0
-- @tags: graph, cluster, hubs
-- @note: read-only. Degree = logical cluster degree (v2) — NOT the raw ObjectLinks degree
--        (multi-edges/un-hoisted sub-objects over-report by up to ~77×). Builtins and
--        Calculation instances never appear (excluded from ClusterEdges by design).
-- Variables: engine (required) · limit (default 20)
-- ClusterEdges scanned exactly once (MATERIALIZED); node key (uuid, file) — clones stay distinct.
WITH edges AS MATERIALIZED (
  SELECT Source_UUID AS s, Source_File AS sf, Target_UUID AS t, Target_File AS tf FROM ClusterEdges
),
logical_degree AS MATERIALIZED (
  SELECT uuid, file, COUNT(*) AS degree
  FROM (SELECT s AS uuid, sf AS file FROM edges UNION ALL SELECT t, tf FROM edges)
  GROUP BY uuid, file
)
SELECT oc.Object_Type, oc.Object_Name, oc.File_Name, d.degree, cl.Community,
       COALESCE(cn.Semantic_Name, cn.Heuristic_Name) AS Community_Name
FROM logical_degree d
JOIN ObjectCatalog oc
  ON oc.Object_UUID = d.uuid AND oc.File_Name IS NOT DISTINCT FROM d.file
LEFT JOIN ObjectClusters cl
  ON cl.Object_UUID = d.uuid AND cl.File_Name IS NOT DISTINCT FROM d.file
 AND cl.Engine = getvariable('engine')
LEFT JOIN CommunityNames cn
  ON cn.Community = cl.Community AND cn.Engine = cl.Engine
ORDER BY d.degree DESC, oc.Object_Name
LIMIT (COALESCE(getvariable('limit'), 20));
