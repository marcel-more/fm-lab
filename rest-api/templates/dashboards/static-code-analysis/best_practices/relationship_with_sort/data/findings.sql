-- Relationships that sort their related records, extended by consumer
-- context (community pattern, Claris "Top Tips" cloud-performance KB):
-- a relationship-level sort runs for EVERY consumer of the relation, while a
-- portal-level sort costs only where it is displayed. The two consumer
-- columns make the recommendation decidable per row:
--   consumer_portals  = portals whose context is the sorted side's TO
--   portals_own_sort  = of those, portals that carry their own sort anyway
-- A sorted relationship whose portals all sort themselves (or that has no
-- portal consumer at all) pays the relationship sort for nothing visible.
-- Approximation, documented: a portal displaying the sorted TO is counted as
-- consumer regardless of which relationship path its layout context uses.
WITH sorted_rels AS (
    SELECT DISTINCT File_Name, Rel_ID, Rel_UUID, Left_TO_Name, Right_TO_Name,
           Left_Sort_Enabled, Right_Sort_Enabled,
           CASE WHEN Left_Sort_Enabled = 'True' THEN Left_TO_UUID END AS sorted_left_uuid,
           CASE WHEN Right_Sort_Enabled = 'True' THEN Right_TO_UUID END AS sorted_right_uuid
    FROM RelationshipCatalog
    WHERE Left_Sort_Enabled = 'True' OR Right_Sort_Enabled = 'True'
),
portal_ctx AS (
    SELECT ol.Source_UUID AS portal_uuid, ol.Target_UUID AS to_uuid
    FROM ObjectLinks ol
    JOIN ObjectCatalog s ON ol.Source_UUID = s.Object_UUID AND s.Object_Type = 'LayoutObject'
    WHERE ol.Link_Role = 'portal_context'
),
portal_sorted AS (
    SELECT DISTINCT Source_UUID AS portal_uuid FROM ObjectLinks WHERE Link_Role = 'sorts_by_field'
),
consumers AS (
    SELECT sr.File_Name, sr.Rel_ID,
           CAST(count(DISTINCT pc.portal_uuid) AS INTEGER) AS consumer_portals,
           CAST(count(DISTINCT pc.portal_uuid) FILTER (WHERE ps.portal_uuid IS NOT NULL) AS INTEGER) AS portals_own_sort
    FROM sorted_rels sr
    JOIN portal_ctx pc ON pc.to_uuid IN (sr.sorted_left_uuid, sr.sorted_right_uuid)
    LEFT JOIN portal_sorted ps ON ps.portal_uuid = pc.portal_uuid
    GROUP BY 1, 2
),
-- The finding rows. The keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'relationship-with-sort' AS rule_id, 'info' AS severity,
        -- nav_uuid = the relationship's catalog key: its native FileMaker UUID; the
        -- composite rel_<Rel_ID>_<File_Name> only for exports without <UUID>.
        r.File_Name AS file_name, COALESCE(r.Rel_UUID, 'rel_' || r.Rel_ID || '_' || r.File_Name) AS nav_uuid,
        r.Left_TO_Name AS left_to, r.Right_TO_Name AS right_to,
        CASE WHEN r.Left_Sort_Enabled = 'True' AND r.Right_Sort_Enabled = 'True' THEN 'both sides'
             WHEN r.Left_Sort_Enabled = 'True' THEN 'left' ELSE 'right' END AS sorted_side,
        COALESCE(c.consumer_portals, 0) AS consumer_portals,
        COALESCE(c.portals_own_sort, 0) AS portals_own_sort,
        r.File_Name AS _ord_1, r.Left_TO_Name AS _ord_2, r.Rel_ID AS _ord_3
    FROM sorted_rels r
    LEFT JOIN consumers c ON c.File_Name = r.File_Name AND c.Rel_ID = r.Rel_ID
    WHERE (getvariable('file') IS NULL OR r.File_Name = getvariable('file'))
      -- Consumer chips: 'portals' = at least one consumer portal, 'sorted-portals' =
      -- at least one of them sorts itself (the strongest "move the sort to the
      -- portal" candidates). The summary keeps its totals unfiltered.
      AND (getvariable('consumer_filter') IS NULL
           OR (getvariable('consumer_filter') = 'portals' AND COALESCE(c.consumer_portals, 0) > 0)
           OR (getvariable('consumer_filter') = 'sorted-portals' AND COALESCE(c.portals_own_sort, 0) > 0))
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
-- Sorted-side chip: filters the whole result. Its counts (_chip_facets) cover
-- the consumer filter, but neither the search nor the chip itself — the hit
-- count of a search is _row_total.
filtered AS (
    SELECT * FROM searched
    WHERE (getvariable('sorted_side') IS NULL OR sorted_side = getvariable('sorted_side'))
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
    (SELECT to_json(map_from_entries(list((sorted_side, n) ORDER BY sorted_side)))
       FROM (SELECT sorted_side, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
