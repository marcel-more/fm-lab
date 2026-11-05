-- @template_type: report
-- @title: Graph Trace Entries (Einstiegspfad-Presets)
-- @description: Preset-Vorschau für /api/graph/trace — je Einstiegspfad die Seed-Zahl und eine Namens-Stichprobe, damit Frontend/Skill die Pfad-Auswahl VOR dem ersten Trace anbieten können
-- @params: start (required, UUID), start_file
-- @version: 1.0.0
-- @author: Marcel / Claude
-- @tags: graph, trace, explorer
-- @note: Begleit-Endpoint GET /api/graph/trace/entries. v1 liefert nur für
--        Layout-Starts eine echte Auswahl (layout_runtime / layout_inbound /
--        layout_full); ein Script-Start liefert das triviale Preset 'script'.
--        Andere Objekttypen → 0 Zeilen (Controller antwortet mit v2-Hinweis).
--        Seed-Ableitung deckungsgleich mit graph_trace.sql Stufe 0 —
--        Änderungen dort MÜSSEN hier gespiegelt werden.
--
-- AUSGABE — eine Zeile je verfügbarem Preset:
--   entry        Preset-Schlüssel ('script' | 'layout_runtime' | 'layout_inbound' | 'layout_full')
--   is_default   TRUE beim typabhängigen Default-Preset
--   seed_count   Anzahl distinkter Seed-Scripts
--   seeds_sample JSON-Array der ersten 5 Seed-Script-Namen (alphabetisch)

WITH
start_seed AS (
  SELECT
    getvariable('start') AS uuid,
    COALESCE(
      NULLIF(CAST(getvariable('start_file') AS VARCHAR), ''),
      (SELECT File_Name FROM ObjectCatalog WHERE Object_UUID = getvariable('start') LIMIT 1)
    ) AS file
),
start_obj AS (
  SELECT s.uuid, s.file, oc.Object_Type AS otype, oc.Object_Name AS oname
  FROM start_seed s
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = s.uuid AND oc.File_Name IS NOT DISTINCT FROM s.file
  LIMIT 1
),
-- Runtime-Seeds — Event-Trigger des Layouts + seiner LayoutObjects + Buttons
-- (Spiegel von seed_trigger_edges in graph_trace.sql).
runtime_seeds AS (
  SELECT DISTINCT rl.Target_UUID AS uuid, rl.Target_File AS file
  FROM ObjectLinks rl, start_obj s
  WHERE s.otype = 'Layout'
    AND rl.Link_Role = 'triggers_script'
    AND ((rl.Source_Type = 'Layout'
          AND rl.Source_UUID = s.uuid AND rl.Source_File IS NOT DISTINCT FROM s.file)
         OR (rl.Source_Type = 'LayoutObject'
             AND (rl.Source_UUID, COALESCE(rl.Source_File, '')) IN (
               SELECT pl.Source_UUID, COALESCE(pl.Source_File, '')
               FROM ObjectLinks pl, start_obj s2
               WHERE pl.Link_Role = 'parent_layout' AND pl.Source_Type = 'LayoutObject'
                 AND pl.Target_UUID = s2.uuid AND pl.Target_File IS NOT DISTINCT FROM s2.file)))
),
-- Inbound-Seeds — Scripts mit navigates_to_layout auf das Start-Layout
-- (Spiegel von seed_nav_edges in graph_trace.sql).
inbound_seeds AS (
  SELECT DISTINCT rl.Source_UUID AS uuid, rl.Source_File AS file
  FROM ObjectLinks rl, start_obj s
  WHERE s.otype = 'Layout'
    AND rl.Link_Role = 'navigates_to_layout'
    AND rl.Source_Type = 'Script'
    AND rl.Target_UUID = s.uuid AND rl.Target_File IS NOT DISTINCT FROM s.file
),
full_seeds AS (
  SELECT uuid, file FROM runtime_seeds
  UNION
  SELECT uuid, file FROM inbound_seeds
),
named AS (
  SELECT kind, oc.Object_Name AS name
  FROM (
    SELECT 'layout_runtime' AS kind, uuid, file FROM runtime_seeds
    UNION ALL SELECT 'layout_inbound', uuid, file FROM inbound_seeds
    UNION ALL SELECT 'layout_full', uuid, file FROM full_seeds
  ) x
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = x.uuid AND oc.File_Name IS NOT DISTINCT FROM x.file
),
named_agg AS (
  SELECT kind, COUNT(*) AS seed_count, to_json(list_slice(list(name ORDER BY name), 1, 5)) AS seeds_sample
  FROM named GROUP BY kind
)
SELECT entry, is_default, seed_count, seeds_sample
FROM (
  SELECT 'script' AS entry, TRUE AS is_default, 1 AS seed_count,
         to_json([(SELECT oname FROM start_obj)]) AS seeds_sample
  FROM start_obj WHERE otype = 'Script'
  UNION ALL
  -- Layout-Presets IMMER als drei Zeilen — auch mit 0 Seeds (Frontend zeigt Zähler).
  SELECT p.kind AS entry,
         (p.kind = 'layout_runtime') AS is_default,
         COALESCE(na.seed_count, 0) AS seed_count,
         COALESCE(na.seeds_sample, to_json([])) AS seeds_sample
  FROM (SELECT unnest(['layout_runtime', 'layout_inbound', 'layout_full']) AS kind) p
  LEFT JOIN named_agg na ON na.kind = p.kind
  WHERE (SELECT otype FROM start_obj) = 'Layout'
)
ORDER BY CASE entry
  WHEN 'script' THEN 0 WHEN 'layout_runtime' THEN 1
  WHEN 'layout_inbound' THEN 2 ELSE 3 END;
