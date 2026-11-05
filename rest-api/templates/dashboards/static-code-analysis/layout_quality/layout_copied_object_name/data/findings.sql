-- Named layout objects with a copy suffix (' Copy', ' copy', ' Kopie'), a
-- numeric paste suffix (1-4 trailing digits), or a name shared with another
-- object on the same layout. FileMaker renames on paste, so the suffix check
-- is the operative duplicate detector; the duplicate clause is a cheap safety
-- net. Numeric suffixes can be deliberate naming — flagged for review, see
-- the rule description. Translated from fmCheckMate ReportCopiedObjectNames.
-- The reason chips (getvariable('reason')) and the object-type select
-- (getvariable('object_type')) narrow the result server-side — unset means
-- no filter. DuckDB resolves the reason SELECT alias in WHERE.
WITH named AS (
    SELECT File_Name, Layout_ID, Object_UUID, Object_Type, Object_Name, Part_Type,
           Bounds_Left, Bounds_Top, Bounds_Right, Bounds_Bottom
    FROM LayoutObjects
    WHERE Object_Name IS NOT NULL AND trim(Object_Name) <> ''
),
dups AS (
    SELECT File_Name, Layout_ID, Object_Name
    FROM named
    GROUP BY ALL
    HAVING COUNT(*) > 1
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'layout-copied-object-name' AS rule_id, 'warning' AS severity,
        n.File_Name AS file_name, l.L_UUID AS nav_uuid, l.L_Name AS layout_name,
        n.Object_UUID AS object_uuid, n.Object_Type AS object_type, n.Object_Name AS object_name,
        n.Part_Type AS part_type,
        CASE WHEN n.Object_Name LIKE '% Copy' OR n.Object_Name LIKE '% copy' OR n.Object_Name LIKE '% Kopie'
             THEN 'copy-suffix'
             WHEN d.Object_Name IS NOT NULL THEN 'duplicate-name'
             ELSE 'numeric-suffix' END AS reason,
        n.Bounds_Left AS x, n.Bounds_Top AS y, (n.Bounds_Right - n.Bounds_Left) AS w, (n.Bounds_Bottom - n.Bounds_Top) AS h,
        CASE WHEN n.Object_Name LIKE '% Copy' OR n.Object_Name LIKE '% copy' OR n.Object_Name LIKE '% Kopie'
             THEN 'Object name carries a copy suffix — probably a paste leftover'
             WHEN d.Object_Name IS NOT NULL
             THEN 'Object name appears more than once on this layout'
             ELSE 'Object name ends in a numeric suffix — possibly a paste leftover, possibly deliberate naming'
        END AS message,
           n.File_Name AS _ord_1,
           l.L_Name AS _ord_2,
           n.Object_Name AS _ord_3,
           n.Object_UUID AS _ord_4
    FROM named n
    JOIN Layouts l ON n.Layout_ID = l.L_ID AND n.File_Name = l.File_Name
    LEFT JOIN dups d ON d.File_Name = n.File_Name AND d.Layout_ID = n.Layout_ID
     AND d.Object_Name = n.Object_Name
    WHERE (n.Object_Name LIKE '% Copy' OR n.Object_Name LIKE '% copy' OR n.Object_Name LIKE '% Kopie'
           OR regexp_matches(n.Object_Name, ' \d{1,4}$')
           OR d.Object_Name IS NOT NULL)
      AND (getvariable('reason') IS NULL OR reason = getvariable('reason'))
      AND (getvariable('object_type') IS NULL OR n.Object_Type = getvariable('object_type'))
      AND (getvariable('file') IS NULL OR n.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR l.L_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u) AS row_key
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
