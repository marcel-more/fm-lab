-- @template_type: report
-- @description: Kopplungs-Matrix — eine Zeile je gerichtetem Datei-Paar (Quelle → Ziel) mit Link-Anzahl, Anzahl verschiedener Rollen und operational/structural-Aufteilung. Klick auf eine Zeile filtert die Detailliste auf dieses Paar.
-- @params: file (optional), limit (optional, default 300)
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        Source_File                                             AS source_file,
        Target_File                                             AS target_file,
        COUNT(*)                                                AS links,
        COUNT(DISTINCT Link_Role)                               AS roles,
        -- kompakte Rollen-Vorschau (erste vier Rollen des Paars, alphabetisch).
        -- list_slice statt Slice-Syntax mit Doppelpunkt: der API-SQL-Präprozessor
        -- deutet den Doppelpunkt-Index sonst als benannten Parameter und ersetzt ihn.
        array_to_string(
            list_slice(list(DISTINCT Link_Role ORDER BY Link_Role), 1, 4), ', '
        )                                                       AS sample_roles
    FROM ObjectLinks
    WHERE Is_Cross_File = TRUE
      AND Source_File IS NOT NULL AND Target_File IS NOT NULL
      AND Source_File <> Target_File
      AND (getvariable('file') IS NULL
           OR Source_File = getvariable('file')
           OR Target_File = getvariable('file'))
    GROUP BY Source_File, Target_File
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.links DESC, u.source_file, u.target_file, u) AS row_key
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
