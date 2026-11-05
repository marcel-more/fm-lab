-- File-level script triggers (OnFirstWindowOpen / OnLastWindowClose / OnWindowClose …).
-- Row click → openObject on the triggered script (Script_UUID = ObjectCatalog.Object_UUID).
SELECT
    t.Trigger_Action,
    t.Script_Name  AS target_name,
    t.Script_UUID  AS target_uuid,
    t.File_Name
FROM ScriptTriggers t
WHERE t.File_Name = :file
  AND t.Owner_Type = 'File'
ORDER BY t.Trigger_Action;
