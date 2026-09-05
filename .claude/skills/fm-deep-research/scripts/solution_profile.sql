-- @title: Solution profile (R1) — solution-wide facts for header, business context, architecture
-- @description: Eleven read-only result sets. Variables: engine (required).
-- @version: 1.0.0
-- @tags: solution, profile, report
-- @note: #9 reads ClusterGodNodes (view over LogicalLinks) exactly once; nothing here scans
--        ClusterEdges (anchors/hubs come from the shared community_members.sql / hubs.sql).

-- #1 files — versions and DDR-Info flag (DDR decides whether step text is available)
SELECT File_Name, FileMaker_Version, Has_DDR_INFO FROM FilesCatalog ORDER BY File_Name;

-- #2 object counts per type (LayoutObject / Calculation / ScriptStep are large by design)
SELECT Object_Type, COUNT(*) AS n FROM ObjectCatalog GROUP BY 1 ORDER BY n DESC;

-- #3 data core — base tables with field count and occurrence fan-out (top 25 by fields)
SELECT bt.File_Name, bt.BT_Name,
       (SELECT COUNT(*) FROM FieldsForTables f
         WHERE f.File_Name = bt.File_Name AND f.Table_UUID = bt.BT_UUID)            AS fields,
       (SELECT COUNT(*) FROM TableOccurrenceCatalog t
         WHERE t.File_Name = bt.File_Name AND t.BT_UUID = bt.BT_UUID)               AS occurrences
FROM BaseTableCatalog bt
ORDER BY fields DESC, bt.BT_Name
LIMIT 25;

-- #3b schema totals
SELECT (SELECT COUNT(*) FROM BaseTableCatalog)        AS base_tables,
       (SELECT COUNT(*) FROM TableOccurrenceCatalog)  AS occurrences,
       (SELECT COUNT(*) FROM RelationshipCatalog)     AS relationships,
       (SELECT COUNT(*) FROM FieldsForTables)         AS fields,
       (SELECT COUNT(*) FROM Layouts)                 AS layouts,
       (SELECT COUNT(*) FROM ObjectCatalog WHERE Object_Type = 'Script')          AS scripts,
       (SELECT COUNT(*) FROM ObjectCatalog WHERE Object_Type = 'CustomFunction')  AS custom_functions,
       (SELECT COUNT(*) FROM ObjectCatalog WHERE Object_Type = 'ValueList')       AS value_lists,
       (SELECT COUNT(*) FROM ObjectCatalog WHERE Object_Type = 'ScriptTrigger')   AS script_triggers;

-- #4 external data sources (integration surface)
SELECT File_Name, DS_Name, DS_Type, Path FROM ExternalDataSourceCatalog ORDER BY File_Name, DS_Name;

-- #5 security — privilege sets with account counts; full-access scripts per file
SELECT p.File_Name, p.PrivilegeSet_Name, p.Is_Default_Access,
       (SELECT COUNT(*) FROM AccountsCatalog a
         WHERE a.File_Name = p.File_Name AND a.PrivilegeSet_Name = p.PrivilegeSet_Name) AS accounts
FROM PrivilegeSetsCatalog p
ORDER BY p.File_Name, accounts DESC, p.PrivilegeSet_Name;
SELECT File_Name,
       COUNT(*) AS scripts,
       COUNT(*) FILTER (WHERE CAST(Full_Access AS VARCHAR) IN ('true', 'True', '1')) AS full_access_scripts,
       COUNT(*) FILTER (WHERE CAST(Is_Hidden AS VARCHAR) IN ('true', 'True', '1'))   AS hidden_scripts
FROM ScriptCatalog
GROUP BY File_Name ORDER BY File_Name;

-- #6 plugins — most used plugin functions (integration + platform footprint)
SELECT Plugin_Function_Name, COUNT(*) AS usages,
       COUNT(DISTINCT Source_UUID) AS sources, COUNT(DISTINCT File_Name) AS files
FROM PluginFunctionUsages
GROUP BY 1 ORDER BY usages DESC LIMIT 20;

-- #7 folders — the developers' intended structure (script/layout/CF folders with direct item counts)
WITH items AS (
  SELECT File_Name, Source_Table, Parent_Folder_UUID FROM FolderHierarchy WHERE subtype = 'Item'
),
folders AS (
  SELECT File_Name, Source_Table, Source_UUID, Item_Name, nesting_level
  FROM FolderHierarchy WHERE subtype = 'Folder'
)
SELECT f.File_Name, f.Source_Table, f.nesting_level, f.Item_Name AS folder,
       COUNT(i.Parent_Folder_UUID) AS direct_items
