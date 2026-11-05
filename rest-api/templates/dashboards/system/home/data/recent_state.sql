-- Guard of the card "Recently changed": one row with
--   has_changes    → at least one individual change by a developer (same rule as
--                    recent_changes) — the card hides itself without one
--   show_list      → the switch `recent` stands on single changes (default)
--   show_sessions  → the switch `recent` stands on work sessions
SELECT
    EXISTS (
        SELECT 1
        FROM ObjectChangeMeta m
        LEFT JOIN v_change_meta_authors a ON a.Author_Key = m.Author_Key
        WHERE m.Modified_At IS NOT NULL
          AND m.Bulk_Event_ID IS NULL
          AND NOT COALESCE(a.Is_Technical, m.Author_Kind IS NOT NULL)
          AND m.Object_Type NOT IN ('Account', 'Authorization')
    )                                                                         AS has_changes,
    COALESCE(CAST(getvariable('recent') AS VARCHAR), '') <> 'sessions'       AS show_list,
    COALESCE(CAST(getvariable('recent') AS VARCHAR), '') = 'sessions'        AS show_sessions;
