-- Hand-maintained COUNT wrapper embedding the findings core of rule (custom_function_many_params).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'custom-function-many-params' AS rule_id, 'info' AS severity,
    cf.File_Name AS file_name, cf.CF_UUID AS nav_uuid, cf.CF_Name AS cf_name,
    len(cf.Parameters) AS param_count,
    len(cf.Parameters) || ' parameters' AS message,
    row_number() OVER (ORDER BY len(cf.Parameters) DESC) AS row_key
FROM CustomFunctionsCatalog cf
WHERE len(cf.Parameters) >= 5
  AND (getvariable('file') IS NULL OR cf.File_Name = getvariable('file'))
ORDER BY param_count DESC
) _summary;