FROM folders f
LEFT JOIN items i ON i.Parent_Folder_UUID = f.Source_UUID AND i.File_Name = f.File_Name
GROUP BY ALL
ORDER BY f.File_Name, f.Source_Table, f.nesting_level, direct_items DESC
LIMIT 60;

-- #8 script triggers per file (UI reactivity)
SELECT File_Name, COUNT(*) AS script_triggers
FROM ObjectCatalog WHERE Object_Type = 'ScriptTrigger'
GROUP BY 1 ORDER BY 2 DESC;

-- #9 cross-cutting nodes removed from the cluster graph (god-node filter)
SELECT DISTINCT oc.Object_Type, oc.Object_Name, oc.File_Name, g.File_Spread, g.Own_File_Share
FROM ClusterGodNodes g
JOIN ObjectCatalog oc ON oc.Object_UUID = g.Object_UUID
ORDER BY g.File_Spread DESC, oc.Object_Name
LIMIT 20;

-- #10 partition shape (engine-scoped)
WITH per AS (
  SELECT Community, COUNT(*) AS n, COUNT(DISTINCT File_Name) AS files
  FROM ObjectClusters WHERE Engine = getvariable('engine') GROUP BY 1
)
SELECT COUNT(*) AS communities, SUM(n) AS nodes, MAX(n) AS largest,
       ROUND(MAX(n) * 1.0 / SUM(n), 3) AS largest_share,
       COUNT(*) FILTER (WHERE n = 1) AS singletons,
       quantile_cont(n, 0.5) AS median_size, ROUND(AVG(n), 1) AS avg_size,
       COUNT(*) FILTER (WHERE files = 1) AS single_file_communities,
       COUNT(*) FILTER (WHERE files >= 2) AS multi_file_communities
FROM per;

-- #11 intended vs. detected modularity — folder members inside their majority community
WITH m AS (
  SELECT f.Object_Name AS folder, f.File_Name, cl.Community
  FROM ObjectClusters cl
  JOIN ObjectLinks ol
    ON ol.Source_UUID = cl.Object_UUID AND ol.Source_File IS NOT DISTINCT FROM cl.File_Name
   AND ol.Link_Role = 'parent_folder'
  JOIN ObjectCatalog f
    ON f.Object_UUID = ol.Target_UUID AND f.File_Name IS NOT DISTINCT FROM ol.Target_File
  WHERE cl.Engine = getvariable('engine')
),
per AS (SELECT folder, File_Name, Community, COUNT(*) AS c FROM m GROUP BY ALL),
top AS (
  SELECT folder, File_Name, SUM(c) AS members, MAX(c) AS in_majority, COUNT(*) AS communities_touched
  FROM per GROUP BY 1, 2
)
SELECT COUNT(*) AS folders, SUM(members) AS foldered_members, SUM(in_majority) AS aligned_members,
       ROUND(SUM(in_majority) * 1.0 / NULLIF(SUM(members), 0), 3) AS alignment,
       COUNT(*) FILTER (WHERE communities_touched >= 3) AS cross_cutting_folders
FROM top;
WITH m AS (
  SELECT f.Object_Name AS folder, f.File_Name, cl.Community
  FROM ObjectClusters cl
  JOIN ObjectLinks ol
    ON ol.Source_UUID = cl.Object_UUID AND ol.Source_File IS NOT DISTINCT FROM cl.File_Name
   AND ol.Link_Role = 'parent_folder'
  JOIN ObjectCatalog f
    ON f.Object_UUID = ol.Target_UUID AND f.File_Name IS NOT DISTINCT FROM ol.Target_File
  WHERE cl.Engine = getvariable('engine')
),
per AS (SELECT folder, File_Name, Community, COUNT(*) AS c FROM m GROUP BY ALL)
SELECT folder, File_Name, SUM(c) AS members, COUNT(*) AS communities_touched,
       ROUND(MAX(c) * 1.0 / SUM(c), 2) AS majority_share
FROM per GROUP BY 1, 2
ORDER BY communities_touched DESC, members DESC
LIMIT 15;
