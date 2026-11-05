-- Unstored calculation fields whose formula calls Get(CurrentHostTimestamp)
-- AND that are placed on at least one layout. Claris documents the cost as
-- per-display: each render of the field asks the host for its clock.
--
-- Only the field's own calculation slot is checked — auto-enter and
-- validation formulas evaluate on write, not on render, so the documented
-- per-display cost does not apply to them.
--
-- The match covers the English function name and its German display name
-- (SystemuhrzeitstempelHost); which one the catalog carries depends on the
-- export locale of the file.
WITH hot_fields AS (
    SELECT f.File_Name, f.Field_UUID, f.Table_Name, f.Field_Name
    FROM FieldsForTables f
    WHERE f.Field_Type = 'Calculated'
      AND COALESCE(f.Storage_StoreCalcResults, FALSE) = FALSE
      AND regexp_matches(lower(f.Calculation_Text), 'currenthosttimestamp|systemuhrzeitstempelhost')
),
placements AS (
    SELECT h.File_Name, h.Field_UUID, h.Table_Name, h.Field_Name,
           CAST(count(*) AS INTEGER) AS placement_count,
           CAST(count(*) FILTER (WHERE l.Default_View = 'List') AS INTEGER) AS on_list_layouts,
           CAST(count(DISTINCT l.L_UUID) AS INTEGER) AS layout_count
    FROM hot_fields h
    JOIN ObjectLinks ol ON ol.Target_UUID = h.Field_UUID AND ol.Link_Role = 'displays_field'
    JOIN ObjectCatalog src ON ol.Source_UUID = src.Object_UUID AND src.Object_Type = 'LayoutObject'
    JOIN LayoutObjects lo ON src.Object_UUID = lo.Object_UUID
    JOIN Layouts l ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
    GROUP BY 1, 2, 3, 4
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'unstored-calc-network-function' AS rule_id,
        'warning' AS severity,
        p.File_Name AS file_name,
        p.Field_UUID AS nav_uuid,
        p.Table_Name AS table_name,
        p.Field_Name AS field_name,
        p.layout_count,
        p.placement_count,
        p.on_list_layouts,
        'Unstored calculation calls Get(CurrentHostTimestamp) and is placed ' || p.placement_count
          || ' time(s) on ' || p.layout_count || ' layout(s) — every render asks the host for its clock' AS message,
           p.File_Name AS _ord_1,
           p.Table_Name AS _ord_2,
           p.Field_Name AS _ord_3
    FROM placements p
    WHERE (getvariable('file') IS NULL OR p.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR p.Field_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
