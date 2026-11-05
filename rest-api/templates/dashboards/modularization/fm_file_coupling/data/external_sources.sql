-- @template_type: report
-- @description: Externe FileMaker-Datenquellen — welche Datei bindet welche andere Datei als Datenquelle ein (deklarative Kopplung, unabhängig vom tatsächlichen Objekt-Verkehr). Mit TO-Anzahl und Sample-TO für Navigation.
-- @params: file (optional), limit (optional, default 40)

WITH ds AS (
    SELECT DS_Name, DS_Type, DS_UUID, File_Name
    FROM ExternalDataSourceCatalog
    WHERE DS_Type = 'FileMaker'
      AND (getvariable('file') IS NULL OR File_Name = getvariable('file'))
),
to_per_ds AS (
    SELECT
        ds.DS_Name,
        ds.File_Name,
        COUNT(DISTINCT t.TO_UUID)             AS to_count,
        arg_min(t.TO_UUID, t.TO_Name)         AS sample_to_uuid,
        arg_min(t.TO_Name, t.TO_Name)         AS sample_to_name
    FROM ds
    LEFT JOIN TableOccurrenceCatalog t
      ON (t.DS_UUID = ds.DS_UUID AND t.File_Name = ds.File_Name)
      OR (t.DS_UUID IS NULL AND t.DS_Name = ds.DS_Name AND t.File_Name = ds.File_Name)
    GROUP BY ds.DS_Name, ds.File_Name
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        ds.File_Name                              AS from_file,
        ds.DS_Name                                AS to_source,
        COALESCE(MAX(tpd.to_count), 0)            AS to_count,
        arg_min(tpd.sample_to_uuid, ds.DS_Name)  AS sample_to_uuid,
        arg_min(tpd.sample_to_name, ds.DS_Name)  AS sample_to_name,
           ds.File_Name AS _ord_1,
           ds.DS_Name AS _ord_2
    FROM ds
    LEFT JOIN to_per_ds tpd ON tpd.DS_Name = ds.DS_Name AND tpd.File_Name = ds.File_Name
    GROUP BY ds.File_Name, ds.DS_Name
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2),
           row_number() OVER (ORDER BY u._ord_1, u.to_count DESC, u._ord_2, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 40), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
