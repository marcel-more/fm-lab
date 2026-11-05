-- @template_type: report
-- @description: Einzelne Cross-File-Links — pro Zeile ein Quell-Objekt (Datei A) das ein Ziel-Objekt (Datei B) referenziert, mit Rolle. Standardmäßig auf das in der Matrix gewählte Datei-Paar gefiltert. Klick auf eine Zeile öffnet das Ziel-Objekt.
-- @params: file (optional), source_file (optional), target_file (optional), link_role (optional), limit (optional, default 300)
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        ol.Source_File                          AS source_file,
        ol.Target_File                          AS target_file,
        ol.Link_Role                            AS link_role,
        ol.Link_Type                            AS link_type,
        ol.Source_Type                          AS source_type,
        COALESCE(sc.Object_Name, '—')           AS source_object,
        ol.Target_Type                          AS target_type,
        COALESCE(tc.Object_Name, '—')           AS target_object,
        ol.Target_UUID                          AS target_uuid,
           ol.Source_File AS _ord_1,
           ol.Target_File AS _ord_2,
           ol.Link_Role AS _ord_3
    FROM ObjectLinks ol
    LEFT JOIN ObjectCatalog sc ON ol.Source_UUID = sc.Object_UUID AND sc.File_Name = ol.Source_File
    LEFT JOIN ObjectCatalog tc ON ol.Target_UUID = tc.Object_UUID AND tc.File_Name IS NOT DISTINCT FROM ol.Target_File
    WHERE ol.Is_Cross_File = TRUE
      AND ol.Source_File IS NOT NULL AND ol.Target_File IS NOT NULL
      AND ol.Source_File <> ol.Target_File
      AND (getvariable('file') IS NULL
           OR ol.Source_File = getvariable('file')
           OR ol.Target_File = getvariable('file'))
      AND (getvariable('source_file') IS NULL OR getvariable('source_file') IN ('', 'All', 'Alle')
           OR ol.Source_File = getvariable('source_file'))
      AND (getvariable('target_file') IS NULL OR getvariable('target_file') IN ('', 'All', 'Alle')
           OR ol.Target_File = getvariable('target_file'))
      AND (getvariable('link_role') IS NULL OR getvariable('link_role') IN ('', 'All', 'Alle')
           OR ol.Link_Role = getvariable('link_role'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u.source_object, u.target_object, u) AS row_key
    FROM unkeyed u
),
-- >>> shared paging table-search block
haystack AS (
    SELECT *, lower(concat_ws(chr(31),
              *COLUMNS(lambda c: NOT starts_with(c, '_') AND lower(c) NOT IN ('uuid', 'nav_uuid', 'row_key')))) AS _pg_hay
    FROM result
),
searched AS (
    SELECT * EXCLUDE (_pg_hay) FROM haystack
    WHERE NULLIF(CAST(getvariable('q') AS VARCHAR), '') IS NULL
       OR contains(_pg_hay, lower(CAST(getvariable('q') AS VARCHAR)))
),
-- <<< shared paging table-search block
filtered AS (
    SELECT * FROM searched
),
-- >>> shared paging window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 300), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
