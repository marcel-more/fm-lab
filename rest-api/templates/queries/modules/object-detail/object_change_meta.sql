-- @template_type: report
-- @description: Effective change stamp of one object for the detail header: its own stamp, else the stamp of its container, else no row
-- @params: uuid (required), file (optional)
-- @output_format: report
-- @author: Marcel
-- @version: 1.0
-- @tags: change-metadata, header, react
-- @note: meta_source 'own' = Stempel des Objekts selbst (ObjectChangeMeta); 'container' =
-- @note: Objekt ohne eigenen Stempel (ScriptStep, LayoutObject, LayoutPart, Calculation,
-- @note: ScriptTrigger, CustomMenuItem) → Stempel des Containers über die Containment-
-- @note: Kanten parent_script / parent_layout / parent_menu / trigger_owner und
-- @note: has_calculation rückwärts, höchstens zwei Sprünge (Calculation → Step → Script).
-- @note: Nie über parent_folder / contains_menu / groups_into: ein Ordner- oder
-- @note: Menüset-Stempel sagt nichts über den Inhalt. Kein Treffer → keine Zeile.
-- @note: Anzeigename, Person (person_key, Ziel des Autor-Links ins Dashboard „changes")
-- @note: und technischer Autor aus v_change_meta_authors (TEMP-View der API, kuratierte
-- @note: Aliase); Massenereignis aus ChangeBulkEvents.

WITH RECURSIVE up(uuid, file, hop) AS (
    SELECT CAST(getvariable('uuid') AS VARCHAR), CAST(getvariable('file') AS VARCHAR), 0
    UNION ALL
    SELECT CASE WHEN l.Link_Role = 'has_calculation' THEN l.Source_UUID ELSE l.Target_UUID END,
           CASE WHEN l.Link_Role = 'has_calculation' THEN l.Source_File ELSE l.Target_File END,
           up.hop + 1
    FROM up
    JOIN ObjectLinks l
      ON (l.Link_Role IN ('parent_script', 'parent_layout', 'parent_menu', 'trigger_owner')
          AND l.Source_UUID = up.uuid
          AND (up.file IS NULL OR l.Source_File = up.file))
      OR (l.Link_Role = 'has_calculation'
          AND l.Target_UUID = up.uuid
          AND (up.file IS NULL OR l.Target_File = up.file))
    WHERE up.hop < 2
      AND NOT EXISTS (
          SELECT 1 FROM ObjectChangeMeta m0
          WHERE m0.Object_UUID = up.uuid
            AND (up.file IS NULL OR m0.File_Name = up.file))
),
hit AS (
    SELECT m.Object_UUID, m.File_Name, m.Object_Type, m.Object_Name, m.Source_Table,
           m.Modified_At, m.Modified_By, m.Modified_Account, m.Modifications,
           m.Author_Key, m.Author_Kind, m.Bulk_Event_ID, up.hop
    FROM up
    JOIN ObjectChangeMeta m
      ON m.Object_UUID = up.uuid
     AND (up.file IS NULL OR m.File_Name = up.file)
    ORDER BY up.hop, m.File_Name, m.Object_UUID
    LIMIT 1
)
SELECT
    CASE WHEN h.hop = 0 THEN 'own' ELSE 'container' END AS meta_source,
    h.Object_UUID                    AS stamp_uuid,
    h.File_Name                      AS stamp_file,
    h.Object_Type                    AS stamp_type,
    h.Object_Name                    AS stamp_name,
    h.Source_Table                   AS stamp_source_table,
    CAST(h.Modified_At AS VARCHAR)   AS modified_at,
    h.Modified_By                    AS modified_by,
    h.Modified_Account               AS modified_account,
    h.Modifications                  AS modifications,
    h.Author_Key                     AS author_key,
    h.Author_Kind                    AS author_kind,
    a.Display_Name                   AS author_display,
    COALESCE(a.Person_Key, h.Author_Key) AS person_key,
    COALESCE(a.Is_Technical, h.Author_Kind IS NOT NULL) AS author_is_technical,
    b.Bulk_Event_ID                  AS bulk_event_id,
    b.Scope                          AS bulk_scope,
    b.Kind                           AS bulk_kind,
    CAST(b.Start_At AS VARCHAR)      AS bulk_start,
    CAST(b.End_At AS VARCHAR)        AS bulk_end,
    b.Files                          AS bulk_files,
    b.Objects                        AS bulk_objects
FROM hit h
LEFT JOIN v_change_meta_authors a ON a.Author_Key = h.Author_Key
LEFT JOIN ChangeBulkEvents b ON b.Bulk_Event_ID = h.Bulk_Event_ID;
