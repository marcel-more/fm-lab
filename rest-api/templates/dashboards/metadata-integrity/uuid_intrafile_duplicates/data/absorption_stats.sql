-- @template_type: report
-- @description: Consistency cross-check per catalog and file - absorbed duplicates from the import census (source records minus stored rows) versus the UUID-precise detail rows. "consistent" means every absorbed duplicate is covered by detail rows; "counter-only" marks catalogs where only the counter exists.
-- @params: file (optional)
WITH det AS (
    SELECT Catalog, File_Name,
           COUNT(*) AS detail_rows,
           COUNT(DISTINCT Object_UUID) AS dup_uuids
    FROM DuplicateAbsorptionDetails
    GROUP BY 1, 2
)
SELECT
    v.Catalog AS catalog,
    v.File_Name AS file,
    v.Source_Records AS source_records,
    v.Stored_Rows AS stored_rows,
    v.Absorbed AS absorbed,
    COALESCE(det.detail_rows, 0) AS detail_rows,
    COALESCE(det.dup_uuids, 0) AS dup_uuids,
    CASE
        WHEN det.detail_rows IS NULL THEN 'counter-only'
        WHEN det.detail_rows - det.dup_uuids = v.Absorbed THEN 'consistent'
        ELSE 'partial'
    END AS coverage,
    v.Catalog || ' · ' || v.File_Name AS row_key
FROM v_check_absorbed_dups v
LEFT JOIN det ON det.Catalog = v.Catalog AND det.File_Name = v.File_Name
CROSS JOIN (SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '') AS file_filter) p
WHERE (p.file_filter IS NULL OR v.File_Name = p.file_filter)
ORDER BY v.Absorbed DESC, v.Catalog, v.File_Name;
