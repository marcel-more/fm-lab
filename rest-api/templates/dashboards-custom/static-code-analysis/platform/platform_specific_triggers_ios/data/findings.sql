-- Platform-binding inventory (axis b), trigger evidence: scripts attached to
-- an event that exists ONLY in FileMaker Go (iOS). Exclusivity is derived from
-- ref.trigger_compat (fm_spec >= 2.8.0) with the same strict predicate as the
-- step evidence of platform_specific_ios: go = true AND every other runtime
-- column strictly false (NULL = Partial elsewhere disqualifies) - no slot-id
-- literals, the predicate follows future reference versions. Neutral by
-- design: severity 'info', findings are properties, never defects.
SELECT 'platform-ios-specific-triggers' AS rule_id, 'info' AS severity,
    t.File_Name AS file_name, t.Script_UUID AS nav_uuid, t.Script_Name AS script_name,
    st.event_name AS trigger_event, t.Owner_Type AS owner_type,
    CASE t.Owner_Type
         WHEN 'Layout'       THEN COALESCE(l.L_Name, t.Owner_UUID)
         WHEN 'LayoutObject' THEN COALESCE(NULLIF(trim(lo.Object_Name), ''), COALESCE(lo.Object_Type, 'object') || ' (unnamed)')
         ELSE t.File_Name END AS owner_name,
    COALESCE(l.L_Name, lol.L_Name) AS layout_name,
    'trig_' || t.Trigger_ID || '_' || t.Owner_UUID || '_' || t.File_Name AS trigger_uuid,
    lower(st.event_name) AS doc_slug,
    st.event_name || ' fires only in FileMaker Go (iOS) - the script is bound to the iOS runtime' AS message,
    row_number() OVER (ORDER BY t.File_Name, t.Script_Name, t.Trigger_ID, t.Owner_UUID) AS row_key
FROM ScriptTriggers t
JOIN ref.trigger_compat c ON c.trigger_id = t.Trigger_ID
JOIN ref.script_triggers st ON st.trigger_id = t.Trigger_ID
LEFT JOIN Layouts l ON t.Owner_Type = 'Layout' AND l.L_UUID = t.Owner_UUID AND l.File_Name = t.File_Name
LEFT JOIN (
    SELECT Object_UUID, Layout_ID, File_Name, Object_Type, Object_Name,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
) lo ON t.Owner_Type = 'LayoutObject' AND lo.Object_UUID = t.Owner_UUID AND lo.File_Name = t.File_Name AND lo.rn = 1
LEFT JOIN Layouts lol ON lo.Layout_ID = lol.L_ID AND lol.File_Name = lo.File_Name
WHERE t.Script_UUID IS NOT NULL
  -- strict exclusivity from the table: Go yes, EVERY other runtime strictly No
  -- (NULL = Partial elsewhere disqualifies); no hard-coded slot ids
  AND c.go = true AND c.pro = false AND c.server = false AND c.webdirect = false
  AND c.cloud = false AND c.dataapi = false AND c.cwp = false
  AND (getvariable('file') IS NULL OR t.File_Name = getvariable('file'))
  AND (getvariable('scope_uuids') IS NULL
       OR t.Script_UUID IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
       OR t.Owner_UUID  IN (SELECT unnest(string_split(getvariable('scope_uuids'), ',')))
       OR COALESCE(l.L_UUID, lol.L_UUID) IN (SELECT unnest(string_split(getvariable('scope_uuids'), ','))))
ORDER BY file_name, script_name, trigger_event
LIMIT CAST(COALESCE(getvariable('limit'), '500') AS INTEGER);
