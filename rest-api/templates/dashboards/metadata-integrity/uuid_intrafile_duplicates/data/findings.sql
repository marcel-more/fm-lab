-- @template_type: report
-- @description: UUID-precise occurrences of duplicated UUIDs within single files, captured by the import census (DuplicateAbsorptionDetails). Since UUID healing (schema 1.19.0) the twins are HEALED instead of absorbed: each occurrence exists in the catalog (kept-original under the source UUID, healed under a deterministic replacement UUID in Healed_UUID). Navigation targets the occurrence's own object (for script steps via the containing script with a step anchor); heal_status 'absorbed' marks the remaining collapse cases (double serialization, FM_UUID_HEAL=0 runs, pre-healing DBs).
-- @params: file (optional), limit (optional, default 500)
WITH params AS (
    SELECT NULLIF(CAST(getvariable('file') AS VARCHAR), '') AS file_filter
),
det AS (
    SELECT
        d.File_Name,
        d.Catalog,
        d.Object_UUID,
        d.Object_Name,
        d.Object_Type,
        d.Occurrence_Seq,
        d.Parent_Name,
        d.Position,
        d.Display_Text,
        d.Heal_Status,
        d.Healed_UUID,
        d.Discriminator,
        -- Catalog UUID of THIS occurrence: healed twins live under the replacement
        -- UUID, kept-original under the source UUID (UUID healing, schema 1.19.0)
        COALESCE(d.Healed_UUID, d.Object_UUID) AS catalog_uuid,
        st.Script_UUID AS step_script_uuid,
        st.Script_Name AS step_script_name,
        oc.Object_Type AS survivor_type,
        oc.Object_Name AS survivor_name
    FROM DuplicateAbsorptionDetails d
    LEFT JOIN StepsForScripts st
           ON d.Catalog = 'StepsForScripts'
          AND st.Step_UUID = COALESCE(d.Healed_UUID, d.Object_UUID)
          AND st.File_Name = d.File_Name
    LEFT JOIN ObjectCatalog oc
           ON d.Catalog <> 'StepsForScripts'
          AND oc.Object_UUID = COALESCE(d.Healed_UUID, d.Object_UUID)
          AND oc.File_Name = d.File_Name
    CROSS JOIN params p
    WHERE (p.file_filter IS NULL OR d.File_Name = p.file_filter)
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'uuid-intrafile-duplicate' AS rule_id,
        'warning' AS severity,
        File_Name AS file,
        Catalog AS catalog,
        Object_UUID AS dup_uuid,
        Object_Name AS name,
        Object_Type AS type,
        Occurrence_Seq AS occ,
        Parent_Name AS parent,
        Position AS position,
        Display_Text AS display,
        COALESCE(Heal_Status, 'absorbed') AS heal_status,
        Healed_UUID AS healed_uuid,
        Discriminator AS discriminator,
        COALESCE(step_script_name, survivor_name) AS surviving,
        COALESCE(step_script_uuid, CASE WHEN survivor_type IS NOT NULL THEN catalog_uuid END) AS nav_uuid,
        COALESCE(CASE WHEN step_script_uuid IS NOT NULL THEN 'Script' END, survivor_type) AS nav_type,
        CASE WHEN step_script_uuid IS NOT NULL THEN catalog_uuid END AS step_uuid,
           File_Name AS _ord_1,
           Object_UUID AS _ord_2,
           Occurrence_Seq AS _ord_3
    FROM det
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u._ord_1, u.catalog, u._ord_2, u._ord_3, u) AS row_key
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
