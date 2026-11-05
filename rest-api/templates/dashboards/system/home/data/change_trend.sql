-- One row per month: individual changes of the whole solution over the 12 months
-- up to its data state (newest individual change by a developer), for the
-- sparkline of the card "Recently changed". Same rules as the sparkline of the
-- file view, without the file: no mass events, no technical authors, no
-- Account/Authorization (runtime changes) — a month's from_at/to_at opens exactly
-- its changes in the dashboard "Recent changes".
--   month / month_index → the month as text and its position (0 = oldest)
--   n                   → individual changes in that month
--   from_at / to_at     → the month as drill-down window (to the second)
-- Times are the local time of the editing client without time zone, as text.
WITH stamps AS (
    SELECT m.Object_Type, m.Modified_At,
           COALESCE(a.Is_Technical, m.Author_Kind IS NOT NULL) AS Is_Technical
    FROM ObjectChangeMeta m
    LEFT JOIN v_change_meta_authors a ON a.Author_Key = m.Author_Key
    WHERE m.Modified_At IS NOT NULL
      AND m.Bulk_Event_ID IS NULL
      AND m.Object_Type NOT IN ('Account', 'Authorization')
),
anchor AS (
    SELECT COALESCE(max(s.Modified_At) FILTER (WHERE NOT s.Is_Technical), max(s.Modified_At)) AS anchor_at
    FROM stamps s
),
months AS (
    SELECT g.m_start, g.m_start + INTERVAL 1 MONTH AS m_end,
           row_number() OVER (ORDER BY g.m_start) - 1 AS month_index
    FROM anchor an,
         generate_series(date_trunc('month', an.anchor_at) - INTERVAL 11 MONTH,
                         date_trunc('month', an.anchor_at), INTERVAL 1 MONTH) g(m_start)
),
hits AS (
    SELECT date_trunc('month', s.Modified_At) AS m_start, count(*) AS n
    FROM stamps s
    WHERE NOT s.Is_Technical
    GROUP BY 1
)
SELECT
    strftime(mo.m_start, '%Y-%m')                                AS month,
    mo.month_index                                               AS month_index,
    COALESCE(h.n, 0)                                             AS n,
    strftime(mo.m_start, '%Y-%m-%d %H:%M:%S')                    AS from_at,
    strftime(mo.m_end - INTERVAL 1 SECOND, '%Y-%m-%d %H:%M:%S')  AS to_at
FROM months mo
LEFT JOIN hits h ON h.m_start = mo.m_start
ORDER BY mo.m_start;
