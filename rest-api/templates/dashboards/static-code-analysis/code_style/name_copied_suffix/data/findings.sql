-- Object names that still carry the suffix FileMaker appends when something is
-- duplicated. Translated from fmCheckMate CopiedNames; the localised suffix
-- list is extensible and currently covers the English and German wording.
--
-- The numeric class (a name ending in a space and one to four digits) is what
-- FileMaker leaves behind on a second duplicate — but it is also how countless
-- deliberate names are built ("Address 2", "Report 2024"). Measured on a large
-- solution it outnumbers the copy suffixes roughly two to one, almost all of it
-- legitimate. It is therefore a separate class the chip bar switches to, and
-- not part of the default finding set.
WITH named AS (
    SELECT Object_UUID, Object_Type, Object_Name, File_Name
    FROM ObjectCatalog
    WHERE Object_Type IN ('Script', 'Field', 'Layout', 'CustomFunction', 'TableOccurrence',
                          'BaseTable', 'ValueList', 'CustomMenu', 'CustomMenuSet',
                          'ExternalDataSource', 'Account', 'PrivilegeSet', 'Folder')
      AND Object_Name IS NOT NULL
),
classified AS (
    SELECT *,
           CASE WHEN Object_Name LIKE '% Copy' OR Object_Name LIKE '% copy' OR Object_Name LIKE '% Kopie'
                THEN 'copy'
                WHEN regexp_matches(Object_Name, ' [0-9]{1,4}$') THEN 'numeric'
           END AS suffix_class
    FROM named
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'name-copied-suffix' AS rule_id, 'info' AS severity,
        c.File_Name AS file_name, c.Object_UUID AS nav_uuid,
        c.Object_Type AS object_type, c.Object_Name AS object_name,
        c.suffix_class,
        CASE WHEN c.suffix_class = 'copy'
             THEN 'Name still carries the suffix FileMaker adds when duplicating'
             ELSE 'Name ends in a number — possibly a duplicate that was never renamed'
        END AS message,
           c.File_Name AS _ord_1,
           c.Object_Type AS _ord_2,
           c.Object_Name AS _ord_3
    FROM classified c
    WHERE c.suffix_class IS NOT NULL
      AND (getvariable('object_type') IS NULL OR c.Object_Type = getvariable('object_type'))
      AND (COALESCE(getvariable('suffix_kind'), 'copy') = 'all'
           OR c.suffix_class = COALESCE(getvariable('suffix_kind'), 'copy'))
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR c.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
