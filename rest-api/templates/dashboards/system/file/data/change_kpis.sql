-- One row: change-stamp KPIs of the file for the hero "File info".
--   last_design_change  → newest individual change by a developer (outside mass
--                         events, no technical author) — the file's "last design change"
--   last_design_author  → display name of that change's author (curated aliases)
--   last_mass_change    → end of the newest mass event touching the file
--   mass_events         → number of mass events touching the file
--   individual_pct      → share of the file's stamps outside mass events
-- Times are the local time of the editing client without time zone, shown as written.
-- Separate dataset: on a catalog without the mass-event columns only this KPI strip fails.
WITH own AS (
    SELECT m.Modified_At, m.Author_Key, m.Bulk_Event_ID, m.Author_Kind
    FROM ObjectChangeMeta m
    WHERE m.File_Name = :file
),
last_single AS (
    SELECT o.Modified_At, o.Author_Key
    FROM own o
    WHERE o.Bulk_Event_ID IS NULL AND o.Author_Kind IS NULL AND o.Modified_At IS NOT NULL
    ORDER BY o.Modified_At DESC, o.Author_Key
    LIMIT 1
),
events AS (
    SELECT b.Bulk_Event_ID, b.End_At
    FROM ChangeBulkEvents b
    WHERE list_contains(b.File_Names, :file)
)
SELECT
    (SELECT strftime(ls.Modified_At, '%Y-%m-%d %H:%M') FROM last_single ls) AS last_design_change,
    (SELECT COALESCE(a.Display_Name, ls.Author_Key)
       FROM last_single ls
       LEFT JOIN v_change_meta_authors a ON a.Author_Key = ls.Author_Key) AS last_design_author,
    (SELECT strftime(max(e.End_At), '%Y-%m-%d %H:%M') FROM events e) AS last_mass_change,
    (SELECT COUNT(*) FROM events) AS mass_events,
    (SELECT round(100.0 * COUNT(*) FILTER (WHERE o.Bulk_Event_ID IS NULL) / NULLIF(COUNT(*), 0), 1)
       FROM own o) AS individual_pct;
