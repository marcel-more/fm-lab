-- @template_type: report
-- @description: Plugin-Abhängigkeit je Komponente — Call-Sites, verschiedene Funktionen und betroffene Dateien pro MBS-Komponente (bzw. sonstigem Plugin). Zeigt, welche Module ohne Plugin tot wären. Klick auf eine Zeile filtert die Funktions-Liste.
-- @params: file (optional), limit (optional, default 100)

WITH calls AS (
    SELECT
        src.File_Name                                             AS file,
        CASE WHEN tc.Object_Name LIKE 'MBS:%' THEN 'MBS' ELSE 'Other' END AS plugin,
        CASE WHEN tc.Object_Name LIKE 'MBS:%'
             THEN regexp_extract(tc.Object_Name, '(?i)MBS:([A-Za-z]+)\.', 1)
             ELSE 'Other' END                                     AS component,
        tc.Object_Name                                            AS fn
    FROM ObjectLinks ol
    JOIN ObjectCatalog tc ON ol.Target_UUID = tc.Object_UUID AND tc.File_Name IS NOT DISTINCT FROM ol.Target_File
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID AND src.File_Name = ol.Source_File
    WHERE ol.Link_Role = 'calls_pluginfunction'
      AND (getvariable('file') IS NULL OR src.File_Name = getvariable('file'))
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        plugin,
        component,
        COUNT(*)                          AS callsites,
        COUNT(DISTINCT fn)                AS functions,
        COUNT(DISTINCT file)             AS files
    FROM calls
    GROUP BY plugin, component
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.callsites DESC, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 100), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
