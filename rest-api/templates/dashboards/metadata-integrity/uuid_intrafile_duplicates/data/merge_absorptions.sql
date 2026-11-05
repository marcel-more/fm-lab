-- @template_type: report
-- @description: Duplicate primary keys absorbed at chunk-merge time (persisted katmerge a2 report). Root cause is not distinguishable at the merge point - either converter-internal chunk overlap (no solution defect) or clone files sharing the same internal file name (a genuine UUID collision).
-- @params: file (optional)
SELECT
    m.Table_Name AS table_name,
    m.File_Name AS file,
    m.Absorbed_Count AS absorbed,
    m.Merge_Path AS merge_path,
    m.Run_Timestamp AS run_at,
    m.Table_Name || ' · ' || COALESCE(m.File_Name, '?') AS row_key
FROM MergeAbsorptions m
CROSS JOIN (SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '') AS file_filter) p
WHERE (p.file_filter IS NULL OR m.File_Name = p.file_filter)
ORDER BY m.Absorbed_Count DESC, m.Table_Name;
