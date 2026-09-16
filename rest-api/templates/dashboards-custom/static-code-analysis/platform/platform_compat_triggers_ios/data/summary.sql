-- Hand-maintained COUNT wrapper embedding the findings core of rule (platform_compat_triggers_ios).
-- The core is a textual copy - keep filters (file filter + S-Block) in sync with data/findings.sql.
SELECT
    COUNT(*) AS finding_count,
    COUNT(*) FILTER (WHERE severity = 'error')   AS not_supported,
    COUNT(*) FILTER (WHERE severity = 'warning') AS partial_support,
    COUNT(*) FILTER (WHERE severity = 'info')    AS no_statement,
    COUNT(DISTINCT file_name) AS affected_files
FROM (
SELECT 'platform-ios-triggers' AS rule_id,
    CASE WHEN c.trigger_id IS NULL THEN 'info'
         WHEN c.go = false THEN 'error'
         ELSE 'warning' END AS severity,
    t.File_Name AS file_name, t.Script_UUID AS nav_uuid, t.Script_Name AS script_name,
    COALESCE(st.event_name, 'Trigger ' || t.Trigger_ID) AS trigger_event,
    t.Owner_Type AS owner_type,
    CASE t.Owner_Type
         WHEN 'Layout'       THEN COALESCE(l.L_Name, t.Owner_UUID)
         WHEN 'LayoutObject' THEN COALESCE(NULLIF(trim(lo.Object_Name), ''), COALESCE(lo.Object_Type, 'object') || ' (unnamed)')
         ELSE t.File_Name END AS owner_name,
    COALESCE(l.L_Name, lol.L_Name) AS layout_name,
    'trig_' || t.Trigger_ID || '_' || t.Owner_UUID || '_' || t.File_Name AS trigger_uuid,
    lower(COALESCE(st.event_name, '')) AS doc_slug,
    CASE WHEN c.trigger_id IS NULL
         THEN COALESCE(st.event_name, 'Trigger ' || t.Trigger_ID) || ' has no published compatibility row for FileMaker Go (iOS) (reference older than fm-spec 2.8.0)'
         WHEN c.go = false
         THEN COALESCE(st.event_name, 'Trigger ' || t.Trigger_ID) || ' does not fire in FileMaker Go (iOS)'
         ELSE COALESCE(st.event_name, 'Trigger ' || t.Trigger_ID) || ' fires only PARTIALLY in FileMaker Go (iOS) - conditionally supported, see the trigger notes on its Claris help page'
    END AS message,
    row_number() OVER (ORDER BY t.File_Name, t.Script_Name, t.Trigger_ID, t.Owner_UUID) AS row_key
FROM ScriptTriggers t
LEFT JOIN ref.script_triggers st ON st.trigger_id = t.Trigger_ID          -- slot id, never Trigger_Action
LEFT JOIN ref.trigger_compat  c  ON c.trigger_id  = t.Trigger_ID
LEFT JOIN Layouts l ON t.Owner_Type = 'Layout' AND l.L_UUID = t.Owner_UUID AND l.File_Name = t.File_Name
LEFT JOIN (
    SELECT Object_UUID, Layout_ID, File_Name, Object_Type, Object_Name,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
) lo ON t.Owner_Type = 'LayoutObject' AND lo.Object_UUID = t.Owner_UUID AND lo.File_Name = t.File_Name AND lo.rn = 1
LEFT JOIN Layouts lol ON lo.Layout_ID = lol.L_ID AND lol.File_Name = lo.File_Name
WHERE t.Script_UUID IS NOT NULL
  AND (c.trigger_id IS NULL OR c.go = false OR c.go IS NULL)
  AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR t.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
       OR t.Owner_UUID  IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
       OR COALESCE(l.L_UUID, lol.L_UUID) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
) _summary;
