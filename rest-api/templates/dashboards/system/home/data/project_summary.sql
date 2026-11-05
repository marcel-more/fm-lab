-- @template_type: report
-- @description: Projekt-Header-Kennzahlen aus FilesCatalog und ObjectCatalog.
-- @params: none
--
-- Hinweis zum leeren Zustand:
-- Bei leerer FilesCatalog liefern die Aggregate NULL statt 0/'none'. Der
-- Frontend-Formatter rendert NULL automatisch als "—" — dadurch entsteht
-- der "noch nichts importiert"-Look im Project-overview-KPI-Strip.

WITH meta AS (
    SELECT
        COUNT(*)                                                    AS file_count,
        string_agg(DISTINCT FileMaker_Version, ', '
                   ORDER BY [TRY_CAST(x AS INTEGER) FOR x IN string_split(FileMaker_Version, '.')])
                                                                    AS fm_versions,
        bool_or(Has_DDR_INFO)                                        AS any_ddr,
        bool_and(Has_DDR_INFO)                                       AS all_ddr,
        max(Import_Timestamp)                                        AS last_import
    FROM FilesCatalog
)
SELECT
    NULLIF(file_count, 0)                                             AS file_count,
    fm_versions,
    CASE WHEN file_count = 0  THEN NULL
         WHEN all_ddr         THEN 'full'
         WHEN any_ddr         THEN 'partial'
         ELSE 'none' END                                              AS ddr_status,
    last_import,
    NULLIF((SELECT COUNT(*) FROM ObjectCatalog), 0)                   AS total_objects,
    NULLIF((SELECT COUNT(*) FROM ObjectLinks), 0)                     AS total_links,
    (SELECT string_agg(File_Name, ', ' ORDER BY File_Name)
     FROM FilesCatalog)                                               AS file_names,
    (file_count = 0)                                                  AS db_empty
FROM meta;
