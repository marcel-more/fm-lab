-- Auto-enter calculations that read related fields ('::' syntax). The
-- relationship is traversed on every write of the record — extra network work
-- per commit on remote clients, invisible in the scripts that trigger it.
--
-- '::' inside string literals or formula comments also matches — documented
-- false-positive class, hence severity info. related_ref_count is the raw
-- number of '::' occurrences: a rough size indicator, not a resolved
-- dependency count.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'autoenter-calc-related-fields' AS rule_id,
        'info' AS severity,
        f.File_Name AS file_name,
        f.Field_UUID AS nav_uuid,
        f.Table_Name AS table_name,
        f.Field_Name AS field_name,
        CAST((length(f.AE_Calc_Text) - length(replace(f.AE_Calc_Text, '::', ''))) / 2 AS INTEGER) AS related_ref_count,
        substr(regexp_replace(trim(f.AE_Calc_Text), '\s+', ' ', 'g'), 1, 120) AS formula_start,
        'Auto-enter calculation reads related fields ('
          || CAST((length(f.AE_Calc_Text) - length(replace(f.AE_Calc_Text, '::', ''))) / 2 AS INTEGER)
          || ' reference(s)) — evaluated on every write' AS message,
           f.File_Name AS _ord_1,
           f.Table_Name AS _ord_2,
           f.Field_Name AS _ord_3
    FROM FieldsForTables f
    WHERE f.AE_Calc_Text LIKE '%::%'
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR f.Field_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
