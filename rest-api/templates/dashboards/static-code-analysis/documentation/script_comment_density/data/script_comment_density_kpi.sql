-- @template_type: report
-- @description: Aggregate KPI numbers for the Script Comment Density dashboard.
-- @params: file (optional, exact File_Name match), min_steps (optional, default 10)

WITH script_stats AS (
    SELECT
        s.Script_UUID,
        COUNT(st.Step_UUID)                                           AS total_steps,
        -- Step_ID 89 = comment step (locale-independent; Step_Name is localized).
        COUNT(*) FILTER (WHERE st.Step_ID = 89)                       AS comment_steps,
        COUNT(*) FILTER (WHERE st.Step_ID = 89
                           AND st.Parameters_XML LIKE '%<Comment/>%') AS whitespace_steps
    FROM ScriptCatalog s
    LEFT JOIN StepsForScripts st ON st.Script_UUID = s.Script_UUID AND st.File_Name = s.File_Name
    WHERE (s.Folder_Type IS NULL OR s.Folder_Type = 'False')
      AND NOT s.Is_Separator
      AND (getvariable('file') IS NULL OR s.File_Name = getvariable('file'))
    GROUP BY ALL
),
filtered AS (
    SELECT * FROM script_stats
    WHERE total_steps >= CAST(COALESCE(getvariable('min_steps'), '10') AS INTEGER)
)
SELECT
    (SELECT COUNT(*) FROM script_stats)                                                            AS scripts_total,
    (SELECT COUNT(*) FROM filtered)                                                                AS scripts_substantial,
    (SELECT COUNT(*) FROM filtered WHERE comment_steps - whitespace_steps = 0)                     AS scripts_without_comment,
    (SELECT ROUND(MEDIAN((comment_steps - whitespace_steps) * 100.0
                         / NULLIF(total_steps - whitespace_steps, 0)), 1)
       FROM filtered)                                                                              AS median_comment_pct,
    -- Dynamic upper bound for the header slider (highest step count in the corpus,
    -- unfiltered so the ceiling stays stable while dragging min_steps).
    (SELECT COALESCE(MAX(total_steps), 0) FROM script_stats)                                       AS max_total_steps;
