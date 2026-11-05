WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'cascade-delete-relationship' AS rule_id, 'warning' AS severity,
        -- nav_uuid = the relationship's catalog key: its native FileMaker UUID; the
        -- composite rel_<Rel_ID>_<File_Name> only for exports without <UUID>.
        r.File_Name AS file_name, COALESCE(r.Rel_UUID, 'rel_' || r.Rel_ID || '_' || r.File_Name) AS nav_uuid,
        r.Left_TO_Name AS left_to, r.Right_TO_Name AS right_to,
        CASE WHEN r.Left_Delete AND r.Right_Delete THEN 'both sides'
             WHEN r.Left_Delete THEN 'left deletes right' ELSE 'right deletes left' END AS cascade,
           r.File_Name AS _ord_1,
           r.Left_TO_Name AS _ord_2
    FROM (SELECT DISTINCT File_Name, Rel_ID, Rel_UUID, Left_TO_Name, Right_TO_Name, Left_Delete, Right_Delete
          FROM RelationshipCatalog WHERE Left_Delete OR Right_Delete) r
    WHERE (getvariable('file') IS NULL OR r.File_Name = getvariable('file'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u) AS row_key
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
-- Chip filter: narrows the whole result; its counts (_chip_facets) leave out
-- the search and the chip itself.
filtered AS (
    SELECT * FROM searched
    WHERE (getvariable('cascade') IS NULL OR cascade = getvariable('cascade'))
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
    -- Facets ordered by value, so every request returns the same text.
    (SELECT to_json(map_from_entries(list((cascade, n) ORDER BY cascade)))
       FROM (SELECT cascade, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
