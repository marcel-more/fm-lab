-- Hand-maintained COUNT wrapper embedding the findings core of rule (base_table_many_occurrences).
-- The core is a textual copy — keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*)                     AS finding_count,
    'info'          AS severity,
    COUNT(DISTINCT file_name)   AS affected_files
FROM (
SELECT 'base-table-many-occurrences' AS rule_id, 'info' AS severity,
    any_value(o.File_Name) AS file_name, to2.BT_UUID AS nav_uuid, any_value(o.Object_Name) AS base_table,
    COUNT(*) AS occurrence_count,
    COUNT(*) || ' occurrences' AS message,
    row_number() OVER (ORDER BY COUNT(*) DESC) AS row_key
FROM TableOccurrenceCatalog to2
JOIN ObjectCatalog o ON o.Object_UUID = to2.BT_UUID AND o.Object_Type = 'BaseTable'
    -- Local occurrences pair with the same-file base table; external ones (DS set)
    -- legitimately point into another file, where the bare UUID is all we have.
    AND (to2.DS_UUID IS NOT NULL OR o.File_Name = to2.File_Name)
WHERE (getvariable('file') IS NULL OR o.File_Name = getvariable('file'))
GROUP BY to2.BT_UUID, o.File_Name
HAVING COUNT(*) > 8
ORDER BY occurrence_count DESC
) _summary;
