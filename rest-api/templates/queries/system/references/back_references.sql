-- @template_type: report
-- @description: Cross-Reference Back-Lookup — alle Sources im Destination-Container, die das Origin-Objekt referenzieren
-- @params: destination (required, UUID), origin (required, UUID)
-- @author: Marcel
-- @version: 1.1
-- @tags: references, cross-references, highlight
-- @note: Liefert alle Objekt-UUIDs, die sich INNERHALB des Destination-Containers
--        befinden UND einen operationalen Link auf das Origin haben.
--        Container-Logik:
--          • Destination ist ein Layout       → Sources sind LayoutObjects mit parent_layout
--                                                  ODER Layout direkt (z.B. context_table)
--          • Destination ist ein Script       → Sources sind ScriptSteps mit parent_script
--                                                  ODER Script direkt (z.B. calls_script)
--          • Destination ist eine CustomFunction → Sources sind die CF selbst
--          • Sonst                            → nur direkter Link Destination → Origin
--        Seit 1.1 zusätzlich: Origin = ScriptTrigger-Sub-Knoten → der Trigger-
--        OWNER (LayoutObject) im Destination-Container ist der Match (Fall 3).

WITH destination AS (
  SELECT Object_UUID, Object_Type, Object_Name, File_Name
  FROM ObjectCatalog
  WHERE Object_UUID = getvariable('destination')
  LIMIT 1
),
origin AS (
  SELECT Object_UUID, Object_Type, Object_Name, File_Name
  FROM ObjectCatalog
  WHERE Object_UUID = getvariable('origin')
  LIMIT 1
),
-- Schritt 1: Alle Links, deren Target das Origin ist (operational).
--            Egal von welchem Source — wir filtern danach.
candidate_links AS (
  SELECT
    ol.Source_UUID,
    ol.Source_Type,
    ol.Link_Role
  FROM ObjectLinks ol
  JOIN origin o ON ol.Target_UUID = o.Object_UUID
  WHERE ol.Link_Type = 'operational'
),
-- Schritt 2: Container-Mitgliedschaft prüfen — Logik hängt vom Destination-Typ ab.
--
--   Layout-Container:
--     Nur Container-Kinder (LayoutObjects, parent_layout) zählen. Direkte
--     Layout→Field-Links über `displays_field` sind redundant zu den
--     LayoutObject-Links und würden den Treffer-Counter verdoppeln, weil sie
--     im SVG nicht als separates Objekt sichtbar sind.
--
--   Script / CustomFunction:
--     Token-Container — die Sub-Objekte (ScriptSteps, CF-Tokens) haben keine
--     eigene Sichtbarkeit, sondern werden via Formel-Tokens im Text markiert.
--     Daher: direkter Self-Link Destination→Origin wird als "1 Container-Match"
--     gezählt, repräsentiert die Token-Vorkommen im Text. Die genaue Anzahl
--     erfordert DDR-Chunk-Scan und liefert dieses Template bewusst nicht.
matches AS (
  SELECT
    cl.Source_UUID AS uuid,
    cl.Source_Type AS type,
    cl.Link_Role   AS role,
    oc.Object_Name AS name
  FROM candidate_links cl
  JOIN destination d ON 1=1
  JOIN ObjectCatalog oc ON cl.Source_UUID = oc.Object_UUID
  WHERE
    -- Container-Kinder (Standardfall: Layout → LayoutObjects)
    EXISTS (
      SELECT 1
      FROM ObjectLinks parent
      WHERE parent.Source_UUID = cl.Source_UUID
        AND parent.Target_UUID = d.Object_UUID
        AND parent.Link_Role IN ('parent_layout', 'parent_script', 'parent_object')
    )
    -- Token-Container (Script / CustomFunction): direkter Self-Link zählt.
    OR (
      cl.Source_UUID = d.Object_UUID
      AND d.Object_Type IN ('Script', 'CustomFunction')
    )
)
SELECT DISTINCT uuid, type, role, name
FROM (
  SELECT * FROM matches

  UNION ALL

  -- Pseudo-Typ-Origins:
  -- ScriptStepType + PluginComponent haben keine ObjectLinks-Spiegelung,
  -- daher findet der Standard-Pfad oben sie nicht. Hier matchen wir name-/
  -- Component-basiert auf die konkreten Sub-Knoten im Destination-Container.
  --
  -- Fall 1: Origin = ScriptStepType, Destination = Script
  --   → alle ScriptSteps mit Step_Name = origin.Object_Name innerhalb des Scripts.
  SELECT
    s.Step_UUID            AS uuid,
    'ScriptStep'           AS type,
    'uses_step_type'       AS role,
    s.Step_Name            AS name
  FROM StepsForScripts s
  JOIN origin o      ON o.Object_Type = 'ScriptStepType' AND s.Step_Name = o.Object_Name
  JOIN destination d ON s.Script_UUID = d.Object_UUID    AND d.Object_Type = 'Script'

  UNION ALL

  -- Fall 2: Origin = PluginComponent, Destination = Script / CustomFunction
  --   → alle Container-Kinder (ScriptStep / CF), die eine PluginFunction der
  --     Component aufrufen (zwei-stufig: groups_into × calls_pluginfunction).
  SELECT
    oc.Object_UUID         AS uuid,
    oc.Object_Type         AS type,
    'calls_component'      AS role,
    oc.Object_Name         AS name
  FROM origin o
  JOIN ObjectLinks gi    ON gi.Target_UUID = o.Object_UUID
                        AND gi.Link_Role = 'groups_into'
  JOIN ObjectLinks call  ON call.Target_UUID = gi.Source_UUID
                        AND call.Link_Role = 'calls_pluginfunction'
                        AND call.Link_Type = 'operational'
  JOIN ObjectCatalog oc  ON oc.Object_UUID = call.Source_UUID
  JOIN destination d     ON 1=1
  WHERE o.Object_Type = 'PluginComponent'
    AND (
      -- Sub-Knoten via parent_script/parent_object Link
      EXISTS (
        SELECT 1 FROM ObjectLinks parent
        WHERE parent.Source_UUID = oc.Object_UUID
          AND parent.Target_UUID = d.Object_UUID
          AND parent.Link_Role IN ('parent_layout', 'parent_script', 'parent_object')
      )
      -- Token-Container (Script / CustomFunction): direkter Self-Link
      OR (
        oc.Object_UUID = d.Object_UUID
        AND d.Object_Type IN ('Script', 'CustomFunction')
      )
    )

  UNION ALL

  -- Fall 3: Origin = ScriptTrigger (synthetischer Sub-Knoten `trig_<slot>_…`),
  --   Destination = Layout des Trigger-Owners.
  --   Den Trigger-Knoten referenziert nichts INNERHALB des Layouts — der
  --   Standard-Pfad oben liefert für diese Navigation ("Sub-Knoten → Container
  --   öffnen, Sub-Knoten als ?ref=") also nie ein Highlight. Der sichtbare
  --   Stellvertreter im Canvas ist der OWNER des Triggers: aufgelöst über die
  --   strukturelle trigger_owner-Kante (nie per UUID-Parsing), bewusst NUR für
  --   LayoutObject-Owner — Layout-/File-Trigger behalten ihr bisheriges
  --   Verhalten (Trigger-Liste im Eigenschaften-Panel matcht die trig-UUID).
  --   Owner ohne trigger_owner-Kante (Parser-Lücke PopoverPanel) degradieren
  --   still auf "kein Match" wie bisher.
  SELECT
    own.Target_UUID        AS uuid,
    own.Target_Type        AS type,
    'trigger_owner'        AS role,
    oc.Object_Name         AS name
  FROM origin o
  JOIN ObjectLinks own   ON own.Source_UUID = o.Object_UUID
                        AND own.Source_File = o.File_Name
                        AND own.Link_Role = 'trigger_owner'
                        AND own.Target_Type = 'LayoutObject'
  JOIN destination d     ON 1=1
  JOIN ObjectCatalog oc  ON oc.Object_UUID = own.Target_UUID
                        AND oc.File_Name = own.Target_File
  WHERE o.Object_Type = 'ScriptTrigger'
    AND EXISTS (
      SELECT 1 FROM ObjectLinks parent
      WHERE parent.Source_UUID = own.Target_UUID
        AND parent.Target_UUID = d.Object_UUID
        AND parent.Link_Role IN ('parent_layout', 'parent_object')
    )
) all_matches
ORDER BY type, role, name;
