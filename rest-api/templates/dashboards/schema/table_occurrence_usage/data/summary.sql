-- One row: count per usage class (KPI tiles). Source: v_table_occurrence_class
-- (analysis table, schema 1.38.0). rare / heavy are view classes of 'used'.
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
summary_end AS (SELECT 1)
SELECT
    COUNT(*)                                                         AS total,
    COUNT(*) FILTER (WHERE Usage_Class = 'used')                     AS used,
    COUNT(*) FILTER (WHERE view_class = 'rare')                      AS rare,
    COUNT(*) FILTER (WHERE view_class = 'heavy')                     AS heavy,
    COUNT(*) FILTER (WHERE Usage_Class = 'relationship_bridge')      AS bridge,
    COUNT(*) FILTER (WHERE Usage_Class = 'dead_branch')              AS dead_branch,
    COUNT(*) FILTER (WHERE Usage_Class = 'dead_island')              AS dead_island,
    COUNT(*) FILTER (WHERE Usage_Class = 'unused')                   AS unused,
    COUNT(*) FILTER (WHERE Low_Confidence)                           AS low_confidence,
    any_value(_rare_max)                                             AS rare_max,
    CAST(ceil(any_value(heavy_min)) AS BIGINT)                       AS heavy_min
FROM cls;
