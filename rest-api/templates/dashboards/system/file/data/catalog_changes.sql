-- Change stamps per catalog of the file ("Changes per catalog" card):
--   last_single_change → newest individual developer change of an object in the catalog
--                        (outside mass events, no technical author) + its author
--   catalog_stamp      → the catalog's own stamp; its counter rises with every save of a
--                        child, its timestamp follows a per-catalog rule (e.g. the script
--                        catalog moves on every script action, the layout catalog only on
--                        structural changes)
--   stamped / in_mass  → objects with a stamp / of those inside mass events
--   deleted_hint       → field catalogs only: number of tables whose field catalog is
--                        newer than every field (+1 min tolerance) — a field was deleted
--                        after the last field edit. Not meaningful for other catalogs.
-- Field catalogs exist once per base table; they are aggregated into one row.
WITH obj AS (
    SELECT
        CASE m.Source_Table
            WHEN 'Layouts' THEN 'LayoutCatalog'
            WHEN 'FieldsForTables' THEN 'FieldCatalog'
            WHEN 'FileAccessAuthorizations' THEN 'FileAccessCatalog'
            ELSE m.Source_Table
        END AS Catalog,
        m.Modified_At, m.Author_Key, m.Bulk_Event_ID, m.Author_Kind
    FROM ObjectChangeMeta m
    WHERE m.File_Name = :file
),
obj_agg AS (
    SELECT
        o.Catalog,
        COUNT(*) AS stamped,
        COUNT(*) FILTER (WHERE o.Bulk_Event_ID IS NOT NULL) AS in_mass,
        max(o.Modified_At) FILTER (WHERE o.Bulk_Event_ID IS NULL AND o.Author_Kind IS NULL) AS last_single,
        arg_max(o.Author_Key, o.Modified_At) FILTER (WHERE o.Bulk_Event_ID IS NULL AND o.Author_Kind IS NULL) AS last_single_key
    FROM obj o
    GROUP BY o.Catalog
),
cat_agg AS (
    SELECT
        c.Catalog,
        max(c.Modified_At) AS catalog_stamp,
        CAST(SUM(c.Modifications) AS BIGINT) AS catalog_counter,
        COUNT(*) FILTER (WHERE c.Catalog = 'FieldCatalog'
                           AND c.Modified_At > c.Newest_Child_At + INTERVAL 1 MINUTE) AS deleted_hint
    FROM CatalogChangeMeta c
    WHERE c.File_Name = :file
    GROUP BY c.Catalog
)
SELECT
    COALESCE(ca.Catalog, oa.Catalog) AS catalog,
    strftime(oa.last_single, '%Y-%m-%d %H:%M') AS last_single_change,
    COALESCE(a.Display_Name, oa.last_single_key) AS last_single_author,
    strftime(ca.catalog_stamp, '%Y-%m-%d %H:%M') AS catalog_stamp,
    ca.catalog_counter,
    COALESCE(oa.stamped, 0) AS stamped,
    COALESCE(oa.in_mass, 0) AS in_mass,
    CASE WHEN ca.deleted_hint > 0 THEN ca.deleted_hint END AS deleted_hint
FROM cat_agg ca
FULL JOIN obj_agg oa ON oa.Catalog = ca.Catalog
LEFT JOIN v_change_meta_authors a ON a.Author_Key = oa.last_single_key
ORDER BY COALESCE(oa.last_single, ca.catalog_stamp) DESC NULLS LAST, catalog;
