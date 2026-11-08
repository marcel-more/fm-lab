-- Who uses the selected object (params obj_uuid + obj_file): one row per USING
-- OBJECT — a layout object or layout part counts as its layout, like the number
-- "Usage" of the list. Row count = Usage (Usage_Owners) of the object; refs = its
-- single places (sum = Usage_Refs). A row opens the using object.
--   Field, Script, Layout, CustomFunction, ValueList, BaseTable,
--   ExternalDataSource, PrivilegeSet: the usage edges of v_object_usage
--   TableOccurrence: v_table_occurrence_usage without the relationship sides (those
--                    decide the class — path analysis in Table Occurrence Usage)
--   Relationship:    no own usage; its two table occurrences and their class
-- Server paging (manifest: details_page / details_q / details_sort → page / q / sort).
WITH
sel AS (
    SELECT Object_UUID, Object_Type, File_Name
    FROM v_object_usage
    WHERE Object_UUID = NULLIF(CAST(getvariable('obj_uuid') AS VARCHAR), '')
      AND File_Name = NULLIF(CAST(getvariable('obj_file') AS VARCHAR), '')
),
-- >>> usage edge definition (keep in sync: CTE edges of v_object_usage in
--     ingestion/sql/create_analysis_views.sql — registry flag, BaseTable override,
--     aggregate edge Layout → Field excluded)
edges AS (
    SELECT ol.Source_UUID, ol.Source_Type, ol.Source_File, ol.Link_Role
    FROM sel s
    JOIN ObjectLinks ol ON ol.Target_UUID = s.Object_UUID AND ol.Target_File = s.File_Name
    LEFT JOIN LinkRoleRegistry r ON r.Link_Role = ol.Link_Role
    WHERE s.Object_Type NOT IN ('TableOccurrence', 'Relationship')
      AND CASE WHEN s.Object_Type = 'BaseTable' THEN ol.Link_Role = 'base_table'
               ELSE COALESCE(r.Counts_For_Where_Used, FALSE) END
      AND NOT (ol.Source_Type = 'Layout' AND ol.Link_Role = 'displays_field'
               AND ol.Link_Subrole IS NULL)
),
-- <<< usage edge definition
owned AS (
    SELECT e.*,
           COALESCE(c.Target_UUID, e.Source_UUID)                      AS Owner_UUID,
           CASE WHEN c.Target_UUID IS NOT NULL THEN 'Layout' ELSE e.Source_Type END AS Owner_Type
    FROM edges e
    LEFT JOIN (
        SELECT pl.Source_UUID, pl.Source_File, any_value(pl.Target_UUID) AS Target_UUID
        FROM ObjectLinks pl
        WHERE pl.Link_Role = 'parent_layout' AND pl.Target_Type = 'Layout'
          AND pl.Source_Type IN ('LayoutObject', 'LayoutPart')
          AND (pl.Source_UUID, pl.Source_File) IN (SELECT (Source_UUID, Source_File) FROM edges)
        GROUP BY ALL
    ) c ON c.Source_UUID = e.Source_UUID AND c.Source_File = e.Source_File
       AND e.Source_Type IN ('LayoutObject', 'LayoutPart')
),
generic AS (
    SELECT o.Owner_Type                       AS owner_type,
           any_value(oc.Object_Name)          AS owner_name,
           o.Source_File                      AS owner_file,
           string_agg(DISTINCT o.Link_Role, ', ' ORDER BY o.Link_Role) AS roles,
           COUNT(*)                           AS refs,
           CAST(NULL AS VARCHAR)              AS usage_class,
           o.Owner_UUID                       AS nav_uuid
    FROM owned o
    LEFT JOIN ObjectCatalog oc ON oc.Object_UUID = o.Owner_UUID AND oc.File_Name = o.Source_File
    GROUP BY o.Owner_Type, o.Owner_UUID, o.Source_File
),
to_owners AS (
    SELECT COALESCE(u.Container_Type, u.User_Type)  AS owner_type,
           any_value(COALESCE(u.Container_Name, u.User_Name)) AS owner_name,
           u.User_File                               AS owner_file,
           string_agg(DISTINCT u.Role, ', ' ORDER BY u.Role) AS roles,
           SUM(u.Ref_Count)                          AS refs,
           CAST(NULL AS VARCHAR)                     AS usage_class,
           COALESCE(u.Container_UUID, u.User_UUID)   AS nav_uuid
    FROM sel s
    JOIN v_table_occurrence_usage u ON u.TO_UUID = s.Object_UUID AND u.File_Name = s.File_Name
    WHERE s.Object_Type = 'TableOccurrence' AND u.Category <> 'relationship'
    GROUP BY 1, 3, 7
),
rel_sides AS (
    SELECT 'TableOccurrence'                     AS owner_type,
           c.TO_Name                             AS owner_name,
           c.File_Name                           AS owner_file,
           side.role                             AS roles,
           CAST(NULL AS BIGINT)                  AS refs,
           CASE
               WHEN c.Usage_Class = 'relationship_bridge' THEN 'bridge'
               WHEN c.Low_Confidence AND c.Usage_Class IN ('unused', 'dead_branch', 'dead_island') THEN c.Usage_Class || '_unverified'
               ELSE c.Usage_Class
           END                                   AS usage_class,
           c.TO_UUID                             AS nav_uuid
    FROM sel s
    JOIN (SELECT DISTINCT Rel_UUID, File_Name, Left_TO_UUID, Right_TO_UUID FROM RelationshipCatalog) r
      ON r.Rel_UUID = s.Object_UUID AND r.File_Name = s.File_Name
    CROSS JOIN LATERAL (VALUES ('left_table', r.Left_TO_UUID), ('right_table', r.Right_TO_UUID)) side(role, to_uuid)
    JOIN v_table_occurrence_class c ON c.TO_UUID = side.to_uuid AND c.File_Name = r.File_Name
    WHERE s.Object_Type = 'Relationship'
),
unkeyed AS MATERIALIZED (
    SELECT g.*, -COALESCE(g.refs, 0) AS _ord_1, g.owner_type AS _ord_2, g.owner_name AS _ord_3
    FROM (SELECT * FROM generic UNION ALL SELECT * FROM to_owners UNION ALL SELECT * FROM rel_sides) g
),
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 100), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
