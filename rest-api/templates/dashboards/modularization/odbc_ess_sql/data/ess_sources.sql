-- @template_type: report
-- @description: ODBC-/ESS-Datenquellen — externe Nicht-FileMaker-Datenquellen (ODBC/ESS). Klick öffnet die alphabetisch erste TableOccurrence der Quelle. (Im Korpus 0 — generische Template-Query.)
-- @params: file (optional), limit (optional, default 40)

WITH ds AS (
    SELECT DS_Name, DS_Type, DS_UUID, File_Name
    FROM ExternalDataSourceCatalog
    WHERE DS_Type <> 'FileMaker'
      AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
)
SELECT
    ds.File_Name                          AS file,
    ds.DS_Name                            AS source_name,
    ds.DS_Type                            AS source_type,
    COUNT(DISTINCT t.TO_UUID)             AS to_count,
    arg_min(t.TO_UUID, t.TO_Name)         AS sample_to_uuid
FROM ds
LEFT JOIN TableOccurrenceCatalog t
  ON t.DS_UUID = ds.DS_UUID AND t.File_Name = ds.File_Name
GROUP BY ds.File_Name, ds.DS_Name, ds.DS_Type
ORDER BY ds.File_Name, to_count DESC, ds.DS_Name
LIMIT CAST(COALESCE(getvariable('limit'), '40') AS INTEGER);
