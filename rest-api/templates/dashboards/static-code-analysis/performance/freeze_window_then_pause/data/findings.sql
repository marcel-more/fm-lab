-- Scripts that freeze the window and later pause. Per the Claris help,
-- Pause/Resume Script ends the frozen state — everything after the pause
-- renders live again, so the freeze silently loses its effect.
--
-- One finding per script: the first enabled Freeze Window (id 79) that has an
-- enabled Pause/Resume (id 62) at a later step index. `step` anchors on the
-- freeze, `marks` highlights the freeze and every later pause (capped at 25;
-- list_slice instead of the [1:25] slice syntax — the dashboard SQL
-- preprocessor replaces every :word, including the ':25' of a slice).
WITH freezes AS (
    SELECT File_Name, Script_UUID, Script_Name,
           min(Step_Index) AS freeze_index
    FROM StepsForScripts
    WHERE Step_ID = 79 AND Is_Enabled
    GROUP BY 1, 2, 3
),
pauses AS (
    SELECT f.File_Name, f.Script_UUID,
           min(p.Step_Index) AS first_pause_index,
           count(*) AS pause_count,
           list(p.Step_UUID ORDER BY p.Step_Index) AS pause_uuids
    FROM freezes f
    JOIN StepsForScripts p
      ON p.File_Name = f.File_Name AND p.Script_UUID = f.Script_UUID
     AND p.Step_ID = 62 AND p.Is_Enabled AND p.Step_Index > f.freeze_index
    GROUP BY 1, 2
),
-- The finding rows; the keys of the default order travel along as hidden
-- columns, so the page order does not hang on row_key alone.
unkeyed AS MATERIALIZED (
    SELECT
        'freeze-window-then-pause' AS rule_id,
        'warning' AS severity,
        f.File_Name AS file_name,
        f.Script_UUID AS nav_uuid,
        f.Script_Name AS script_name,
        f.freeze_index + 1 AS freeze_step,
        p.first_pause_index + 1 AS pause_step,
        CAST(p.pause_count AS INTEGER) AS pause_count,
        fs.Step_UUID AS step_uuid,
        fs.Step_UUID || ',' || array_to_string(list_slice(p.pause_uuids, 1, 25), ',') AS marks,
        'Freeze Window at step ' || (f.freeze_index + 1) || ' is ended by Pause/Resume at step '
          || (p.first_pause_index + 1)
          || CASE WHEN p.pause_count > 1 THEN ' (and ' || (p.pause_count - 1) || ' more pause(s))' ELSE '' END
          || ' — the window renders mid-script' AS message,
           f.File_Name AS _ord_1,
           f.Script_Name AS _ord_2
    FROM freezes f
    JOIN pauses p ON p.File_Name = f.File_Name AND p.Script_UUID = f.Script_UUID
    JOIN StepsForScripts fs
      ON fs.File_Name = f.File_Name AND fs.Script_UUID = f.Script_UUID AND fs.Step_Index = f.freeze_index
    WHERE (getvariable('file') IS NULL OR f.File_Name = getvariable('file'))
      AND (getvariable('scope_uuids') IS NULL
           OR f.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
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
