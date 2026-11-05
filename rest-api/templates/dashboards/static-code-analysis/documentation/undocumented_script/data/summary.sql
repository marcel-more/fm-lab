-- Feeds the KPI strip and the comment filter chips (true totals, uncapped).
-- has_comment counts only comment steps carrying text (attribute or element
-- form) — empty '#' spacer comments do not count as documentation.
WITH s AS (
    SELECT File_Name,
        COUNT(*) FILTER (WHERE Step_ID = 89
            AND (Step_XML LIKE '%<Comment value="%' OR Step_XML LIKE '%<Comment>%')) > 0 AS has_comment
    FROM StepsForScripts
    WHERE (getvariable('file') IS NULL OR File_Name = getvariable('file'))
    GROUP BY File_Name, Script_ID
    HAVING COUNT(*) >= 10
),
sel AS (SELECT COALESCE(getvariable('comment'), 'without') = 'with' AS want_with)
SELECT
    COUNT(*) FILTER (WHERE NOT has_comment) AS count_without,
    COUNT(*) FILTER (WHERE has_comment)     AS count_with,
    CASE WHEN (SELECT want_with FROM sel) THEN COUNT(*) FILTER (WHERE has_comment)
         ELSE COUNT(*) FILTER (WHERE NOT has_comment) END AS finding_count,
    'info' AS severity,
    CASE WHEN (SELECT want_with FROM sel) THEN COUNT(DISTINCT File_Name) FILTER (WHERE has_comment)
         ELSE COUNT(DISTINCT File_Name) FILTER (WHERE NOT has_comment) END AS affected_files
FROM s;
