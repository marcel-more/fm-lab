-- Comment steps in scripts that carry a FIXME marker — a known defect that
-- was shipped. Part of the "Unfinished Work" rule family; the detector is the
-- canon of tools/tests/rules/unfinished_work_detector.sql:
--
--   FIXME: (?i)\bfix[\s\-_]?(it|me)\b
--
-- Case-insensitive and separator-tolerant on purpose (FIXME, FIX ME, FIX-IT,
-- fix_it), so the marker is found regardless of the developer's notation. The
-- word boundaries keep prose out ("fix item", "prefix message", "fixed").
--
-- Source column is StepsForScripts.Comment_Text — the decoded comment text the
-- converter extracts for Step_ID 89; no XML regex needed, and no entity
-- decoding in the rule. Comment_Text exists for step 89 only.
--
-- Grain: one finding per comment step. A comment carrying FIXME *and* TODO is
-- reported by both rules of the family — the overlap is intended (a line can
-- be a defect and a plan at once).
--
-- Disabled comment steps count too: a marker documents open work whether or
-- not the surrounding step is active.
--
-- Deep link: the row click opens the script, scrolls to the comment step
-- (`step`) and marks it (`marks`).
WITH
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'script-comment-fixme' AS rule_id, 'warning' AS severity,
        s.File_Name AS file_name,
        s.Script_UUID AS nav_uuid,
        'Script' AS nav_type,
        s.Script_Name AS script_name,
        s.Step_Index + 1 AS step_no,
        s.Step_UUID AS step_uuid,
        s.Step_UUID AS marks,
        regexp_extract(s.Comment_Text, '(?i)\bfix[\s\-_]?(it|me)\b', 0) AS marker,
        s.Comment_Text AS comment,
        'FIXME marker in a script comment' AS message,
           s.File_Name AS _ord_1,
           s.Script_Name AS _ord_2,
           s.Step_Index AS _ord_3
    FROM StepsForScripts s
    WHERE s.Step_ID = 89   -- '# (Comment)' — Step_ID is locale-independent
      AND s.Comment_Text IS NOT NULL
      AND regexp_matches(s.Comment_Text, '(?i)\bfix[\s\-_]?(it|me)\b')
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR s.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
