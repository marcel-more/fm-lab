-- Hand-maintained COUNT wrapper embedding the findings core of rule (unused_custom_function).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
-- The view filter of the list (ddr) stays out on purpose: the counts are totals
-- (KPI tiles, defaultResult of the Analysis Tests).
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files,
    COUNT(*) FILTER (WHERE low_confidence) AS low_confidence_count
FROM (
SELECT
    oc.File_Name  AS file_name,
    oc.Low_Confidence AS low_confidence
FROM v_object_usage oc
WHERE oc.Object_Type = 'CustomFunction'
  AND oc.Usage_Class = 'unused'
  AND (getvariable('file') IS NULL OR oc.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR oc.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
) _summary;
