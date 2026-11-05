-- @template_type: report
-- @description: Serverseitige Ausführung — Perform Script on Server, Execute FileMaker Data API und Install OnTimer Script (Step_ID-gated). Klick auf eine Zeile öffnet das Script am Step.
-- @params: file (optional), mechanism (optional), limit (optional, default 400)
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        s.File_Name                                         AS file,
        CASE s.Step_ID
            WHEN 164 THEN 'Perform Script on Server'
            WHEN 203 THEN 'Execute FileMaker Data API'
            WHEN 148 THEN 'Install OnTimer Script'
        END                                                 AS mechanism,
        s.Script_Name                                       AS carrier,
        s.Step_Name                                         AS detail,
        s.Step_Index + 1                                        AS step_index,
        s.Script_UUID                                       AS nav_uuid,
        s.Step_UUID                                         AS step_uuid,
           s.File_Name AS _ord_1,
           s.Script_Name AS _ord_2,
           s.Step_Index AS _ord_3
    FROM StepsForScripts s
    WHERE s.Step_ID IN (164, 203, 148)
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('mechanism') IS NULL OR getvariable('mechanism') IN ('', 'All', 'Alle')
           OR CASE s.Step_ID WHEN 164 THEN 'Perform Script on Server'
                             WHEN 203 THEN 'Execute FileMaker Data API'
                             WHEN 148 THEN 'Install OnTimer Script' END = getvariable('mechanism'))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3),
           row_number() OVER (ORDER BY u.mechanism, u._ord_1, u._ord_2, u._ord_3, u) AS row_key
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
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 400), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM filtered) t
)
-- <<< shared paging window block
SELECT f.*,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
