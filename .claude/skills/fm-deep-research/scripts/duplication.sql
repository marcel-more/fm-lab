-- @title: Per-file duplication of scripts (R1/R3)
-- @description: Script names that exist in ≥ 2 files, with cross-file call count (0 = copies,
--               not a shared dependency), plus same-UUID clone summary.
-- @version: 1.0.0
-- @tags: graph, cluster, duplication
-- @note: read-only. Same name ≠ same object: the cluster node key is (uuid, file). A name that
--        recurs across files is per-file copies — a maintenance/consistency risk, never a hub.
WITH s AS (
  SELECT Object_UUID, Object_Name, File_Name
  FROM ObjectCatalog WHERE Object_Type = 'Script'
),
dup AS (
  SELECT Object_Name, COUNT(DISTINCT File_Name) AS files,
         list(DISTINCT File_Name ORDER BY File_Name) AS file_list
  FROM s GROUP BY Object_Name
  HAVING COUNT(DISTINCT File_Name) >= 2
),
cross_calls AS (
  SELECT a.Object_Name, COUNT(*) AS cross_file_calls
  FROM ObjectLinks ol
  JOIN s a ON a.Object_UUID = ol.Source_UUID AND a.File_Name IS NOT DISTINCT FROM ol.Source_File
  JOIN s b ON b.Object_UUID = ol.Target_UUID AND b.File_Name IS NOT DISTINCT FROM ol.Target_File
  WHERE ol.Link_Role = 'calls_script' AND a.Object_Name = b.Object_Name AND a.File_Name <> b.File_Name
  GROUP BY a.Object_Name
)
SELECT d.Object_Name, d.files, list_slice(d.file_list, 1, 6) AS sample_files,
       COALESCE(c.cross_file_calls, 0) AS cross_file_calls
FROM dup d LEFT JOIN cross_calls c ON c.Object_Name = d.Object_Name
ORDER BY d.files DESC, d.Object_Name
LIMIT 20;

-- Same-UUID clones (template scaffolds saved into several files)
SELECT Object_Type,
       COUNT(*) FILTER (WHERE files >= 2) AS cloned_uuids,
       MAX(files) AS max_copies
FROM (SELECT Object_Type, Object_UUID, COUNT(DISTINCT File_Name) AS files
      FROM ObjectCatalog WHERE File_Name IS NOT NULL GROUP BY 1, 2)
GROUP BY Object_Type HAVING COUNT(*) FILTER (WHERE files >= 2) > 0
ORDER BY cloned_uuids DESC;
