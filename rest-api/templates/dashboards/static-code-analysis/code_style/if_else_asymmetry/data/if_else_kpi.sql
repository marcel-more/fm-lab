-- @template_type: report
-- @description: Aggregate KPIs for asymmetric If/Else blocks (long If branch, short Else branch).
-- @params: file (optional), min_if_len (optional, default 10), max_else_len (optional, default 2)

-- Control-flow gating is locale-independent via Step_ID
-- (68 = If, 69 = Else, 70 = End If); Step_Name is localized in SaXML exports.
WITH steps_with_depth AS (
    SELECT
        Script_UUID, File_Name, Step_Index, Step_ID,
        SUM(CASE WHEN Step_ID = 68 THEN 1
                 WHEN Step_ID = 70 THEN -1
                 ELSE 0 END)
            OVER (PARTITION BY Script_UUID, File_Name
                  ORDER BY Step_Index
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS depth_after
    FROM StepsForScripts
),
if_nodes AS (
    SELECT Script_UUID, File_Name, Step_Index AS if_idx, depth_after AS if_depth
    FROM steps_with_depth WHERE Step_ID = 68
),
if_with_end AS (
    SELECT i.*,
        (SELECT MIN(e.Step_Index) FROM steps_with_depth e
           WHERE e.Script_UUID = i.Script_UUID AND e.File_Name = i.File_Name
             AND e.Step_Index > i.if_idx
             AND e.Step_ID = 70
             AND e.depth_after = i.if_depth - 1) AS end_idx
    FROM if_nodes i
),
matched AS (
    SELECT b.*,
        (SELECT MIN(s.Step_Index) FROM steps_with_depth s
           WHERE s.Script_UUID = b.Script_UUID AND s.File_Name = b.File_Name
             AND s.Step_Index > b.if_idx
             AND s.Step_Index < b.end_idx
             AND s.Step_ID = 69
             AND s.depth_after = b.if_depth) AS else_idx
    FROM if_with_end b
    WHERE b.end_idx IS NOT NULL
),
sized AS (
    SELECT m.*,
        (SELECT COUNT(*) FROM StepsForScripts t
           WHERE t.Script_UUID = m.Script_UUID AND t.File_Name = m.File_Name
             AND t.Step_Index > m.if_idx
             AND t.Step_Index < m.else_idx) AS if_len,
        (SELECT COUNT(*) FROM StepsForScripts t
           WHERE t.Script_UUID = m.Script_UUID AND t.File_Name = m.File_Name
             AND t.Step_Index > m.else_idx
             AND t.Step_Index < m.end_idx) AS else_len
    FROM matched m WHERE m.else_idx IS NOT NULL
)
SELECT
    COUNT(*)                          AS asymmetric_blocks,
    COUNT(DISTINCT Script_UUID)       AS affected_scripts,
    COUNT(DISTINCT File_Name)         AS affected_files,
    MAX(if_len)                       AS max_if_len
FROM sized
WHERE if_len  >= CAST(COALESCE(getvariable('min_if_len'),  '10') AS INTEGER)
  AND else_len <= CAST(COALESCE(getvariable('max_else_len'), '2') AS INTEGER)
  AND (getvariable('file') IS NULL OR File_Name = getvariable('file'));
