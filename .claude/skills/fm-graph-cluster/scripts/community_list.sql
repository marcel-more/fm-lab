-- @title: Final community list (named state)
-- @description: All communities of the engine, largest first — display name, semantic layer, hints.
-- @version: 1.0.0
-- @tags: graph, cluster, report
-- @note: read-only. Name = COALESCE(Semantic_Name, Heuristic_Name) — the Explorer's fallback rule.
-- Variables: engine (required)
SELECT cn.Community,
       COALESCE(cn.Semantic_Name, cn.Heuristic_Name) AS Name,
       cn.Semantic_Name IS NOT NULL                   AS Is_Semantic,
       cn.Semantic_Description,
       cn.Member_Count, cn.Dominant_File, cn.Dominant_Type, cn.Top_Member_Label
FROM CommunityNames cn
WHERE cn.Engine = getvariable('engine')
ORDER BY cn.Member_Count DESC, cn.Community;
