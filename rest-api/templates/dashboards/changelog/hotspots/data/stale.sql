-- Objects without fan-in in one state (state = cold | unknown | active | menu),
-- only with view=stale (else no rows): oldest stamp first, paged like the change
-- list (100 rows per page).
--   age_years      years from the last stamp to the data state (one decimal)
--   modifications  lifetime save counter
--   marker         'Mass event' when the last stamp belongs to a mass event
--   row_key        UUID and file — a UUID can occur in several files
-- >>> shared filter block — identical in every dataset of the Changelog dashboards
-- (unit test dashboard-changelog-blocks guards it); change it in all files at once.
--   params    URL params, normalised ('' and absent → NULL / default). `type` and
--             `file` are comma-separated lists of the multi-selects (a handful of
--             values, hence list_contains). `count` and `stack` steer only the charts.
--   stamps    every change stamp with the person (curated aliases of
--             v_change_meta_authors) and the curated technical flag
--   anchor    "data" (default): newest individual change by a developer — the
--             solution's data state; "today": the current local time
--   period    lower bound of the period `days` (7 | 30 | 90 (default) | 365 | all)
--             counted back from the anchor; NULL for all
--   win       from/to (a drill-down window, inclusive) wins over the period
--   base      every filter except time and mass events; Account/Authorization only
--             when the type filter names them (runtime changes, not developer activity)
--   scoped    base within the window
--   charted   base within the period, ignoring the drill-down window — the charts
--             keep their frame while the list shows one of their cells
--   filtered  scoped minus mass events unless `bulk=include`
WITH params AS (
    SELECT
        string_split(NULLIF(CAST(getvariable('type') AS VARCHAR), ''), ',')            AS types,
        string_split(NULLIF(CAST(getvariable('file') AS VARCHAR), ''), ',')            AS files,
        NULLIF(CAST(getvariable('person') AS VARCHAR), '')                             AS person,
        COALESCE(NULLIF(CAST(getvariable('days') AS VARCHAR), ''), '90')               AS days,
        COALESCE(NULLIF(CAST(getvariable('anchor') AS VARCHAR), ''), 'data')           AS anchor,
        COALESCE(NULLIF(CAST(getvariable('bulk') AS VARCHAR), ''), 'hide')             AS bulk,
        COALESCE(NULLIF(CAST(getvariable('technical') AS VARCHAR), ''), 'hide')        AS technical,
        TRY_CAST(NULLIF(CAST(getvariable('from') AS VARCHAR), '') AS TIMESTAMP)        AS w_from,
        TRY_CAST(NULLIF(CAST(getvariable('to') AS VARCHAR), '') AS TIMESTAMP)          AS w_to,
        lower(NULLIF(trim(CAST(getvariable('q') AS VARCHAR)), ''))                     AS q,
        COALESCE(NULLIF(CAST(getvariable('count') AS VARCHAR), ''), 'objects')         AS count_mode,
        COALESCE(NULLIF(CAST(getvariable('stack') AS VARCHAR), ''), 'type')            AS stack_by
),
stamps AS (
    SELECT
        m.Object_UUID, m.File_Name, m.Object_Type, m.Object_Name, m.Modified_At,
        m.Modified_Account, m.Modifications, m.Author_Key, m.Burst_ID, m.Bulk_Event_ID,
        COALESCE(a.Person_Key, m.Author_Key)                  AS Person_Key,
        COALESCE(a.Display_Name, m.Modified_By, m.Author_Key) AS Person_Name,
        COALESCE(a.Is_Technical, m.Author_Kind IS NOT NULL)   AS Is_Technical
    FROM ObjectChangeMeta m
    LEFT JOIN v_change_meta_authors a ON a.Author_Key = m.Author_Key
    WHERE m.Modified_At IS NOT NULL
),
anchor AS (
    SELECT CASE
               WHEN p.anchor = 'today' THEN CAST(current_localtimestamp() AS TIMESTAMP)
               ELSE COALESCE(
                   (SELECT max(s.Modified_At) FROM stamps s
                     WHERE s.Bulk_Event_ID IS NULL AND NOT s.Is_Technical),
                   (SELECT max(s.Modified_At) FROM stamps s))
           END AS anchor_at
    FROM params p
),
period AS (
    SELECT CASE
               WHEN p.days = 'all' THEN NULL
               ELSE an.anchor_at - INTERVAL 1 DAY * COALESCE(TRY_CAST(p.days AS INTEGER), 90)
           END AS lo
    FROM params p, anchor an
),
win AS (
    SELECT
        (p.w_from IS NOT NULL OR p.w_to IS NOT NULL) AS is_window,
        CASE WHEN p.w_from IS NOT NULL OR p.w_to IS NOT NULL THEN p.w_from ELSE pe.lo END AS lo,
        CASE WHEN p.w_from IS NOT NULL OR p.w_to IS NOT NULL THEN p.w_to END AS hi
    FROM params p, period pe
),
base AS (
    SELECT
        s.Object_UUID, s.File_Name, s.Object_Type, s.Object_Name, s.Modified_At,
        s.Modified_Account, s.Modifications, s.Author_Key, s.Burst_ID, s.Bulk_Event_ID,
        s.Person_Key, s.Person_Name, s.Is_Technical
    FROM stamps s, params p
    WHERE ((p.types IS NULL AND s.Object_Type NOT IN ('Account', 'Authorization'))
           OR list_contains(p.types, s.Object_Type))
      AND (p.files IS NULL OR list_contains(p.files, s.File_Name))
      AND (p.person IS NULL OR s.Person_Key = p.person)
      AND (p.technical = 'include' OR NOT s.Is_Technical)
      AND (p.q IS NULL
           OR contains(lower(COALESCE(s.Object_Name, '')), p.q)
           OR contains(lower(s.File_Name), p.q)
           OR contains(lower(s.Person_Name), p.q)
           OR contains(lower(s.Object_Type), p.q))
),
scoped AS (
    SELECT
        b.Object_UUID, b.File_Name, b.Object_Type, b.Object_Name, b.Modified_At,
        b.Modified_Account, b.Modifications, b.Author_Key, b.Burst_ID, b.Bulk_Event_ID,
        b.Person_Key, b.Person_Name, b.Is_Technical
    FROM base b, win w
    WHERE (w.lo IS NULL OR b.Modified_At > w.lo OR (w.is_window AND b.Modified_At = w.lo))
      AND (w.hi IS NULL OR b.Modified_At <= w.hi)
),
charted AS (
    SELECT
        b.Object_UUID, b.File_Name, b.Object_Type, b.Object_Name, b.Modified_At,
        b.Modified_Account, b.Modifications, b.Author_Key, b.Burst_ID, b.Bulk_Event_ID,
        b.Person_Key, b.Person_Name, b.Is_Technical
    FROM base b, period pe
    WHERE pe.lo IS NULL OR b.Modified_At > pe.lo
),
filtered AS (
    SELECT
        sc.Object_UUID, sc.File_Name, sc.Object_Type, sc.Object_Name, sc.Modified_At,
        sc.Modified_Account, sc.Modifications, sc.Author_Key, sc.Burst_ID, sc.Bulk_Event_ID,
        sc.Person_Key, sc.Person_Name, sc.Is_Technical
    FROM scoped sc, params p
    WHERE p.bulk = 'include' OR sc.Bulk_Event_ID IS NULL
)
-- <<< shared filter block
,
-- >>> shared hotspot block — identical in every dataset of this bundle that lists
-- or counts objects (unit test dashboard-changelog-blocks guards it); change it in
-- all files at once.
--   hs_params   years (1 | 2 (default) | 5), view (hotspots (default) | stale),
--               quadrant (hotspot (default) | churn | core), state (cold (default)
--               | unknown | active | menu)
--   fan_in      distinct objects with a where-used link to an object
--               (LinkRoleRegistry.Counts_For_Where_Used), keyed by UUID and file —
--               a UUID can occur in several files; self-references do not count
--   menu_reach  layouts in the layout menu and scripts in the Scripts menu:
--               reachable by users without any reference
--   population  objects of the nine types with a usage meaning, with their
--               lifetime save counter, fan-in and menu flag. Every stamp counts,
--               whatever its author — the counter covers the whole lifetime
--   ranked      percentile rank of fan-in and counter within the object type,
--               over the whole solution, so a filter never moves the thresholds
--   classified  quadrant (top decile of the type on an axis = high; hotspot =
--               high on both) and, for objects without fan-in, the state: menu,
--               cold (last stamp older than `years` before the data state),
--               unknown (a younger mass stamp — the last real change is
--               overwritten) or active (a younger individual change)
--   shown       classified objects within the type, file and search filters
hs_params AS (
    SELECT
        CASE COALESCE(NULLIF(CAST(getvariable('years') AS VARCHAR), ''), '2')
            WHEN '1' THEN 1 WHEN '5' THEN 5 ELSE 2 END                          AS years,
        COALESCE(NULLIF(CAST(getvariable('view') AS VARCHAR), ''), 'hotspots')  AS view,
        COALESCE(NULLIF(CAST(getvariable('quadrant') AS VARCHAR), ''), 'hotspot') AS quadrant,
        COALESCE(NULLIF(CAST(getvariable('state') AS VARCHAR), ''), 'cold')     AS state
),
fan_in AS (
    SELECT l.Target_UUID, l.Target_File,
           count(DISTINCT (l.Source_UUID, l.Source_File)) AS fan_in
    FROM ObjectLinks l
    JOIN LinkRoleRegistry r ON r.Link_Role = l.Link_Role AND r.Counts_For_Where_Used
    WHERE (l.Source_UUID <> l.Target_UUID OR l.Source_File IS DISTINCT FROM l.Target_File)
      -- aggregate Layout → Field edge: twin of the layout-object edges, no own user
      AND NOT (l.Source_Type = 'Layout' AND l.Link_Role = 'displays_field' AND l.Link_Subrole IS NULL)
    GROUP BY l.Target_UUID, l.Target_File
),
menu_reach AS (
    SELECT DISTINCT lc.L_UUID AS Object_UUID, lc.File_Name FROM Layouts lc WHERE NOT lc.Is_Hidden
    UNION
    SELECT DISTINCT sc.Script_UUID, sc.File_Name FROM ScriptCatalog sc WHERE NOT sc.Is_Hidden
),
population AS (
    SELECT
        s.Object_UUID, s.File_Name, s.Object_Type, s.Object_Name, s.Modified_At, s.Bulk_Event_ID,
        COALESCE(s.Modifications, 0)   AS mods,
        COALESCE(fi.fan_in, 0)         AS fan_in,
        mr.Object_UUID IS NOT NULL     AS in_menu
    FROM stamps s
    LEFT JOIN fan_in fi     ON fi.Target_UUID = s.Object_UUID AND fi.Target_File = s.File_Name
    LEFT JOIN menu_reach mr ON mr.Object_UUID = s.Object_UUID AND mr.File_Name = s.File_Name
    WHERE s.Object_Type IN ('Script', 'Field', 'Layout', 'TableOccurrence', 'BaseTable',
                            'ValueList', 'CustomFunction', 'ExternalDataSource', 'Theme')
),
ranked AS (
    SELECT
        po.Object_UUID, po.File_Name, po.Object_Type, po.Object_Name, po.Modified_At,
        po.Bulk_Event_ID, po.mods, po.fan_in, po.in_menu,
        percent_rank() OVER (PARTITION BY po.Object_Type ORDER BY po.fan_in) AS use_rank,
        percent_rank() OVER (PARTITION BY po.Object_Type ORDER BY po.mods)   AS change_rank
    FROM population po
),
classified AS (
    SELECT
        rk.Object_UUID, rk.File_Name, rk.Object_Type, rk.Object_Name, rk.Modified_At,
        rk.Bulk_Event_ID, rk.mods, rk.fan_in, rk.in_menu, rk.use_rank, rk.change_rank,
        CASE
            WHEN rk.use_rank >= 0.9 AND rk.fan_in > 0 AND rk.change_rank >= 0.9 THEN 'hotspot'
            WHEN rk.change_rank >= 0.9                                         THEN 'churn'
            WHEN rk.use_rank >= 0.9 AND rk.fan_in > 0                          THEN 'core'
            ELSE 'other'
        END                                                        AS quadrant,
        CASE
            WHEN rk.fan_in > 0 THEN NULL
            WHEN rk.in_menu THEN 'menu'
            WHEN rk.Modified_At < an.anchor_at - INTERVAL 1 YEAR * hp.years THEN 'cold'
            WHEN rk.Bulk_Event_ID IS NOT NULL THEN 'unknown'
            ELSE 'active'
        END                                                        AS state,
        date_diff('day', rk.Modified_At, an.anchor_at)             AS age_days
    FROM ranked rk, anchor an, hs_params hp
),
shown AS (
    SELECT
        c.Object_UUID, c.File_Name, c.Object_Type, c.Object_Name, c.Modified_At,
        c.Bulk_Event_ID, c.mods, c.fan_in, c.in_menu, c.use_rank, c.change_rank,
        c.quadrant, c.state, c.age_days
    FROM classified c, params p
    WHERE (p.types IS NULL OR list_contains(p.types, c.Object_Type))
      AND (p.files IS NULL OR list_contains(p.files, c.File_Name))
      AND (p.q IS NULL
           OR contains(lower(COALESCE(c.Object_Name, '')), p.q)
           OR contains(lower(c.File_Name), p.q)
           OR contains(lower(c.Object_Type), p.q))
)
-- <<< shared hotspot block
,
numbered AS MATERIALIZED (
    SELECT
           sh.Object_UUID,
           sh.File_Name,
           sh.Object_Type,
           sh.Object_Name,
           sh.Modified_At,
           sh.Bulk_Event_ID,
           sh.mods,
           sh.age_days,
           row_number() OVER (ORDER BY sh.Modified_At, sh.Object_Type, sh.Object_Name,
                                    sh.File_Name, sh.Object_UUID)   AS rn,
           sh.Modified_At AS _ord_1,
           sh.Object_Type AS _ord_2,
           sh.Object_Name AS _ord_3,
           sh.File_Name AS _ord_4,
           sh.Object_UUID AS _ord_5
    FROM shown sh, hs_params hp
    WHERE hp.view = 'stale' AND sh.state = hp.state
),
-- The list rows; the keys of the default order travel along as hidden
-- columns.
unkeyed AS MATERIALIZED (
    SELECT
        n.Object_UUID                                                  AS uuid,
        n.Object_UUID || '|' || n.File_Name                            AS row_key,
        strftime(n.Modified_At, '%Y-%m-%d %H:%M')                     AS at,
        round(n.age_days / 365.25, 1)                                  AS age_years,
        n.Object_Type                                                  AS type,
        n.Object_Name                                                  AS name,
        n.File_Name                                                    AS file,
        n.mods                                                         AS modifications,
        CASE WHEN n.Bulk_Event_ID IS NOT NULL THEN 'Mass event' END    AS marker,
        n._ord_1 AS _ord_1,
        n._ord_2 AS _ord_2,
        n._ord_3 AS _ord_3,
        n._ord_4 AS _ord_4,
        n._ord_5 AS _ord_5
    FROM numbered n
),
-- _row_seq numbers the rows in the default order (row_key stays the row's
-- identity); the whole row breaks the remaining ties, so every request
-- assigns the same number.
result AS MATERIALIZED (
    SELECT u.* EXCLUDE (_ord_1, _ord_2, _ord_3, _ord_4, _ord_5),
           row_number() OVER (ORDER BY u._ord_1, u._ord_2, u._ord_3, u._ord_4, u._ord_5, u) AS _row_seq
    FROM unkeyed u
),
-- >>> shared paging changelog-window block
pg AS (
    SELECT s._pg_size, t._pg_total,
           LEAST(GREATEST(COALESCE(TRY_CAST(NULLIF(CAST(getvariable('page') AS VARCHAR), '') AS INTEGER), 1), 1),
                 GREATEST(CAST(ceil(t._pg_total / s._pg_size) AS INTEGER), 1)) AS _pg_page
    FROM (SELECT LEAST(GREATEST(COALESCE(TRY_CAST(CAST(getvariable('page_size') AS VARCHAR) AS INTEGER), 500), 1), 10000) AS _pg_size) s,
         (SELECT count(*) AS _pg_total FROM result) t
)
-- <<< shared paging changelog-window block
SELECT f.*, pg._pg_total AS _row_total, pg._pg_page AS _page, pg._pg_size AS _page_size
FROM result f, pg
ORDER BY /*@sort*/ _row_seq, f
LIMIT (SELECT _pg_size FROM pg) OFFSET (SELECT (_pg_page - 1) * _pg_size FROM pg);
