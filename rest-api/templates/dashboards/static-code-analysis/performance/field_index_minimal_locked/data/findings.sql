-- Fields whose index is set to Minimal while automatic indexing is still on.
-- Minimal keeps only the word index and drops the value index, but with
-- automatic indexing enabled FileMaker rebuilds whatever a find needs anyway —
-- so the setting saves nothing predictable and mostly documents an index that
-- was cleared once and never reconsidered. Translated from fmCheckMate
-- IndexMinimalLocked.
--
-- The index setting itself is not a result column: the WHERE clause pins it
-- to 'Minimal', so it would repeat the rule's name in every row.
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'field-index-minimal-locked' AS rule_id, 'info' AS severity,
        f.File_Name AS file_name, f.Field_UUID AS nav_uuid,
        f.Table_Name AS table_name, f.Field_Name AS field_name,
        f.Field_Type AS field_type, f.Data_Type AS data_type,
        'Index is Minimal while automatic indexing is on' AS message,
           f.File_Name AS _ord_1,
           f.Table_Name AS _ord_2,
           f.Field_Name AS _ord_3
    FROM FieldsForTables f
    WHERE f.Storage_Index = 'Minimal' AND f.Storage_AutoIndex
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
