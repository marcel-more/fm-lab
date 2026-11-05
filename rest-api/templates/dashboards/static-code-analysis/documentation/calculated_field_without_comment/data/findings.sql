-- The comment filter (getvariable('comment'), default 'without') toggles between
-- calculated fields WITHOUT any comment and those WITH one — a field comment or
-- an inline comment inside the calculation (DDR Comment chunk). Browsing the
-- commented ones is useful as documentation inspiration.
-- Instance base is the CalculationsCatalog field_calculation slot (single
-- source for all calculation slots); FieldsForTables contributes the field
-- comment, DDR_Calculations the chunk-level inline-comment detection.
WITH calc AS (
    SELECT c.File_Name, c.Owner_UUID AS Field_UUID, f.Table_Name, f.Field_Name,
        (COALESCE(f.Field_Comment, '') <> ''
         OR (c.Formula_Hash IS NOT NULL AND EXISTS (
              SELECT 1 FROM DDR_Calculations d
              WHERE d.Calc_Hash = c.Formula_Hash AND d.Chunk_Type = 'Comment'))) AS has_comment
    FROM CalculationsCatalog c
    JOIN FieldsForTables f ON f.Field_UUID = c.Owner_UUID AND f.File_Name = c.File_Name
    WHERE c.Calc_Role = 'field_calculation'
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'calculated-field-without-comment' AS rule_id, 'info' AS severity,
        File_Name AS file_name, Field_UUID AS nav_uuid,
        Table_Name AS table_name, Field_Name AS field_name,
        Table_Name || '::' || Field_Name AS qualified_name
    FROM calc
    WHERE has_comment = (COALESCE(getvariable('comment'), 'without') = 'with')
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.file_name, u.table_name, u.field_name, u) AS row_key
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
