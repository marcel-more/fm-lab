-- Close Window [Name: X] where X is never produced by any window-name producer
-- ANYWHERE in the imported corpus (producers: New Window @Name, Go to Related
-- Record @Name, Set Window Title @Rename — its @Name slot is the *target*, not a
-- producer). Window names are app-global, so producers are matched corpus-wide
-- (no file scoping on the producer side). A literal close with no producer is a
-- guaranteed no-op (dead cleanup, severity error); a dynamic name (variable /
-- expression) is only comparable textually (severity info — verify at runtime).
-- Formula source is the CalculationsCatalog (Owner_UUID = Step_UUID, slot
-- selected via the instance's Source_Path); StepsForScripts contributes the
-- step type, enabled state and script context.
WITH closes AS (
    SELECT c.File_Name, s.Script_UUID, s.Script_Name, s.Step_Index, c.Owner_UUID AS Step_UUID,
           COALESCE(c.Formula_Text, c.Display_Text) AS Calc_Text,
           regexp_full_match(COALESCE(c.Formula_Text, c.Display_Text), '"[^"]*"') AS is_literal
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Step_ID = 121 AND c.Source_Path = 'Step/Name' AND s.Is_Enabled
),
producers AS (
    SELECT DISTINCT COALESCE(c.Formula_Text, c.Display_Text) AS Calc_Text
    FROM CalculationsCatalog c
    JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE s.Is_Enabled
      AND ((s.Step_ID IN (122, 74) AND c.Source_Path = 'Step/Name')
           OR (s.Step_ID = 124 AND c.Source_Path = 'Step/Rename'))
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT 'close-window-name-never-created' AS rule_id,
        CASE WHEN c.is_literal THEN 'error' ELSE 'info' END AS severity,
        c.File_Name AS file_name, c.Script_UUID AS nav_uuid, c.Script_Name AS script_name,
        c.Step_Index + 1 AS step_no, c.Step_UUID AS step_uuid,
        c.Calc_Text AS window_name,
        CASE WHEN c.is_literal
             THEN 'Close Window targets ' || c.Calc_Text || ' — this name is never produced anywhere in the imported corpus (dead cleanup)'
             ELSE 'Close Window targets dynamic name ' || c.Calc_Text || ' with no textually matching producer (heuristic — verify at runtime)'
        END AS message
    FROM closes c
    LEFT JOIN producers p ON p.Calc_Text = c.Calc_Text
    WHERE p.Calc_Text IS NULL
      AND (getvariable('file') IS NULL OR c.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR c.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
),
-- row_key numbers the rows in the default order; the whole row breaks the
-- remaining ties, so every request assigns the same key.
result AS MATERIALIZED (
    SELECT u.*,
           row_number() OVER (ORDER BY u.severity, u.file_name, u.script_name, u.step_no, u) AS row_key
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
