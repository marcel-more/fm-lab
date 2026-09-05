-- @title: Community signals (R2) — bounded per-segment evidence for name + description
-- @description: One row per selected community: prior names, type histogram, files, dominant
--               folder, bounded lists of scripts / layouts / tables / fields / variables / other,
--               and up to 6 script comments. Anchors by degree come from the shared
--               community_members.sql (this file never scans ClusterEdges).
-- @version: 1.1.0
-- @tags: graph, cluster, community, report
-- @note: read-only. Variables: engine (required) · min_members (default 3) ·
--        max_communities (default 60) · community (-1/unset = all) ·
--        include_formulaic (default false: scaffolding communities — access rights, menu
--        overrides — are skipped; they cost tokens and never yield findings).
--        Lists are trimmed to what a writer actually uses (scripts 8, layouts 6, tables 6,
--        fields 6, variables 4, other 6, comments 4 × 100 chars).
WITH selected AS (
  SELECT Community, Member_Count, Semantic_Name, Semantic_Description, Heuristic_Name,
         Dominant_File, Dominant_Type, Top_Member_Label
  FROM CommunityNames
  WHERE Engine = getvariable('engine')
    AND Member_Count >= COALESCE(getvariable('min_members'), 3)
    AND (COALESCE(getvariable('community'), -1) < 0 OR Community = getvariable('community'))
    AND (COALESCE(getvariable('include_formulaic'), false)
         OR Dominant_Type NOT IN ('PrivilegeSet', 'Account', 'ExtendedPrivilege', 'CustomMenu', 'CustomMenuItem'))
  ORDER BY Member_Count DESC, Community
  LIMIT (COALESCE(getvariable('max_communities'), 60))
),
mem AS (
  SELECT cl.Community, cl.Object_UUID, oc.Object_Type, oc.Object_Name, oc.File_Name
  FROM ObjectClusters cl
  JOIN selected s ON s.Community = cl.Community
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = cl.Object_UUID AND oc.File_Name IS NOT DISTINCT FROM cl.File_Name
  WHERE cl.Engine = getvariable('engine')
),
hist AS (
  SELECT Community, string_agg(Object_Type || '=' || n, ', ' ORDER BY n DESC) AS type_histogram
  FROM (SELECT Community, Object_Type, COUNT(*) AS n FROM mem GROUP BY 1, 2)
  GROUP BY Community
),
folders AS (
  SELECT m.Community, mode(f.Object_Name) AS dominant_folder, COUNT(*) AS foldered
  FROM mem m
  JOIN ObjectLinks ol
    ON ol.Source_UUID = m.Object_UUID AND ol.Source_File IS NOT DISTINCT FROM m.File_Name
   AND ol.Link_Role = 'parent_folder'
  JOIN ObjectCatalog f
    ON f.Object_UUID = ol.Target_UUID AND f.File_Name IS NOT DISTINCT FROM ol.Target_File
  GROUP BY m.Community
),
comments AS (
  SELECT m.Community,
         list_slice(list(left(st.Comment_Text, 100) ORDER BY st.Script_Name, st.Step_Index), 1, 4) AS script_comments
  FROM mem m
  JOIN StepsForScripts st
    ON st.Script_UUID = m.Object_UUID AND st.File_Name IS NOT DISTINCT FROM m.File_Name
  WHERE m.Object_Type = 'Script' AND st.Comment_Text IS NOT NULL AND trim(st.Comment_Text) <> ''
  GROUP BY m.Community
),
lists AS (
  SELECT Community,
         COUNT(DISTINCT File_Name) AS files,
         string_agg(DISTINCT File_Name, ', ') AS file_list,
         list_slice(list(Object_Name ORDER BY Object_Name) FILTER (WHERE Object_Type = 'Script'), 1, 8) AS scripts,
         list_slice(list(Object_Name ORDER BY Object_Name) FILTER (WHERE Object_Type = 'Layout'), 1, 6) AS layouts,
         list_slice(list(Object_Name ORDER BY Object_Name) FILTER (WHERE Object_Type IN ('BaseTable', 'TableOccurrence')), 1, 6) AS tables,
         list_slice(list(Object_Name ORDER BY Object_Name) FILTER (WHERE Object_Type = 'Field'), 1, 6) AS fields,
         list_slice(list(Object_Name ORDER BY Object_Name) FILTER (WHERE Object_Type = 'Variable'), 1, 4) AS variables,
         list_slice(list(Object_Type || ':' || Object_Name ORDER BY Object_Type, Object_Name)
                    FILTER (WHERE Object_Type IN ('CustomFunction', 'PluginFunction', 'ValueList', 'PrivilegeSet',
                                                  'Account', 'Relationship', 'ExtendedPrivilege', 'CustomMenu', 'Theme')), 1, 6) AS other
  FROM mem GROUP BY Community
)
SELECT s.Community, s.Member_Count,
       s.Semantic_Name, s.Semantic_Description, s.Heuristic_Name,
       s.Dominant_File, s.Dominant_Type, s.Top_Member_Label,
       f.dominant_folder, f.foldered,
       h.type_histogram, l.files, l.file_list,
       l.scripts, l.layouts, l.tables, l.fields, l.variables, l.other,
       c.script_comments
FROM selected s
LEFT JOIN hist h     ON h.Community = s.Community
LEFT JOIN folders f  ON f.Community = s.Community
LEFT JOIN lists l    ON l.Community = s.Community
LEFT JOIN comments c ON c.Community = s.Community
ORDER BY s.Member_Count DESC, s.Community;
