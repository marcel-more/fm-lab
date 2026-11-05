-- Enabled Refresh Window steps that flush the join cache (option id 256) or
-- the external-data cache (option id 512). Claris documents the cost: the
-- flush discards cached related records, so every subsequent display of
-- related data re-fetches from the server.
--
-- The options are matched by their NUMERIC ids. The type attribute of the
-- Boolean parameter is localized with the export language (German files carry
-- "Join-Ergebnisse im Cache löschen") — a text match silently loses those
-- findings. Measured on the calibration corpus: 88 id-based vs. 81 with an
-- English text match.
--
-- Loop context via v_script_block_tree: a flush inside a loop repeats the
-- cache invalidation per iteration and weighs heavier.
WITH flushes AS (
    SELECT File_Name, Script_UUID, Script_Name, Step_Index, Step_UUID,
           regexp_matches(Step_XML, 'id="256" value="True"')  AS flush_join,
           regexp_matches(Step_XML, 'id="512" value="True"')  AS flush_external
    FROM StepsForScripts
    WHERE Step_ID = 80 AND Is_Enabled
      AND (regexp_matches(Step_XML, 'id="256" value="True"')
           OR regexp_matches(Step_XML, 'id="512" value="True"'))
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'refresh-window-flush-cache' AS rule_id,
        'warning' AS severity,
        f.File_Name AS file_name,
        f.Script_UUID AS nav_uuid,
        f.Script_Name AS script_name,
        f.Step_Index + 1 AS step_nr,
        CASE WHEN f.flush_join AND f.flush_external THEN 'join+external'
             WHEN f.flush_join THEN 'join' ELSE 'external' END AS flush_class,
        CAST(COALESCE(b.loop_depth_before, 0) AS INTEGER) AS loop_depth,
        f.Step_UUID AS step_uuid,
        'Refresh Window at step ' || (f.Step_Index + 1) || ' flushes '
          || CASE WHEN f.flush_join AND f.flush_external THEN 'cached join results and external data'
                  WHEN f.flush_join THEN 'cached join results' ELSE 'cached external data' END
          || CASE WHEN COALESCE(b.loop_depth_before, 0) > 0 THEN ' inside a loop' ELSE '' END AS message,
           f.File_Name AS _ord_1,
           f.Script_Name AS _ord_2,
           f.Step_Index AS _ord_3
    FROM flushes f
    LEFT JOIN v_script_block_tree b
      ON b.File_Name = f.File_Name AND b.Script_UUID = f.Script_UUID AND b.Step_Index = f.Step_Index
    WHERE (getvariable('flush_kind') IS NULL
           OR (getvariable('flush_kind') = 'join' AND f.flush_join)
           OR (getvariable('flush_kind') = 'external' AND f.flush_external))
      AND (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR f.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
