-- @template_type: report
-- @description: One-row KPI summary for the intra-file duplicate dashboard. Since UUID healing (schema 1.19.0) finding_count counts the censused duplicate occurrences (the source defect persists even though the catalog is complete); healed/kept/absorbed break the occurrences down by heal status, absorbed_remaining shows objects still missing from the catalog (v_check_absorbed_dups — 0 after healing).
-- @params: file (optional)
WITH params AS (
    SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '') AS file_filter
)
SELECT
    (SELECT COUNT(*)
       FROM DuplicateAbsorptionDetails d
      WHERE (p.file_filter IS NULL OR d.File_Name = p.file_filter)) AS finding_count,
    (SELECT COUNT(DISTINCT d.File_Name)
       FROM DuplicateAbsorptionDetails d
      WHERE (p.file_filter IS NULL OR d.File_Name = p.file_filter)) AS affected_files,
    (SELECT COUNT(*) FILTER (WHERE d.Heal_Status = 'healed')
       FROM DuplicateAbsorptionDetails d
      WHERE (p.file_filter IS NULL OR d.File_Name = p.file_filter)) AS healed_count,
    (SELECT COUNT(*) FILTER (WHERE d.Heal_Status = 'kept-original')
       FROM DuplicateAbsorptionDetails d
      WHERE (p.file_filter IS NULL OR d.File_Name = p.file_filter)) AS kept_count,
    (SELECT COUNT(*) FILTER (WHERE d.Heal_Status = 'absorbed' OR d.Heal_Status IS NULL)
       FROM DuplicateAbsorptionDetails d
      WHERE (p.file_filter IS NULL OR d.File_Name = p.file_filter)) AS absorbed_count,
    (SELECT COALESCE(SUM(Absorbed), 0)
       FROM v_check_absorbed_dups v
      WHERE (p.file_filter IS NULL OR v.File_Name = p.file_filter)) AS absorbed_remaining,
    (SELECT COALESCE(SUM(m.Absorbed_Count), 0)
       FROM MergeAbsorptions m
      WHERE (p.file_filter IS NULL OR m.File_Name = p.file_filter)) AS merge_absorbed,
    'warning' AS severity
FROM params p;
