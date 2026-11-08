-- One row: count per usage class (KPI tiles). Source: v_object_usage (analysis
-- table, schema 1.40.0) — the same definition as the search column "Usage
-- (internal)" and the rules of the Analysis Test unused-code.
-- Filters: file (app level), type (comma-separated object types), rare_max.
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
summary_end AS (SELECT 1)
SELECT
    COUNT(*)                                                                    AS total,
    COUNT(*) FILTER (WHERE Usage_Class IN ('used', 'relationship_bridge'))      AS used,
    COUNT(*) FILTER (WHERE view_class = 'rare')                                 AS rare,
    COUNT(*) FILTER (WHERE view_class = 'heavy')                                AS heavy,
    COUNT(*) FILTER (WHERE Usage_Class = 'entry_point')                         AS entry_point,
    COUNT(*) FILTER (WHERE Usage_Class IN ('unused', 'dead_branch', 'dead_island')) AS unused,
    COUNT(*) FILTER (WHERE Low_Confidence)                                      AS low_confidence,
    COALESCE(any_value(_rare_max), 2)                                           AS rare_max
FROM cls;
