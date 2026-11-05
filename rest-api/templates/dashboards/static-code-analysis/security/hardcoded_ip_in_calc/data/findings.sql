-- Hardcoded IPv4 addresses in the active code of any calculation slot.
-- Instance base is the CalculationsCatalog (single source for all calculation
-- slots, DDR-less instances included). Comments are stripped before matching
-- so addresses in documentation comments do not score: /* ... */ blocks and
-- // line comments (a // that is part of a URL scheme is protected). Known
-- limit: a // inside a string literal that is not a scheme still strips to
-- end of line — same convention as the comment-marker rule family.
-- Script-step instances anchor at the step (Owner_UUID = Step_UUID);
-- StepsForScripts contributes the script context for navigation.
WITH hit AS (
    SELECT c.File_Name, c.Owner_UUID, c.Owner_Type, c.Owner_Name,
        regexp_replace(
            regexp_replace(COALESCE(c.Formula_Text, c.Display_Text), '(?s)/\*.*?\*/', ' ', 'g'),
            '(?m)(^|[^:])//[^\n\r]*', '\1', 'g') AS active_text
    FROM CalculationsCatalog c
    WHERE (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'hardcoded-ip-in-calc' AS rule_id, 'warning' AS severity,
        h.File_Name AS file_name,
        COALESCE(s.Script_Name, h.Owner_Name, '—') AS owner,
        regexp_extract(h.active_text, '([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})', 1) AS ip,
        COALESCE(s.Script_UUID, h.Owner_UUID) AS nav_uuid,
        CASE WHEN s.Script_UUID IS NOT NULL THEN 'Script' ELSE h.Owner_Type END AS nav_type,
        CASE WHEN s.Script_UUID IS NOT NULL THEN h.Owner_UUID END AS step_uuid,
           h.File_Name AS _ord_1
    FROM hit h
    LEFT JOIN StepsForScripts s ON h.Owner_Type = 'ScriptStep'
         AND s.Step_UUID = h.Owner_UUID AND s.File_Name = h.File_Name
    WHERE regexp_matches(h.active_text, '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1),
           row_number() OVER (ORDER BY u._ord_1, u) AS row_key
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
-- Chip filter: narrows the whole result; its counts (_chip_facets) leave out
-- the search and the chip itself.
filtered AS (
    SELECT * FROM searched
    WHERE (getvariable('object_type') IS NULL OR nav_type = getvariable('object_type'))
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
    -- Facets ordered by value, so every request returns the same text.
    (SELECT to_json(map_from_entries(list((nav_type, n) ORDER BY nav_type)))
       FROM (SELECT nav_type, count(*) AS n FROM result GROUP BY 1)) AS _chip_facets,
    pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM filtered f, pg
ORDER BY /*@sort*/ row_key, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
