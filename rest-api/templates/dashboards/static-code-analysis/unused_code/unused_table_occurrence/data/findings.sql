WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
-- Source: v_table_occurrence_class (analysis table, schema 1.38.0) — the one
-- definition of table-occurrence usage (edges plus TO-qualified field references in
-- formulas, script steps and layout fields, contexts, value-list and lookup start
-- TOs) and the path analysis of the relationship graph. A finding is a TO that can
-- be removed: no usage at all, or only relationship sides with no used TO beyond it.
-- Intermediate TOs on a path between two used TOs (join TOs of many-to-many
-- relationships) are never findings.
unkeyed AS MATERIALIZED (
    SELECT
        'unused-table-occurrence'   AS rule_id,
        'info' AS severity,
        c.File_Name  AS file_name,
        c.TO_UUID    AS nav_uuid,
        c.TO_Name    AS object_name,
        c.BT_Name    AS base_table,
        c.Usage_Class AS reason,
        -- Display code of the reason column: in a file without DDR info the finding
        -- is unverified (formula references come only from the formula text there,
        -- evaluation contexts are missing), so it never reads as a plain verdict.
        CASE WHEN c.Low_Confidence THEN c.Usage_Class || '_unverified' ELSE c.Usage_Class END AS reason_status,
        CASE c.Usage_Class
            WHEN 'unused'      THEN 'Not used anywhere (no reference, no relationship)'
            WHEN 'dead_branch' THEN 'Dead branch of the relationship graph (nothing beyond it is used)'
            WHEN 'dead_island' THEN 'Dead island (no TO of its relationship group is used)'
        END || CASE WHEN c.Low_Confidence
                    THEN ' - unverified, the file was exported without DDR info'
                    ELSE '' END AS message,
        c.Anchor_TO_Name  AS anchor_to,
        c.Dead_Group_Size AS branch_size,
        c.Low_Confidence  AS low_confidence,
           c.File_Name AS _ord_1,
           c.TO_Name AS _ord_2
    FROM v_table_occurrence_class c
    WHERE c.Usage_Class IN ('unused', 'dead_branch', 'dead_island')
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR c.TO_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
      -- View filters of the list (KPI tiles, sticky): reason = one class,
      -- ddr = 'without' keeps the findings of files exported without DDR info.
      -- Not part of the summary — its counts stay totals.
      AND (NULLIF(CAST(getvariable('reason') AS VARCHAR), '') IS NULL
           OR c.Usage_Class = NULLIF(CAST(getvariable('reason') AS VARCHAR), ''))
      AND (NULLIF(CAST(getvariable('ddr') AS VARCHAR), '') IS DISTINCT FROM 'without'
           OR c.Low_Confidence)
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u) AS row_key
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
