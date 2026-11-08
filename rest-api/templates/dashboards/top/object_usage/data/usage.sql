-- One row per object, sorted by usage ascending (unused and rarely used first).
-- "Usage" = using objects (Usage_Owners: a layout object or layout part counts as
-- its layout) — the number of the search column "Usage (internal)"; references =
-- every single place (Usage_Refs). Filters: class ('' = all · used · rare · heavy ·
-- entry_point · unused), ddr ('without' = files without DDR info), type, file.
-- Server paging (page / q / sort). usage_class is a code (captions: valueLabels in
-- the layout); class_label carries the English caption so the server search finds it.
-- Without DDR info an unused or dead class is unverified and gets its own code.
WITH
-- >>> shared class base (keep in sync: summary.sql, usage.sql)
base AS (
    SELECT u.*,
           COALESCE(TRY_CAST(NULLIF(CAST(getvariable('rare_max') AS VARCHAR), '') AS INTEGER), 2) AS _rare_max
    FROM v_object_usage u
    WHERE (getvariable('file') IS NULL OR u.File_Name = getvariable('file'))
      AND (NULLIF(CAST(getvariable('type') AS VARCHAR), '') IS NULL
           OR list_contains(string_split(CAST(getvariable('type') AS VARCHAR), ','), u.Object_Type))
),
heavy AS (
    -- Heavily used = top 5 % of the used objects OF THE SAME TYPE by using objects
    -- (a field and a script live on different scales).
    SELECT Object_Type, COALESCE(quantile_cont(Usage_Owners, 0.95), 0) AS heavy_min
    FROM base
    WHERE Usage_Class = 'used' AND Usage_Owners IS NOT NULL
    GROUP BY Object_Type
),
cls AS (
    -- rare / heavy are views of 'used'; heavy only above the rare threshold, so the
    -- two never overlap. Relationships carry no count and stay 'used'.
    SELECT b.*,
           CASE
               WHEN b.Usage_Class = 'used' AND b.Usage_Owners >= h.heavy_min AND h.heavy_min > b._rare_max THEN 'heavy'
               WHEN b.Usage_Class = 'used' AND b.Usage_Owners <= b._rare_max                            THEN 'rare'
               ELSE b.Usage_Class
           END AS view_class,
           h.heavy_min
    FROM base b
    LEFT JOIN heavy h ON h.Object_Type = b.Object_Type
),
-- <<< shared class base
unkeyed AS MATERIALIZED (
    SELECT
        c.File_Name       AS file_name,
        c.Object_UUID     AS nav_uuid,
        c.Object_Type     AS object_type,
        c.Object_Name     AS object_name,
        CASE
            WHEN c.view_class = 'relationship_bridge' THEN 'bridge'
            WHEN c.Low_Confidence AND c.view_class IN ('unused', 'dead_branch', 'dead_island') THEN c.view_class || '_unverified'
            ELSE c.view_class
        END               AS usage_class,
        CASE c.view_class
            WHEN 'heavy'               THEN 'heavily used'
            WHEN 'rare'                THEN 'rarely used'
            WHEN 'used'                THEN 'used'
            WHEN 'relationship_bridge' THEN 'bridge'
            WHEN 'entry_point'         THEN 'entry point'
            WHEN 'builtin'             THEN 'built-in'
            WHEN 'dead_branch'         THEN 'dead branch'
            WHEN 'dead_island'         THEN 'dead island'
            WHEN 'unused'              THEN 'unused'
        END || CASE WHEN c.Low_Confidence AND c.view_class IN ('unused', 'dead_branch', 'dead_island')
                    THEN ' (unverified)' ELSE '' END AS class_label,
        c.Usage_Owners    AS usage,
        c.Usage_Refs      AS refs,
        c.Usage_Files     AS files,
        array_to_string(c.Usage_Roles, ', ') AS roles,
        CASE WHEN c.Entry_Point    THEN TRUE END AS in_menu,
        CASE WHEN c.Key_Field      THEN TRUE END AS key_field,
        CASE WHEN c.Cross_File     THEN TRUE END AS cross_file,
        CASE WHEN c.Low_Confidence THEN TRUE END AS low_confidence,
        -- Current class filter, carried by the row click (the param is click-scoped).
        COALESCE(CAST(getvariable('class') AS VARCHAR), '') AS _class_param,
        COALESCE(c.Usage_Owners, 2147483647) AS _ord_1,
        c.Object_Type     AS _ord_2,
        c.Object_Name     AS _ord_3,
        c.File_Name       AS _ord_4
    FROM cls c
    WHERE CASE NULLIF(CAST(getvariable('class') AS VARCHAR), '')
              WHEN 'used'        THEN c.Usage_Class IN ('used', 'relationship_bridge')
              WHEN 'rare'        THEN c.view_class = 'rare'
              WHEN 'heavy'       THEN c.view_class = 'heavy'
              WHEN 'entry_point' THEN c.Usage_Class = 'entry_point'
              WHEN 'unused'      THEN c.Usage_Class IN ('unused', 'dead_branch', 'dead_island')
              ELSE TRUE
          END
      -- ddr = 'without' keeps the objects of files without DDR info.
      AND (NULLIF(CAST(getvariable('ddr') AS VARCHAR), '') IS DISTINCT FROM 'without'
           OR c.Low_Confidence)
),
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 100), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
