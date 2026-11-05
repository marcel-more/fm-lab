-- Card "Recently changed", switch `recent` on work sessions: the ten newest work
-- sessions — consecutive individual changes of the same person with gaps of at
-- most 30 minutes, across files. Same stamps as recent_changes (no mass events,
-- no technical authors, no Account/Authorization) and the same session rule as
-- the `changes` dashboard, whose list a row opens: from_at/to_at (to the
-- second) and person_key give the drill-down window. Computed only with
-- recent=sessions (else no rows). Times are the local time of the editing
-- client without time zone, as written.
WITH session_input AS (
    SELECT
        m.Object_UUID, m.File_Name, m.Object_Type, m.Modified_At,
        COALESCE(a.Person_Key, m.Author_Key)                  AS Person_Key,
        COALESCE(a.Display_Name, m.Modified_By, m.Author_Key) AS Person_Name
    FROM ObjectChangeMeta m
    LEFT JOIN v_change_meta_authors a ON a.Author_Key = m.Author_Key
    WHERE m.Modified_At IS NOT NULL
      AND m.Bulk_Event_ID IS NULL
      AND NOT COALESCE(a.Is_Technical, m.Author_Kind IS NOT NULL)
      AND m.Object_Type NOT IN ('Account', 'Authorization')
      AND COALESCE(CAST(getvariable('recent') AS VARCHAR), '') = 'sessions'
),
-- >>> shared session block — identical in every dataset that builds work sessions
-- (unit test dashboard-changelog-blocks guards it); change it in all files at once.
--   session_input   the stamps to group (defined by each dataset right before)
--   ordered         a stamp starts a new session when the previous stamp of the
--                   same person lies more than 30 minutes back
--   numbered_steps  every stamp with its session number per person
ordered AS (
    SELECT
        si.Object_UUID, si.File_Name, si.Object_Type, si.Modified_At, si.Person_Key, si.Person_Name,
        CASE WHEN si.Modified_At - lag(si.Modified_At) OVER w30 <= INTERVAL 30 MINUTE
             THEN 0 ELSE 1 END                                     AS is_start,
        row_number() OVER w30                                      AS seq
    FROM session_input si
    WINDOW w30 AS (PARTITION BY si.Person_Key
                   ORDER BY si.Modified_At, si.File_Name, si.Object_Type, si.Object_UUID)
),
numbered_steps AS (
    SELECT
        o.Object_UUID, o.File_Name, o.Object_Type, o.Modified_At, o.Person_Key, o.Person_Name,
        sum(o.is_start) OVER (PARTITION BY o.Person_Key ORDER BY o.seq
                              ROWS UNBOUNDED PRECEDING)            AS session_no
    FROM ordered o
)
-- <<< shared session block
,
type_counts AS (
    SELECT ns.Person_Key, ns.session_no, ns.Object_Type, count(*) AS n
    FROM numbered_steps ns
    GROUP BY ns.Person_Key, ns.session_no, ns.Object_Type
),
type_summary AS (
    SELECT tc.Person_Key, tc.session_no,
           string_agg(tc.n || ' ' || tc.Object_Type, ' · ' ORDER BY tc.n DESC, tc.Object_Type) AS types
    FROM type_counts tc
    GROUP BY tc.Person_Key, tc.session_no
),
sessions AS (
    SELECT
        ns.Person_Key, ns.session_no,
        any_value(ns.Person_Name)                                  AS person,
        min(ns.Modified_At)                                        AS start_at,
        max(ns.Modified_At)                                        AS end_at,
        count(*)                                                   AS objects,
        count(DISTINCT ns.File_Name)                               AS files,
        mode(ns.File_Name)                                         AS main_file
    FROM numbered_steps ns
    GROUP BY ns.Person_Key, ns.session_no
)
SELECT
    strftime(se.start_at, '%Y-%m-%d %H:%M')                        AS started,
    CASE WHEN CAST(se.start_at AS DATE) = CAST(se.end_at AS DATE)
         THEN strftime(se.end_at, '%H:%M')
         ELSE strftime(se.end_at, '%Y-%m-%d %H:%M') END            AS ended,
    date_diff('minute', se.start_at, se.end_at)                    AS minutes,
    se.person                                                      AS person,
    se.objects                                                     AS objects,
    CASE WHEN se.files > 1 THEN se.main_file || ' +' || (se.files - 1)
         ELSE se.main_file END                                     AS files,
    ts.types                                                       AS types,
    strftime(se.start_at, '%Y-%m-%d %H:%M:%S')                     AS from_at,
    strftime(se.end_at, '%Y-%m-%d %H:%M:%S')                       AS to_at,
    se.Person_Key                                                  AS person_key,
    se.Person_Key || '#' || se.session_no                          AS session_key
FROM sessions se
JOIN type_summary ts ON ts.Person_Key = se.Person_Key AND ts.session_no = se.session_no
ORDER BY se.start_at DESC, se.Person_Key
LIMIT 10;
