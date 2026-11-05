-- @template_type: report
-- @description: Cross-File-Kopplung aggregiert nach Link-Rolle — welche Art der Kopplung dominiert (displays_field, calls_script, base_table, …). Klick auf eine Rolle filtert die Detailliste.
-- @params: file (optional), limit (optional, default 60)

SELECT
    Link_Role                                       AS link_role,
    MAX(Link_Type)                                  AS link_type,
    COUNT(*)                                         AS links,
    COUNT(DISTINCT (Source_File, Target_File))       AS pairs,
    COUNT(DISTINCT Source_File)                      AS source_files,
    COUNT(DISTINCT Target_File)                      AS target_files
FROM ObjectLinks
WHERE Is_Cross_File = TRUE
  AND Source_File IS NOT NULL AND Target_File IS NOT NULL
  AND Source_File <> Target_File
  AND (getvariable('file') IS NULL
       OR Source_File = getvariable('file')
       OR Target_File = getvariable('file'))
GROUP BY Link_Role
ORDER BY links DESC
LIMIT CAST(COALESCE(getvariable('limit'), '60') AS INTEGER);
