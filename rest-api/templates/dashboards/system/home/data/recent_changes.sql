-- Card "Recently changed": the ten newest individual changes by developers —
-- outside mass events, no technical authors (curated aliases of
-- v_change_meta_authors), no Account/Authorization (runtime changes). The full
-- list with filters is the `changes` dashboard. Times are the local time of
-- the editing client without time zone, as written. Empty on catalogs without
-- change stamps — the card hides itself then. Computed only while the switch
-- `recent` stands on single changes (else no rows).
SELECT
    strftime(m.Modified_At, '%Y-%m-%d %H:%M')                    AS at,
    m.Object_Type                                                 AS type,
    m.Object_Name                                                 AS name,
    m.File_Name                                                   AS file,
    COALESCE(a.Display_Name, m.Modified_By, m.Author_Key)         AS person,
    m.Object_UUID                                                 AS uuid
FROM ObjectChangeMeta m
LEFT JOIN v_change_meta_authors a ON a.Author_Key = m.Author_Key
WHERE m.Modified_At IS NOT NULL
  AND m.Bulk_Event_ID IS NULL
  AND NOT COALESCE(a.Is_Technical, m.Author_Kind IS NOT NULL)
  AND m.Object_Type NOT IN ('Account', 'Authorization')
  AND COALESCE(CAST(getvariable('recent') AS VARCHAR), '') <> 'sessions'
ORDER BY m.Modified_At DESC, m.File_Name, m.Object_Type, m.Object_Name
LIMIT 10;
