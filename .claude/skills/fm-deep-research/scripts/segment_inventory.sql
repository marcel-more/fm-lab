-- @title: Segment inventory for Appendix B — semantic segments + long-tail aggregate
-- @description: Replaces the former "complete community list". Result set 1 lists only the
--               segments that carry meaning (Semantic_Name set — user names come from the
--               sidecar/REST and are merged by the writer); result set 2 folds the long tail
--               (heuristic-only segments) into one aggregate per dominant type, so nothing is
--               silently dropped but the noise (per-file menu pairs, privilege scaffolds) never
--               fills pages. The complete list stays in the cluster overview (/cluster).
-- @version: 1.1.0
-- @tags: graph, cluster, report
-- @note: read-only. Variables: engine (required).

-- #1 semantic, non-formulaic segments, largest first — the rows worth reading
SELECT Community, Semantic_Name AS Name, Member_Count, Dominant_File, Dominant_Type,
       Semantic_Description IS NOT NULL AS Described
FROM CommunityNames
WHERE Engine = getvariable('engine') AND Semantic_Name IS NOT NULL
  AND Dominant_Type NOT IN ('PrivilegeSet', 'Account', 'ExtendedPrivilege', 'CustomMenu', 'CustomMenuItem')
ORDER BY Member_Count DESC, Community;

-- #2 everything else folded: formulaic (rule-named or not) and heuristic-only, per dominant type
SELECT CASE WHEN Semantic_Name IS NOT NULL THEN 'named (formulaic)' ELSE 'heuristic' END AS layer,
       Dominant_Type, COUNT(*) AS segments, SUM(Member_Count) AS members,
       MIN(Member_Count) AS min_size, MAX(Member_Count) AS max_size,
       COUNT(DISTINCT Dominant_File) AS files
FROM CommunityNames
WHERE Engine = getvariable('engine')
  AND (Semantic_Name IS NULL
       OR Dominant_Type IN ('PrivilegeSet', 'Account', 'ExtendedPrivilege', 'CustomMenu', 'CustomMenuItem'))
GROUP BY layer, Dominant_Type
ORDER BY layer, segments DESC;

-- #3 totals for the one-line summary
SELECT COUNT(*) AS segments_total,
       COUNT(*) FILTER (WHERE Semantic_Name IS NOT NULL) AS semantic_segments,
       SUM(Member_Count) FILTER (WHERE Semantic_Name IS NOT NULL) AS semantic_members,
       SUM(Member_Count) AS members_total,
       ROUND(SUM(Member_Count) FILTER (WHERE Semantic_Name IS NOT NULL) * 1.0 / NULLIF(SUM(Member_Count), 0), 3) AS semantic_member_share
FROM CommunityNames
WHERE Engine = getvariable('engine');
