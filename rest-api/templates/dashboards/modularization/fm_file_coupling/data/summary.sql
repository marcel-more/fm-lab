-- @template_type: report
-- @description: KPI-Übersicht der Modul-Kopplung — Cross-File-Links gesamt, gekoppelte Datei-Paare, Fan-out-Spitze, externe FileMaker-Datenquellen und Datei-Zugriffs-Autorisierungen. Zahlen sind konsistent mit den Detail-Datasets (gleiche Cross-File-Basis).
-- @params: file (optional)

WITH xfile AS (
    SELECT Source_File, Target_File, Link_Role, Link_Type
    FROM ObjectLinks
    WHERE Is_Cross_File = TRUE
      AND Source_File IS NOT NULL AND Target_File IS NOT NULL
      AND Source_File <> Target_File
      AND (getvariable('file') IS NULL
           OR Source_File = getvariable('file')
           OR Target_File = getvariable('file'))
)
SELECT
    (SELECT COUNT(*) FROM xfile)                                      AS total_links,
    (SELECT COUNT(DISTINCT (Source_File, Target_File)) FROM xfile)   AS coupled_pairs,
    (SELECT COUNT(DISTINCT Source_File) FROM xfile)                  AS source_files,
    -- Fan-out-Spitze: höchste Anzahl unterschiedlicher Ziel-Dateien einer Quelle
    (SELECT MAX(cnt) FROM (
        SELECT COUNT(DISTINCT Target_File) AS cnt FROM xfile GROUP BY Source_File
     ))                                                              AS max_fan_out,
    (SELECT COUNT(DISTINCT DS_Name) FROM ExternalDataSourceCatalog
       WHERE DS_Type = 'FileMaker'
         AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
    )                                                               AS external_sources,
    (SELECT COUNT(*) FROM FileAccessAuthorizations
       WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
    )                                                               AS file_authorizations;
