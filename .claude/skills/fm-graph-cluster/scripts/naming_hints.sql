-- @title: Naming hints for un-named communities (Phase F)
-- @description: Hint columns + dominant script/layout folder per community that still has
--               Semantic_Name IS NULL and Member_Count >= threshold (largest first).
-- @version: 1.0.0
-- @tags: graph, cluster, naming
-- @note: read-only. Cache-restored communities (Semantic_Name set) are skipped on purpose.
--        Folder = mode of the parent_folder targets of the community's scripts/layouts —
--        the developers' *intended* module vocabulary (a naming signal, not a cluster input).
-- Variables: engine (required) · threshold (default 3)
WITH folders AS (
  SELECT cl.Community, f.Object_Name AS Folder_Name
  FROM ObjectClusters cl
  JOIN ObjectLinks ol
    ON ol.Source_UUID = cl.Object_UUID AND ol.Source_File IS NOT DISTINCT FROM cl.File_Name
   AND ol.Link_Role = 'parent_folder'
  JOIN ObjectCatalog f
    ON f.Object_UUID = ol.Target_UUID AND f.File_Name IS NOT DISTINCT FROM ol.Target_File
  WHERE cl.Engine = getvariable('engine')
),
folder_mode AS (
  SELECT Community, mode(Folder_Name) AS Dominant_Folder, COUNT(*) AS Foldered_Members
  FROM folders GROUP BY Community
)
SELECT cn.Community, cn.Member_Count, cn.Dominant_Type, cn.Dominant_File,
       fm.Dominant_Folder, fm.Foldered_Members,
       cn.Top_Member_Label, cn.Sample_Labels, cn.Heuristic_Name
FROM CommunityNames cn
LEFT JOIN folder_mode fm ON fm.Community = cn.Community
WHERE cn.Engine = getvariable('engine')
  AND cn.Member_Count >= COALESCE(getvariable('threshold'), 3)
  AND cn.Semantic_Name IS NULL
ORDER BY cn.Member_Count DESC, cn.Community;
