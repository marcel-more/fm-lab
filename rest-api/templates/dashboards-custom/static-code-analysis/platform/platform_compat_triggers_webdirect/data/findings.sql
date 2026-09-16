-- Trigger-compatibility check against the Claris tri-state table trigger_compat
-- (fm_spec >= 2.8.0), ATTACHed as 'ref' by the API connection; the fm-test
-- direct path attaches it itself. Join over the SLOT ID (ScriptTriggers.Trigger_ID
-- = trigger_id) - NEVER over Trigger_Action, a raw, localizable passthrough.
-- Severity model as platform_compat_*: false = 'No' -> error; NULL = 'Partial'
-- -> warning (NEVER 'undocumented'); missing row (older reference) -> info.
-- Scope: the script (nav_uuid), the owner object and the owner's layout all
-- admit a row, so layout scope reaches object-level triggers too.
SELECT 'platform-webdirect-triggers' AS rule_id,
    CASE WHEN c.trigger_id IS NULL THEN 'info'
         WHEN c.webdirect = false THEN 'error'
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
         THEN COALESCE(st.event_name, 'Trigger ' || t.Trigger_ID) || ' has no published compatibility row for FileMaker WebDirect (reference older than fm-spec 2.8.0)'
         WHEN c.webdirect = false
         THEN COALESCE(st.event_name, 'Trigger ' || t.Trigger_ID) || ' does not fire in FileMaker WebDirect'
         ELSE COALESCE(st.event_name, 'Trigger ' || t.Trigger_ID) || ' fires only PARTIALLY in FileMaker WebDirect - conditionally supported, see the trigger notes on its Claris help page'
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
  AND (c.trigger_id IS NULL OR c.webdirect = false OR c.webdirect IS NULL)
  AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR t.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
       OR t.Owner_UUID  IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
       OR COALESCE(l.L_UUID, lol.L_UUID) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, file_name, script_name, trigger_event
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
