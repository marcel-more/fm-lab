-- One row per table occurrence, sorted by usage count (descending), with the usage
-- per category group. Filter: class ('' = all · used · rare · heavy · bridge ·
-- dead_branch · dead_island · unused), ddr ('without' = files without DDR info),
-- file. Server paging (page / q / sort).
-- In a file without DDR info a dead or unused class is unverified (formula
-- references come only from the formula text there) and gets its own code.
-- usage_class is a code (captions: valueLabels in the layout); class_label carries
-- the English caption so the server search finds it.
WITH
-- >>> shared class base (keep in sync: summary.sql, usage.sql)
base AS (
    SELECT c.*,
           COALESCE(TRY_CAST(NULLIF(CAST(getvariable('rare_max') AS VARCHAR), '') AS INTEGER), 3) AS _rare_max
    FROM v_table_occurrence_class c
    WHERE (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
heavy AS (
    -- Heavily used = top 5 % of the used TOs by usage count (within the file filter).
    SELECT COALESCE(quantile_cont(Usage_Ref_Count, 0.95), 0) AS heavy_min
    FROM base WHERE Usage_Class = 'used'
),
cls AS (
    SELECT b.*,
           CASE
               WHEN b.Usage_Class = 'used' AND b.Usage_Ref_Count >= h.heavy_min AND h.heavy_min > 0 THEN 'heavy'
               WHEN b.Usage_Class = 'used' AND b.Usage_Ref_Count <= b._rare_max                    THEN 'rare'
               ELSE b.Usage_Class
           END AS view_class,
           h.heavy_min
    FROM base b, heavy h
),
-- <<< shared class base
cat_counts AS (
    SELECT TO_UUID, File_Name,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category IN ('calculation', 'calculation_text',
                                                               'calc_context')), 0)                        AS calc_refs,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category = 'script_step'), 0)                             AS step_refs,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category IN ('layout_context', 'portal', 'layout_field',
                                                               'table_view', 'layout_part')), 0)           AS layout_refs,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category = 'relationship'), 0)                            AS relationship_refs,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category NOT IN ('calculation', 'calculation_text', 'calc_context', 'script_step',
                                                                   'layout_context', 'portal', 'layout_field',
                                                                   'table_view', 'layout_part', 'relationship')), 0) AS other_refs
    FROM v_table_occurrence_usage
    GROUP BY ALL
),
unkeyed AS MATERIALIZED (
    SELECT
        c.File_Name       AS file_name,
        c.TO_UUID         AS nav_uuid,
        c.TO_Name         AS object_name,
        c.BT_Name         AS base_table,
        CASE
            WHEN c.view_class = 'relationship_bridge' THEN CASE c.Reason WHEN 'cascade_delete' THEN 'bridge_cascade_delete' ELSE 'bridge_path' END
            WHEN c.Low_Confidence AND c.view_class IN ('dead_branch', 'dead_island', 'unused') THEN c.view_class || '_unverified'
            ELSE c.view_class
        END               AS usage_class,
        CASE c.view_class
            WHEN 'heavy'               THEN 'heavily used'
            WHEN 'rare'                THEN 'rarely used'
            WHEN 'used'                THEN 'used'
            WHEN 'relationship_bridge' THEN CASE c.Reason WHEN 'cascade_delete' THEN 'bridge (cascade delete)' ELSE 'bridge (path)' END
            WHEN 'dead_branch'         THEN 'dead branch'
            WHEN 'dead_island'         THEN 'dead island'
            WHEN 'unused'              THEN 'unused'
        END || CASE WHEN c.Low_Confidence AND c.view_class IN ('dead_branch', 'dead_island', 'unused')
                    THEN ' (unverified)' ELSE '' END AS class_label,
        c.Usage_Ref_Count AS usage_refs,
        c.User_Count      AS users,
        COALESCE(k.calc_refs, 0)         AS calc_refs,
        COALESCE(k.step_refs, 0)         AS step_refs,
        COALESCE(k.layout_refs, 0)       AS layout_refs,
        COALESCE(k.relationship_refs, 0) AS relationship_refs,
        COALESCE(k.other_refs, 0)        AS other_refs,
        c.Anchor_TO_Name  AS anchor_to,
        c.Low_Confidence  AS low_confidence,
        -- Current class filter, carried by the row click (the param is click-scoped).
        COALESCE(CAST(getvariable('class') AS VARCHAR), '') AS _class_param,
        -c.Usage_Ref_Count AS _ord_1,
        c.File_Name       AS _ord_2,
        c.TO_Name         AS _ord_3
    FROM cls c
    LEFT JOIN cat_counts k ON k.TO_UUID = c.TO_UUID AND k.File_Name = c.File_Name
    WHERE CASE NULLIF(CAST(getvariable('class') AS VARCHAR), '')
              WHEN 'used'   THEN c.Usage_Class = 'used'
              WHEN 'rare'   THEN c.view_class = 'rare'
              WHEN 'heavy'  THEN c.view_class = 'heavy'
              WHEN 'bridge' THEN c.Usage_Class = 'relationship_bridge'
              WHEN 'dead_branch' THEN c.Usage_Class = 'dead_branch'
              WHEN 'dead_island' THEN c.Usage_Class = 'dead_island'
              WHEN 'unused' THEN c.Usage_Class = 'unused'
              ELSE TRUE
          END
      -- ddr = 'without' keeps the table occurrences of files without DDR info.
      AND (NULLIF(CAST(getvariable('ddr') AS VARCHAR), '') IS DISTINCT FROM 'without'
           OR c.Low_Confidence)
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
