-- Object names beyond a readable length, and names sitting exactly on
-- FileMaker's 100-character ceiling. Translated from fmCheckMate NamesTooLong —
-- but recalibrated: the source's fixed limit is not a useful detector here,
-- because FileMaker enforces the 100-character ceiling itself, so a name can
-- never exceed it. What is worth reporting instead is a configurable
-- readability threshold (max_len, default 80) plus the names that landed
-- exactly on 100 characters, which is where FileMaker silently truncated what
-- the developer typed.
WITH named AS (
    SELECT Object_UUID, Object_Type, Object_Name, File_Name, length(Object_Name) AS name_length
    FROM ObjectCatalog
    WHERE Object_Type IN ('Script', 'Field', 'Layout', 'CustomFunction', 'TableOccurrence',
                          'BaseTable', 'ValueList', 'CustomMenu', 'CustomMenuSet',
                          'ExternalDataSource', 'Account', 'PrivilegeSet', 'Folder')
      AND Object_Name IS NOT NULL
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'name-too-long' AS rule_id,
        CASE WHEN n.name_length >= 100 THEN 'warning' ELSE 'info' END AS severity,
        n.File_Name AS file_name, n.Object_UUID AS nav_uuid,
        n.Object_Type AS object_type, n.Object_Name AS object_name,
        n.name_length,
        CASE WHEN n.name_length >= 100 THEN 'at-limit' ELSE 'too-long' END AS defect,
        CASE WHEN n.name_length >= 100
             THEN 'Name is at FileMaker''s 100-character ceiling and may have been truncated'
             ELSE 'Name is longer than ' || CAST(COALESCE(getvariable('max_len'), '80') AS INTEGER) || ' characters'
        END AS message,
           n.name_length AS _ord_1,
           n.File_Name AS _ord_2,
           n.Object_Name AS _ord_3
    FROM named n
    WHERE n.name_length > CAST(COALESCE(getvariable('max_len'), '80') AS INTEGER)
      AND (getvariable('object_type') IS NULL OR n.Object_Type = getvariable('object_type'))
      AND (getvariable('defect') IS NULL
           OR (CASE WHEN n.name_length >= 100 THEN 'at-limit' ELSE 'too-long' END) = getvariable('defect'))
      AND (getvariable('file') IS NULL OR n.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR n.Object_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1 DESC, u._ord_2, u._ord_3, u) AS row_key
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
