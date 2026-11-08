-- Hand-maintained COUNT wrapper embedding the findings core of rule (unused_table_occurrence).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
-- The view filters of the list (reason, ddr) stay out on purpose: the counts are
-- totals (KPI tiles, defaultResult of the Analysis Tests).
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files,
    COUNT(*) FILTER (WHERE reason = 'unused')                      AS unused_count,
    COUNT(*) FILTER (WHERE reason = 'dead_branch')                 AS dead_branch_count,
    COUNT(*) FILTER (WHERE reason = 'dead_island')                 AS dead_island_count,
    COUNT(*) FILTER (WHERE low_confidence)                         AS low_confidence_count
FROM (
SELECT
    c.File_Name  AS file_name,
    c.Usage_Class AS reason,
    c.Low_Confidence AS low_confidence
FROM v_table_occurrence_class c
WHERE c.Usage_Class IN ('unused', 'dead_branch', 'dead_island')
  AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR c.TO_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
) _summary;
