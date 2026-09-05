-- @title: Community members — top-K per community by logical cluster degree (shared)
-- @description: Anchors of each selected community, ranked by their degree in ClusterEdges
--               (the exact graph the clustering ran on — never the raw ObjectLinks degree).
-- @version: 1.1.0
-- @tags: graph, cluster, community, shared
-- @note: read-only. Used by fm-graph-cluster (hub/anchor tables) and fm-deep-research (R2 scan).
--
-- Variables (SET VARIABLE … before `.read`; unset = default):
--   engine           VARCHAR   ObjectClusters.Engine ('leiden' | 'louvain')   — required
--   k                INTEGER   members per community                            (default 12)
--   min_members      INTEGER   only communities with Member_Count >= this        (default 3)
--   max_communities  INTEGER   largest communities first                         (default 60)
--   community        INTEGER   restrict to ONE community; -1 or unset = all
--   include_formulaic BOOLEAN  default false: communities whose dominant type is scaffolding
--                              (PrivilegeSet/Account/ExtendedPrivilege, CustomMenu/CustomMenuItem)
--                              are skipped — they never contribute findings, only tokens
--
-- ClusterEdges is an expensive view chain: scan it EXACTLY ONCE (MATERIALIZED). A UNION ALL
-- over the view itself doubles the peak and can OOM at 8 threads / 2 GB.
-- Node key is (Object_UUID, File_Name): clones of one UUID in several files stay distinct;
-- IS NOT DISTINCT FROM keeps NULL-file synthetics (PluginFunction).
WITH edges AS MATERIALIZED (
  SELECT Source_UUID AS s, Source_File AS sf, Target_UUID AS t, Target_File AS tf
  FROM ClusterEdges
),
deg AS MATERIALIZED (
  SELECT uuid, file, COUNT(*) AS degree
  FROM (SELECT s AS uuid, sf AS file FROM edges UNION ALL SELECT t, tf FROM edges)
  GROUP BY uuid, file
),
selected AS (
  SELECT Community, Member_Count
  FROM CommunityNames
  WHERE Engine = getvariable('engine')
    AND Member_Count >= COALESCE(getvariable('min_members'), 3)
    AND (COALESCE(getvariable('community'), -1) < 0 OR Community = getvariable('community'))
    AND (COALESCE(getvariable('include_formulaic'), false)
         OR Dominant_Type NOT IN ('PrivilegeSet', 'Account', 'ExtendedPrivilege', 'CustomMenu', 'CustomMenuItem'))
  ORDER BY Member_Count DESC, Community
  LIMIT (COALESCE(getvariable('max_communities'), 60))
)
SELECT cl.Community, sel.Member_Count, oc.Object_Type, oc.Object_Name, oc.File_Name,
       COALESCE(d.degree, 0) AS degree
FROM ObjectClusters cl
JOIN selected sel ON sel.Community = cl.Community
JOIN ObjectCatalog oc
  ON oc.Object_UUID = cl.Object_UUID AND oc.File_Name IS NOT DISTINCT FROM cl.File_Name
LEFT JOIN deg d
  ON d.uuid = cl.Object_UUID AND d.file IS NOT DISTINCT FROM cl.File_Name
WHERE cl.Engine = getvariable('engine')
QUALIFY ROW_NUMBER() OVER (PARTITION BY cl.Community ORDER BY degree DESC, oc.Object_Name)
        <= COALESCE(getvariable('k'), 12)
ORDER BY sel.Member_Count DESC, cl.Community, degree DESC, oc.Object_Name;
