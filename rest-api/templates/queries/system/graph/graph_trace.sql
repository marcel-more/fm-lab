-- @template_type: report
-- @title: Graph Trace (Selective Flow Walk)
-- @description: Selektiver Ablauf-Graph ab einem Startobjekt — Callchain auf-/abwärts, berührte Objekte der Chain-Scripts, Kontext-Trigger betretener Layouts (budgetierte Kaskade)
-- @params: start (required, UUID), start_file, entry, up_depth, down_depth, trigger_depth, expand_up, include_local_vars, include_buttons, include_builtins, include_interaction_triggers, node_limit, hub_degree, exclude
-- @version: 1.3.0
-- @author: Marcel / Claude
-- @tags: graph, trace, explorer
-- @note: 1.3.0 (Event-Klassen-Weiche + Feld-Exclude):
--        Interaktions-Events zünden per Default keine Kaskade mehr
--        (interaction_events-CTE, Opt-in include_interaction_triggers;
--        Stufe-0-Presets unberührt); ausgeschlossene Felder fallen aus
--        fields0/1/2 und schalten keine Objekt-Trigger mehr scharf.
--        Core-Endpoint /api/graph/trace. Komplementär zu graph_subgraph.sql —
--        traversiert NICHT breitensuchend über alle Kanten, sondern entlang einer
--        rollenbasierten Ablauf-Heuristik in vier Stufen (Chain → Touch →
--        Kontext-Trigger → Kantenbildung). Arbeitet auf rohen ObjectLinks
--        (Orphan-gefiltert); Knotenidentität ist (UUID, File_Name) wie im
--        Subgraph-Template — composite Node-id `uuid` + `::` + `file`.
--
-- ============================================================================
-- PARAMETER (von graph.service.js via Joi mit Defaults gesetzt, string-interpoliert)
-- ============================================================================
--   start              UUID des Startobjekts                        (Pflicht)
--   start_file         File_Name des Starts (Klon-Disambiguierung)  (Default NULL)
--   entry              Einstiegspfad-Preset für Layout-Starts       (Default NULL → layout_runtime)
--                      'layout_runtime' | 'layout_inbound' | 'layout_full'; Script ignoriert das Preset
--   up_depth           Chain-Budget aufwärts                        (Default 3)
--   down_depth         Chain-Budget abwärts                         (Default 6)
--   trigger_depth      Trigger-Kaskadenstufen 0..3                  (Default 1)
--   expand_up          TRUE expandiert auch Upstream-Chain-Touch    (Default FALSE)
--   include_local_vars TRUE nimmt lokale $-Variablen mit            (Default FALSE)
--   include_buttons    TRUE nimmt button_action in Stufe 3 mit      (Default FALSE)
--   include_builtins   TRUE nimmt calls_function-Ziele mit          (Default FALSE)
--   include_interaction_triggers                                    (Default FALSE)
--                      TRUE nimmt Interaktions-Events in die Kaskade —
--                      per Default sind sie ausgeschlossen, weil sie während
--                      eines Script-Ablaufs nicht feuern (siehe interaction_events).
--   node_limit         harter Knoten-Deckel                         (Default 1000)
--   hub_degree         Grad-Schwelle für isHub-Markierung           (Default 100)
--   exclude            Boundary-Ausschlussliste: komma-             (Default NULL)
--                      separierte Composite-IDs (`uuid` + `::` + `file`; ohne
--                      `::`-Teil = File_Name NULL). Ausgeschlossene Knoten werden
--                      eingesammelt und bleiben sichtbar (is_excluded = TRUE),
--                      aber es wird nicht AUS ihnen traversiert (Chain + Kaskade),
--                      sie liefern keine Touch-Kanten, und ausgeschlossene Layouts
--                      zünden keine Trigger-Kaskade. Der Start ist nie ausschließbar.
--
-- CLI-Test (getvariable existiert in DuckDB nativ) —
--   SET VARIABLE start = '…'; SET VARIABLE start_file = NULL; SET VARIABLE entry = NULL;
--   SET VARIABLE up_depth = 3; SET VARIABLE down_depth = 6; SET VARIABLE trigger_depth = 1;
--   SET VARIABLE expand_up = FALSE; SET VARIABLE include_local_vars = FALSE;
--   SET VARIABLE include_buttons = FALSE; SET VARIABLE include_builtins = FALSE;
--   SET VARIABLE include_interaction_triggers = FALSE;
--   SET VARIABLE node_limit = 1000; SET VARIABLE hub_degree = 100; SET VARIABLE exclude = NULL;
--
-- ============================================================================
-- AUSGABE — getaggte Union (row_kind), die der Service partitioniert.
--   row_kind='node' → nodes[]  (wie Subgraph + trace_role, trace_depth)
--   row_kind='edge' → edges[]  (wie Subgraph + trace_kind)
--   row_kind='seed' → seeds[]  (Seed-Scripts der Stufe 0 — Payload data.trace.seeds)
-- `total_reachable` = Knotenmenge VOR dem Deckel (truncated-Erkennung);
-- `dynamic_calls`   = Call-Steps der Chain-Scripts ohne statisches Ziel
--                     (Perform Script / on Server / with Callback „by name",
--                      Slot 'List' in StepCalculations) — ehrlicher Blind-Spot.
-- ============================================================================

WITH RECURSIVE
-- 1) Roh-Kanten mit Waisen-Filter — beide Endpunkte katalogisiert; Typ + Datei
--    mitführen. Vorab auf die Trace-relevanten Rollen gefiltert und MATERIALIZED —
--    die CTE wird ~20× referenziert; ohne Rollen-Schnitt + Materialisierung
--    wiederholt sich der Orphan-Semi-Join über die volle ObjectLinks je Referenz
--    (gemessen auf dem Großkorpus der Unterschied zwischen ~1,4 s und < 1 s).
raw_links AS MATERIALIZED (
  SELECT
    Source_UUID AS a, Source_Type AS a_type, Source_File AS a_file,
    Target_UUID AS b, Target_Type AS b_type, Target_File AS b_file,
    Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM ObjectLinks
  WHERE Link_Role IN (
      'calls_script', 'triggers_script', 'parent_layout', 'displays_field',
      'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
      'navigates_to_field', 'inputs_to_field', 'imports_to_field',
      'exports_from_field', 'references_field',
      'navigates_to_layout', 'navigates_to_to',
      'sorts_by_valuelist', 'installs_menuset',
      'calls_customfunction', 'calls_pluginfunction', 'calls_function',
      'sets_variable', 'reads_variable',
      'displays_variable', 'context_table', 'uses_valuelist')
    AND Source_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
    AND Target_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
),
-- 2) Start-Auflösung (Klon-robust wie focus_seed im Subgraph). Der Controller hat
--    Existenz + Eindeutigkeit bereits geprüft (404/409) — LIMIT 1 ist Gurt.
start_seed AS (
  SELECT
    getvariable('start') AS uuid,
    COALESCE(
      NULLIF(CAST(getvariable('start_file') AS VARCHAR), ''),
      (SELECT File_Name FROM ObjectCatalog WHERE Object_UUID = getvariable('start') LIMIT 1)
    ) AS file
),
start_obj AS (
  SELECT s.uuid, s.file, oc.Object_Type AS otype
  FROM start_seed s
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = s.uuid AND oc.File_Name IS NOT DISTINCT FROM s.file
  LIMIT 1
),
-- 2b) Exclude-Liste — Boundary-Semantik, siehe Parameterdoku oben.
--     file_key '' steht für File_Name NULL (gleiche Konvention wie die
--     COALESCE-Vergleiche der Walks). Der Start selbst wird herausgefiltert
--     (Guard), damit ein stehengebliebener Ausschluss einen späteren Trace
--     desselben Objekts nicht leer laufen lässt.
excluded AS (
  SELECT x.uuid, x.file_key
  FROM (
    SELECT
      split_part(item, '::', 1) AS uuid,
      CASE WHEN contains(item, '::')
           THEN substr(item, length(split_part(item, '::', 1)) + 3)
           ELSE '' END AS file_key
    FROM (SELECT unnest(string_split(COALESCE(CAST(getvariable('exclude') AS VARCHAR), ''), ',')) AS item)
    WHERE trim(item) <> ''
  ) x
  WHERE NOT EXISTS (SELECT 1 FROM start_seed s
                    WHERE s.uuid = x.uuid AND COALESCE(s.file, '') = x.file_key)
),
-- 2c) Interaktions-Event-Klasse — Events, die NUR durch Benutzer-
--     Interaktion feuern und deshalb per Default aus den Kaskadenstufen 1-3
--     herausgehalten werden (ein Script drückt keine Tasten). Stufe 0
--     (layout_runtime-Preset) bleibt bewusst unberührt — dort sind sie
--     legitime Einstiegspfade (Button-Symmetrie).
--     Klassifikation 2026-09-03 gegen die lokale Claris-Hilfe verifiziert —
--     - OnLayoutKeystroke / OnObjectKeystroke — "characters entered from the
--       keyboard" — rein Tastatur, kein Script-Pfad → Interaktionsklasse.
--     - OnGestureTap — Touch-Geste (Go/iPad) → Interaktionsklasse.
--     - OnExternalCommandReceived — Lockscreen-/Gerätetasten → Interaktionsklasse.
--     - OnObjectModify — überwiegend Nutzereingabe; die Hilfe nennt zwar
--       "script steps such as Insert Text" als möglichen Auslöser (enge
--       Randbedingung — aktives Objekt nötig), bleibt es bei der Klasse; der
--       Opt-in-Schalter deckt den Randfall.
--     Verifiziert NICHT in der Klasse (script-erreichbar, bleiben in der Kaskade) —
--     - OnLayoutSizeChange ("by script step", Fenster-Steps/erstes Öffnen),
--     - OnObjectAVPlayerChange / OnFileAVPlayerChange (AVPlayer Play /
--       Set Playback State Steps),
--     - OnLayoutEnter/Exit, OnRecordLoad/Commit/Revert, OnModeEnter/Exit,
--       OnObjectEnter/Exit/Save/Validate, OnPanelSwitch, OnViewChange.
interaction_events AS (
  SELECT unnest(['OnLayoutKeystroke', 'OnObjectKeystroke', 'OnGestureTap',
                 'OnObjectModify', 'OnExternalCommandReceived']) AS event
),
-- 3) Einstiegspfad — Script-Starts ignorieren das Preset; Layout-Default layout_runtime.
entry_sel AS (
  SELECT CASE
    WHEN (SELECT otype FROM start_obj) = 'Script' THEN 'script'
    ELSE COALESCE(NULLIF(CAST(getvariable('entry') AS VARCHAR), ''), 'layout_runtime')
  END AS entry
),
-- ============================================================================
-- STUFE 0 — Start-Normalisierung → Seed-Scripts S0 (+ Seed-Kanten für die Ausgabe)
-- ============================================================================
-- LayoutObjects unter dem Start-Layout (Objekt-Trigger gehören zum Runtime-Preset).
start_layout_children AS (
  SELECT rl.a AS uuid, COALESCE(rl.a_file, '') AS file
  FROM raw_links rl
  JOIN start_obj s ON rl.b = s.uuid AND rl.b_file IS NOT DISTINCT FROM s.file
  WHERE s.otype = 'Layout' AND rl.Link_Role = 'parent_layout' AND rl.a_type = 'LayoutObject'
),
-- layout_runtime — Event-Trigger des Layouts + seiner Objekte + Button-Scripts.
-- Buttons sind hier legitimer Einstiegspfad (Teil des Presets, NICHT include_buttons).
seed_trigger_edges AS (
  SELECT rl.a, rl.a_type, rl.a_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl, start_obj s
  WHERE s.otype = 'Layout'
    AND (SELECT entry FROM entry_sel) IN ('layout_runtime', 'layout_full')
    AND rl.Link_Role = 'triggers_script'
    AND ((rl.a_type = 'Layout' AND rl.a = s.uuid AND rl.a_file IS NOT DISTINCT FROM s.file)
         OR (rl.a_type = 'LayoutObject'
             AND (rl.a, COALESCE(rl.a_file, '')) IN (SELECT uuid, file FROM start_layout_children)))
),
-- layout_inbound — Scripts, die auf das Start-Layout navigieren.
seed_nav_edges AS (
  SELECT rl.a, rl.a_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl, start_obj s
  WHERE s.otype = 'Layout'
    AND (SELECT entry FROM entry_sel) IN ('layout_inbound', 'layout_full')
    AND rl.Link_Role = 'navigates_to_layout'
    AND rl.a_type = 'Script'
    AND rl.b = s.uuid AND rl.b_file IS NOT DISTINCT FROM s.file
),
seeds AS (
  SELECT uuid, file FROM start_obj WHERE otype = 'Script'
  UNION
  SELECT b, b_file FROM seed_trigger_edges
  UNION
  SELECT a, a_file FROM seed_nav_edges
),
-- ============================================================================
-- STUFE 1 — Chain-Kern (calls_script auf/ab). Zyklenschutz wie im Subgraph-
-- Template — UNION (nicht ALL) dedupliziert (uuid, file, d); Zyklen terminieren
-- am Tiefendeckel, Diamanten falten pro Tiefe zusammen (deutlich schneller als
-- Pfad-Arrays auf den Real-Korpora; MIN(d) liefert dieselbe Tiefe).
-- ============================================================================
chain_down_walk AS (
  SELECT uuid, file, 0 AS d FROM seeds
  UNION
  SELECT e.b, e.b_file, w.d + 1
  FROM chain_down_walk w
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.a = w.uuid AND e.a_file IS NOT DISTINCT FROM w.file
  WHERE w.d < CAST(getvariable('down_depth') AS INT)
    -- Exclude-Stopp: der ausgeschlossene Knoten wird noch eingesammelt
    -- (als e.b des Aufrufers), aber nicht weiter expandiert.
    AND (w.uuid, COALESCE(w.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
chain_down AS (
  SELECT uuid, file, MIN(d) AS d FROM chain_down_walk GROUP BY uuid, file
),
chain_up_walk AS (
  SELECT uuid, file, 0 AS d FROM seeds
  UNION
  SELECT e.a, e.a_file, w.d + 1
  FROM chain_up_walk w
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.b = w.uuid AND e.b_file IS NOT DISTINCT FROM w.file
  WHERE w.d < CAST(getvariable('up_depth') AS INT)
    AND (w.uuid, COALESCE(w.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
-- Aufwärts-Knoten ohne die schon abwärts erreichten (down gewinnt die Rolle).
chain_up AS (
  SELECT uuid, file, MIN(d) AS d
  FROM chain_up_walk
  WHERE d > 0
    AND (uuid, COALESCE(file, '')) NOT IN (SELECT uuid, COALESCE(file, '') FROM chain_down)
  GROUP BY uuid, file
),
chain_all AS (
  SELECT uuid, file, d FROM chain_down
  UNION ALL
  SELECT uuid, file, -d FROM chain_up
),
-- Feld-Anker-Konvention — LayoutObject, das GENAU ein Feld anzeigt, wird als
-- dieses Feld dargestellt; sonst als sein Layout; button_action immer Layout.
lo_field_anchor AS (
  SELECT a AS lo, COALESCE(a_file, '') AS lo_file, MIN(b) AS f_uuid, MIN(b_file) AS f_file
  FROM raw_links
  WHERE Link_Role = 'displays_field' AND a_type = 'LayoutObject'
  GROUP BY 1, 2
  HAVING COUNT(DISTINCT b || '~' || COALESCE(b_file, '')) = 1
),
lo_parent AS (
  SELECT a AS lo, COALESCE(a_file, '') AS lo_file, b AS layout_uuid, b_file AS layout_file
  FROM raw_links
  WHERE Link_Role = 'parent_layout' AND a_type = 'LayoutObject'
),
-- Trigger-Owner der Chain-Scripts als Kontextknoten (v1-Ende der Up-Traversierung).
-- Synthetische, GEHOBENE Kante Owner → Script (Objekt-Ebene per Feld-Anker-Konvention).
owner_edges_raw AS (
  SELECT
    CASE
      WHEN ts.a_type = 'LayoutObject' AND ts.Link_Subrole IS DISTINCT FROM 'button_action'
           AND fa.f_uuid IS NOT NULL THEN fa.f_uuid
      WHEN ts.a_type = 'LayoutObject' THEN lp.layout_uuid
      ELSE ts.a
    END AS src_uuid,
    CASE
      WHEN ts.a_type = 'LayoutObject' AND ts.Link_Subrole IS DISTINCT FROM 'button_action'
           AND fa.f_uuid IS NOT NULL THEN fa.f_file
      WHEN ts.a_type = 'LayoutObject' THEN lp.layout_file
      ELSE ts.a_file
    END AS src_file,
    ts.b AS dst_uuid, ts.b_file AS dst_file,
    ts.Link_Role, ts.Link_Subrole, ts.Link_Type, ts.Is_Cross_File,
    c.d AS script_d
  FROM raw_links ts
  JOIN chain_all c ON ts.b = c.uuid AND ts.b_file IS NOT DISTINCT FROM c.file
  LEFT JOIN lo_field_anchor fa ON ts.a_type = 'LayoutObject' AND fa.lo = ts.a AND fa.lo_file = COALESCE(ts.a_file, '')
  LEFT JOIN lo_parent lp       ON ts.a_type = 'LayoutObject' AND lp.lo = ts.a AND lp.lo_file = COALESCE(ts.a_file, '')
  WHERE ts.Link_Role = 'triggers_script'
    AND CAST(getvariable('up_depth') AS INT) >= 1
),
owner_edges AS (
  SELECT * FROM owner_edges_raw WHERE src_uuid IS NOT NULL
),
-- ============================================================================
-- STUFE 2 — Touch-Expansion (Level 0). Nur Kanten mit Source_Type='Script'
-- (die Script→Objekt-Projektion liegt owner-projiziert bereits in ObjectLinks).
-- ============================================================================
touch_src0 AS (
  SELECT uuid, file, d FROM chain_down
  UNION
  SELECT uuid, file, d FROM chain_up WHERE getvariable('expand_up') = TRUE
),
touch_edges0 AS (
  SELECT rl.a, rl.a_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
         MIN(ts.d) AS src_d
  FROM raw_links rl
  JOIN touch_src0 ts ON rl.a = ts.uuid AND rl.a_file IS NOT DISTINCT FROM ts.file
  WHERE rl.a_type = 'Script'
    -- Exclude: ausgeschlossene Scripts liefern keine Touch-Kanten.
    AND (rl.a, COALESCE(rl.a_file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND (
      rl.Link_Role IN (
        'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
        'navigates_to_field', 'inputs_to_field', 'imports_to_field',
        'exports_from_field', 'references_field',
        'navigates_to_layout', 'navigates_to_to',
        'sorts_by_valuelist', 'installs_menuset',
        'calls_customfunction', 'calls_pluginfunction')
      OR (rl.Link_Role = 'calls_function' AND getvariable('include_builtins') = TRUE)
      OR (rl.Link_Role IN ('sets_variable', 'reads_variable')
          AND (getvariable('include_local_vars') = TRUE
               OR EXISTS (SELECT 1 FROM ObjectCatalog vt
                          WHERE vt.Object_UUID = rl.b
                            AND vt.File_Name IS NOT DISTINCT FROM rl.b_file
                            AND vt.Object_Name LIKE '$$%')))
    )
  GROUP BY ALL
),
-- Getracete Felder — schalten in Stufe 3 die selektiven Objekt-Trigger scharf.
-- Feld-Exclude: ausgeschlossene Felder fallen aus fields0/1/2 —
-- der Feld-Knoten bleibt sichtbar (Touch-Ziel + is_excluded-Badge), aber
-- Objekt-Trigger, die NUR über dieses Feld scharf würden, zünden nicht.
fields0 AS (
  SELECT DISTINCT b AS uuid, COALESCE(b_file, '') AS file FROM touch_edges0
  WHERE Link_Role IN ('sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
                      'navigates_to_field', 'inputs_to_field', 'imports_to_field',
                      'exports_from_field', 'references_field')
    AND (b, COALESCE(b_file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
layouts0 AS (
  SELECT DISTINCT b AS uuid, b_file AS file FROM touch_edges0 WHERE Link_Role = 'navigates_to_layout'
),
-- ============================================================================
-- STUFE 3 — Kontext-Trigger betretener Layouts, Kaskadenstufe 1
-- (Stufen 2 + 3 der Kaskade sind unten entrollt; Cap trigger_depth = 3)
-- ============================================================================
trig_edges1 AS (
  -- Event-Trigger der Layout-Ebene (File-Trigger bewusst aus — zu global).
  SELECT rl.a AS src_uuid, rl.a_file AS src_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl
  JOIN layouts0 l ON rl.a = l.uuid AND rl.a_file IS NOT DISTINCT FROM l.file
  WHERE CAST(getvariable('trigger_depth') AS INT) >= 1
    -- Exclude: ausgeschlossene Layouts zünden keine Kaskade.
    AND (l.uuid, COALESCE(l.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND rl.Link_Role = 'triggers_script' AND rl.a_type = 'Layout'
    AND (getvariable('include_buttons') = TRUE OR rl.Link_Subrole IS DISTINCT FROM 'button_action')
    -- Event-Klassen-Weiche: Interaktions-Events zünden keine Kaskade.
    AND (getvariable('include_interaction_triggers') = TRUE
         OR COALESCE(rl.Link_Subrole, '') NOT IN (SELECT event FROM interaction_events))
  UNION
  -- Objekt-Trigger SELEKTIV — nur Objekte, die ein bereits getracetes Feld anzeigen
  -- (genau das ist die Selektivität des Features). Kante per Feld-Anker gehoben.
  -- button_action nur per include_buttons (dann alle Buttons des Layouts, Quelle Layout).
  SELECT
    COALESCE(CASE WHEN rl.Link_Subrole IS DISTINCT FROM 'button_action' THEN fa.f_uuid END, lp.layout_uuid),
    COALESCE(CASE WHEN rl.Link_Subrole IS DISTINCT FROM 'button_action' THEN fa.f_file END, lp.layout_file),
    rl.b, rl.b_file, rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl
  JOIN lo_parent lp ON lp.lo = rl.a AND lp.lo_file = COALESCE(rl.a_file, '')
  JOIN layouts0 l ON lp.layout_uuid = l.uuid AND lp.layout_file IS NOT DISTINCT FROM l.file
  LEFT JOIN lo_field_anchor fa ON fa.lo = rl.a AND fa.lo_file = COALESCE(rl.a_file, '')
  WHERE CAST(getvariable('trigger_depth') AS INT) >= 1
    AND (l.uuid, COALESCE(l.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND rl.Link_Role = 'triggers_script' AND rl.a_type = 'LayoutObject'
    -- Event-Klassen-Weiche: Interaktions-Events zünden keine Kaskade.
    AND (getvariable('include_interaction_triggers') = TRUE
         OR COALESCE(rl.Link_Subrole, '') NOT IN (SELECT event FROM interaction_events))
    AND ((rl.Link_Subrole = 'button_action' AND getvariable('include_buttons') = TRUE)
         OR (rl.Link_Subrole IS DISTINCT FROM 'button_action'
             AND EXISTS (SELECT 1 FROM raw_links df
                         JOIN fields0 f ON df.b = f.uuid AND COALESCE(df.b_file, '') = f.file
                         WHERE df.Link_Role = 'displays_field'
                           AND df.a = rl.a AND df.a_file IS NOT DISTINCT FROM rl.a_file)))
),
seeds1 AS (SELECT DISTINCT b AS uuid, b_file AS file FROM trig_edges1),
casc1_walk AS (
  SELECT uuid, file, 0 AS d FROM seeds1
  UNION
  SELECT e.b, e.b_file, w.d + 1
  FROM casc1_walk w
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.a = w.uuid AND e.a_file IS NOT DISTINCT FROM w.file
  WHERE w.d < CAST(getvariable('down_depth') AS INT)
    AND (w.uuid, COALESCE(w.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
casc1 AS (SELECT uuid, file, MIN(d) AS d FROM casc1_walk GROUP BY uuid, file),
touch_edges1 AS (
  SELECT rl.a, rl.a_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
         MIN(ts.d) AS src_d
  FROM raw_links rl
  JOIN casc1 ts ON rl.a = ts.uuid AND rl.a_file IS NOT DISTINCT FROM ts.file
  WHERE rl.a_type = 'Script'
    AND (rl.a, COALESCE(rl.a_file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND (
      rl.Link_Role IN (
        'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
        'navigates_to_field', 'inputs_to_field', 'imports_to_field',
        'exports_from_field', 'references_field',
        'navigates_to_layout', 'navigates_to_to',
        'sorts_by_valuelist', 'installs_menuset',
        'calls_customfunction', 'calls_pluginfunction')
      OR (rl.Link_Role = 'calls_function' AND getvariable('include_builtins') = TRUE)
      OR (rl.Link_Role IN ('sets_variable', 'reads_variable')
          AND (getvariable('include_local_vars') = TRUE
               OR EXISTS (SELECT 1 FROM ObjectCatalog vt
                          WHERE vt.Object_UUID = rl.b
                            AND vt.File_Name IS NOT DISTINCT FROM rl.b_file
                            AND vt.Object_Name LIKE '$$%')))
    )
  GROUP BY ALL
),
fields1 AS (
  SELECT uuid, file FROM fields0
  UNION
  SELECT DISTINCT b, COALESCE(b_file, '') FROM touch_edges1
  WHERE Link_Role IN ('sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
                      'navigates_to_field', 'inputs_to_field', 'imports_to_field',
                      'exports_from_field', 'references_field')
    -- Feld-Exclude — s. fields0.
    AND (b, COALESCE(b_file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
layouts1 AS (
  SELECT DISTINCT b AS uuid, b_file AS file FROM touch_edges1 WHERE Link_Role = 'navigates_to_layout'
),
-- Kaskadenstufe 2 (nur bei trigger_depth >= 2) — Layouts, die erst die Kaskade betritt.
trig_edges2 AS (
  SELECT rl.a AS src_uuid, rl.a_file AS src_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl
  JOIN layouts1 l ON rl.a = l.uuid AND rl.a_file IS NOT DISTINCT FROM l.file
  WHERE CAST(getvariable('trigger_depth') AS INT) >= 2
    AND (l.uuid, COALESCE(l.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND rl.Link_Role = 'triggers_script' AND rl.a_type = 'Layout'
    AND (getvariable('include_buttons') = TRUE OR rl.Link_Subrole IS DISTINCT FROM 'button_action')
    -- Event-Klassen-Weiche: Interaktions-Events zünden keine Kaskade.
    AND (getvariable('include_interaction_triggers') = TRUE
         OR COALESCE(rl.Link_Subrole, '') NOT IN (SELECT event FROM interaction_events))
  UNION
  SELECT
    COALESCE(CASE WHEN rl.Link_Subrole IS DISTINCT FROM 'button_action' THEN fa.f_uuid END, lp.layout_uuid),
    COALESCE(CASE WHEN rl.Link_Subrole IS DISTINCT FROM 'button_action' THEN fa.f_file END, lp.layout_file),
    rl.b, rl.b_file, rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl
  JOIN lo_parent lp ON lp.lo = rl.a AND lp.lo_file = COALESCE(rl.a_file, '')
  JOIN layouts1 l ON lp.layout_uuid = l.uuid AND lp.layout_file IS NOT DISTINCT FROM l.file
  LEFT JOIN lo_field_anchor fa ON fa.lo = rl.a AND fa.lo_file = COALESCE(rl.a_file, '')
  WHERE CAST(getvariable('trigger_depth') AS INT) >= 2
    AND (l.uuid, COALESCE(l.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND rl.Link_Role = 'triggers_script' AND rl.a_type = 'LayoutObject'
    -- Event-Klassen-Weiche: Interaktions-Events zünden keine Kaskade.
    AND (getvariable('include_interaction_triggers') = TRUE
         OR COALESCE(rl.Link_Subrole, '') NOT IN (SELECT event FROM interaction_events))
    AND ((rl.Link_Subrole = 'button_action' AND getvariable('include_buttons') = TRUE)
         OR (rl.Link_Subrole IS DISTINCT FROM 'button_action'
             AND EXISTS (SELECT 1 FROM raw_links df
                         JOIN fields1 f ON df.b = f.uuid AND COALESCE(df.b_file, '') = f.file
                         WHERE df.Link_Role = 'displays_field'
                           AND df.a = rl.a AND df.a_file IS NOT DISTINCT FROM rl.a_file)))
),
seeds2 AS (SELECT DISTINCT b AS uuid, b_file AS file FROM trig_edges2),
casc2_walk AS (
  SELECT uuid, file, 0 AS d FROM seeds2
  UNION
  SELECT e.b, e.b_file, w.d + 1
  FROM casc2_walk w
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.a = w.uuid AND e.a_file IS NOT DISTINCT FROM w.file
  WHERE w.d < CAST(getvariable('down_depth') AS INT)
    AND (w.uuid, COALESCE(w.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
casc2 AS (SELECT uuid, file, MIN(d) AS d FROM casc2_walk GROUP BY uuid, file),
touch_edges2 AS (
  SELECT rl.a, rl.a_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
         MIN(ts.d) AS src_d
  FROM raw_links rl
  JOIN casc2 ts ON rl.a = ts.uuid AND rl.a_file IS NOT DISTINCT FROM ts.file
  WHERE rl.a_type = 'Script'
    AND (rl.a, COALESCE(rl.a_file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND (
      rl.Link_Role IN (
        'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
        'navigates_to_field', 'inputs_to_field', 'imports_to_field',
        'exports_from_field', 'references_field',
        'navigates_to_layout', 'navigates_to_to',
        'sorts_by_valuelist', 'installs_menuset',
        'calls_customfunction', 'calls_pluginfunction')
      OR (rl.Link_Role = 'calls_function' AND getvariable('include_builtins') = TRUE)
      OR (rl.Link_Role IN ('sets_variable', 'reads_variable')
          AND (getvariable('include_local_vars') = TRUE
               OR EXISTS (SELECT 1 FROM ObjectCatalog vt
                          WHERE vt.Object_UUID = rl.b
                            AND vt.File_Name IS NOT DISTINCT FROM rl.b_file
                            AND vt.Object_Name LIKE '$$%')))
    )
  GROUP BY ALL
),
fields2 AS (
  SELECT uuid, file FROM fields1
  UNION
  SELECT DISTINCT b, COALESCE(b_file, '') FROM touch_edges2
  WHERE Link_Role IN ('sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
                      'navigates_to_field', 'inputs_to_field', 'imports_to_field',
                      'exports_from_field', 'references_field')
    -- Feld-Exclude — s. fields0.
    AND (b, COALESCE(b_file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
layouts2 AS (
  SELECT DISTINCT b AS uuid, b_file AS file FROM touch_edges2 WHERE Link_Role = 'navigates_to_layout'
),
-- Kaskadenstufe 3 (nur bei trigger_depth >= 3, Cap) — deren Layouts zünden nicht mehr.
trig_edges3 AS (
  SELECT rl.a AS src_uuid, rl.a_file AS src_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl
  JOIN layouts2 l ON rl.a = l.uuid AND rl.a_file IS NOT DISTINCT FROM l.file
  WHERE CAST(getvariable('trigger_depth') AS INT) >= 3
    AND (l.uuid, COALESCE(l.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND rl.Link_Role = 'triggers_script' AND rl.a_type = 'Layout'
    AND (getvariable('include_buttons') = TRUE OR rl.Link_Subrole IS DISTINCT FROM 'button_action')
    -- Event-Klassen-Weiche: Interaktions-Events zünden keine Kaskade.
    AND (getvariable('include_interaction_triggers') = TRUE
         OR COALESCE(rl.Link_Subrole, '') NOT IN (SELECT event FROM interaction_events))
  UNION
  SELECT
    COALESCE(CASE WHEN rl.Link_Subrole IS DISTINCT FROM 'button_action' THEN fa.f_uuid END, lp.layout_uuid),
    COALESCE(CASE WHEN rl.Link_Subrole IS DISTINCT FROM 'button_action' THEN fa.f_file END, lp.layout_file),
    rl.b, rl.b_file, rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl
  JOIN lo_parent lp ON lp.lo = rl.a AND lp.lo_file = COALESCE(rl.a_file, '')
  JOIN layouts2 l ON lp.layout_uuid = l.uuid AND lp.layout_file IS NOT DISTINCT FROM l.file
  LEFT JOIN lo_field_anchor fa ON fa.lo = rl.a AND fa.lo_file = COALESCE(rl.a_file, '')
  WHERE CAST(getvariable('trigger_depth') AS INT) >= 3
    AND (l.uuid, COALESCE(l.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND rl.Link_Role = 'triggers_script' AND rl.a_type = 'LayoutObject'
    -- Event-Klassen-Weiche: Interaktions-Events zünden keine Kaskade.
    AND (getvariable('include_interaction_triggers') = TRUE
         OR COALESCE(rl.Link_Subrole, '') NOT IN (SELECT event FROM interaction_events))
    AND ((rl.Link_Subrole = 'button_action' AND getvariable('include_buttons') = TRUE)
         OR (rl.Link_Subrole IS DISTINCT FROM 'button_action'
             AND EXISTS (SELECT 1 FROM raw_links df
                         JOIN fields2 f ON df.b = f.uuid AND COALESCE(df.b_file, '') = f.file
                         WHERE df.Link_Role = 'displays_field'
                           AND df.a = rl.a AND df.a_file IS NOT DISTINCT FROM rl.a_file)))
),
seeds3 AS (SELECT DISTINCT b AS uuid, b_file AS file FROM trig_edges3),
casc3_walk AS (
  SELECT uuid, file, 0 AS d FROM seeds3
  UNION
  SELECT e.b, e.b_file, w.d + 1
  FROM casc3_walk w
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.a = w.uuid AND e.a_file IS NOT DISTINCT FROM w.file
  WHERE w.d < CAST(getvariable('down_depth') AS INT)
    AND (w.uuid, COALESCE(w.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
casc3 AS (SELECT uuid, file, MIN(d) AS d FROM casc3_walk GROUP BY uuid, file),
touch_edges3 AS (
  SELECT rl.a, rl.a_file, rl.b, rl.b_file,
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
         MIN(ts.d) AS src_d
  FROM raw_links rl
  JOIN casc3 ts ON rl.a = ts.uuid AND rl.a_file IS NOT DISTINCT FROM ts.file
  WHERE rl.a_type = 'Script'
    AND (rl.a, COALESCE(rl.a_file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND (
      rl.Link_Role IN (
        'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
        'navigates_to_field', 'inputs_to_field', 'imports_to_field',
        'exports_from_field', 'references_field',
        'navigates_to_layout', 'navigates_to_to',
        'sorts_by_valuelist', 'installs_menuset',
        'calls_customfunction', 'calls_pluginfunction')
      OR (rl.Link_Role = 'calls_function' AND getvariable('include_builtins') = TRUE)
      OR (rl.Link_Role IN ('sets_variable', 'reads_variable')
          AND (getvariable('include_local_vars') = TRUE
               OR EXISTS (SELECT 1 FROM ObjectCatalog vt
                          WHERE vt.Object_UUID = rl.b
                            AND vt.File_Name IS NOT DISTINCT FROM rl.b_file
                            AND vt.Object_Name LIKE '$$%')))
    )
  GROUP BY ALL
),
-- ============================================================================
-- STUFE 4 — Knoten-/Kantenbildung, Rollen-Priorität, Deckel
-- ============================================================================
nodes_all AS (
  SELECT uuid, file, 'start' AS trace_role, 0 AS tdepth, 0 AS prio FROM start_obj
  UNION ALL SELECT uuid, file, 'chain_down', d, 1 FROM chain_down
  UNION ALL SELECT uuid, file, 'chain_up', -d, 1 FROM chain_up
  UNION ALL SELECT uuid, file, 'triggered', d, 2 FROM casc1
  UNION ALL SELECT uuid, file, 'triggered', d, 2 FROM casc2
  UNION ALL SELECT uuid, file, 'triggered', d, 2 FROM casc3
  UNION ALL SELECT b, b_file, 'touched', src_d + 1, 3 FROM touch_edges0
  UNION ALL SELECT b, b_file, 'trigger_touched', src_d + 1, 4 FROM touch_edges1
  UNION ALL SELECT b, b_file, 'trigger_touched', src_d + 1, 4 FROM touch_edges2
  UNION ALL SELECT b, b_file, 'trigger_touched', src_d + 1, 4 FROM touch_edges3
  UNION ALL SELECT src_uuid, src_file, 'trigger_owner', script_d, 5 FROM owner_edges
),
node_best AS (
  SELECT uuid, file, trace_role, tdepth, prio,
         ROW_NUMBER() OVER (
           PARTITION BY uuid, COALESCE(file, '')
           ORDER BY prio ASC, abs(tdepth) ASC, trace_role ASC
         ) AS pick
  FROM nodes_all
),
node_set AS (
  SELECT uuid, file, trace_role, tdepth, prio FROM node_best WHERE pick = 1
),
-- Globaler operationaler Grad (Hub-Signal, UUID-aggregiert wie im Subgraph).
deg AS (
  SELECT id, COUNT(*) AS degree
  FROM (
    SELECT Source_UUID AS id FROM ObjectLinks
    WHERE Link_Type = 'operational' AND Source_UUID IN (SELECT uuid FROM node_set)
    UNION ALL
    SELECT Target_UUID AS id FROM ObjectLinks
    WHERE Link_Type = 'operational' AND Target_UUID IN (SELECT uuid FROM node_set)
  )
  GROUP BY id
),
nodes_ranked AS (
  SELECT n.uuid, n.file, n.trace_role, n.tdepth, n.prio,
         oc.Object_Type AS type, oc.Object_Name AS label,
         COALESCE(dg.degree, 0) AS degree
  FROM node_set n
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = n.uuid AND oc.File_Name IS NOT DISTINCT FROM n.file
  LEFT JOIN deg dg ON dg.id = n.uuid
),
-- Deckel-Rang — Chain überlebt zuerst (start > chain > triggered > touched >
-- trigger_touched > Kontext), dann |Tiefe|, dann Grad. Kein stilles Kappen.
nodes_capped AS (
  SELECT *, ROW_NUMBER() OVER (ORDER BY prio ASC, abs(tdepth) ASC, degree DESC, label ASC) AS rn
  FROM nodes_ranked
),
kept AS (
  SELECT * FROM nodes_capped WHERE rn <= CAST(getvariable('node_limit') AS INT)
),
-- ── Hub-Score-Vorschläge: Exclude-Kandidaten unter den getraceten
-- Scripts. Metriken GLOBAL über die materialisierte raw_links (GROUP BY, billig,
-- keine korrelierten Subqueries). Die Floors 25/50/100 liegen Faktor >= 3 über
-- den Korpus-p95 (9/5/-) — kleine Fixtures liefern bewusst eine leere Liste.
-- Cap 10; NIE automatisch angewandt — der Service reicht die Kandidaten als
-- data.trace.suggestions aus, das Frontend macht daraus erst per Klick einen
-- Exclude.
sugg_trig AS (
  SELECT b AS u, COALESCE(b_file, '') AS f, COUNT(*) AS n
  FROM raw_links WHERE Link_Role = 'triggers_script' GROUP BY 1, 2
),
sugg_call AS (
  SELECT b AS u, COALESCE(b_file, '') AS f, COUNT(*) AS n
  FROM raw_links WHERE Link_Role = 'calls_script' GROUP BY 1, 2
),
sugg_touch AS (
  SELECT a AS u, COALESCE(a_file, '') AS f, COUNT(*) AS n
  FROM raw_links
  WHERE a_type = 'Script' AND Link_Role IN (
    'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
    'navigates_to_field', 'inputs_to_field', 'imports_to_field',
    'exports_from_field', 'references_field')
  GROUP BY 1, 2
),
suggestions AS (
  SELECT * FROM (
    SELECT k.uuid, COALESCE(k.file, '') AS f,
           COALESCE(t.n, 0) AS s_trig, COALESCE(c.n, 0) AS s_call, COALESCE(o.n, 0) AS s_touch,
           GREATEST(COALESCE(t.n, 0) * 4, COALESCE(c.n, 0) * 2, COALESCE(o.n, 0)) AS s_score,
           CASE
             WHEN COALESCE(t.n, 0) * 4 >= GREATEST(COALESCE(c.n, 0) * 2, COALESCE(o.n, 0)) THEN 'trigger_hub'
             WHEN COALESCE(o.n, 0) >= COALESCE(c.n, 0) * 2 THEN 'touch_hub'
             ELSE 'call_hub'
           END AS s_reason,
           k.label AS s_label
    FROM kept k
    LEFT JOIN sugg_trig t  ON t.u = k.uuid AND t.f = COALESCE(k.file, '')
    LEFT JOIN sugg_call c  ON c.u = k.uuid AND c.f = COALESCE(k.file, '')
    LEFT JOIN sugg_touch o ON o.u = k.uuid AND o.f = COALESCE(k.file, '')
    WHERE k.type = 'Script'
      AND k.trace_role <> 'start'
      AND (k.uuid, COALESCE(k.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
      -- Guard: Chain-Nutzlast schützen — nie Chain-Knoten der Fokus-Datei,
      -- nie Chain-Knoten mit |Tiefe| <= 1; Kaskaden-Knoten bleiben vorschlagbar.
      AND NOT (k.trace_role IN ('chain_down', 'chain_up')
               AND (abs(k.tdepth) <= 1
                    OR k.file IS NOT DISTINCT FROM (SELECT file FROM start_obj)))
      AND (COALESCE(t.n, 0) >= 25 OR COALESCE(c.n, 0) >= 50 OR COALESCE(o.n, 0) >= 100)
    ORDER BY s_score DESC, s_label ASC
    LIMIT 10
  )
),
-- Kanten-Kandidaten mit trace_kind + Kind-Priorität (chain > trigger > touch > induced).
edge_candidates AS (
  -- Chain — alle calls_script zwischen getraceten Knoten (Traversal + Querverbindungen).
  SELECT a AS src_uuid, a_file AS src_file, b AS dst_uuid, b_file AS dst_file,
         Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'chain' AS trace_kind, 1 AS kprio
  FROM raw_links WHERE Link_Role = 'calls_script'
  UNION ALL
  -- Trigger — Seed-Kanten (layout_runtime), Owner-Kontext, Kaskadenstufen 1–3.
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'trigger', 2
  FROM seed_trigger_edges
  UNION ALL
  SELECT src_uuid, src_file, dst_uuid, dst_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'trigger', 2
  FROM owner_edges
  UNION ALL
  SELECT src_uuid, src_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'trigger', 2
  FROM trig_edges1
  UNION ALL
  SELECT src_uuid, src_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'trigger', 2
  FROM trig_edges2
  UNION ALL
  SELECT src_uuid, src_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'trigger', 2
  FROM trig_edges3
  UNION ALL
  -- Touch — Seed-Navigation (layout_inbound) + Touch-Kanten aller Stufen.
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'touch', 3
  FROM seed_nav_edges
  UNION ALL
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'touch', 3
  FROM touch_edges0
  UNION ALL
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'touch', 3
  FROM touch_edges1
  UNION ALL
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'touch', 3
  FROM touch_edges2
  UNION ALL
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'touch', 3
  FROM touch_edges3
  UNION ALL
  -- Induzierte Kontext-Kanten zwischen bereits eingesammelten Knoten —
  -- erweitern das Knoten-Set NIE (final_edges-Muster des Subgraphen).
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File, 'induced', 4
  FROM raw_links
  WHERE Link_Role IN ('displays_field', 'displays_variable', 'context_table', 'uses_valuelist')
),
-- Beide Endpunkte überleben den Deckel; Duplikate über Kind-Priorität einschmelzen.
final_edges AS (
  SELECT src_uuid, src_file, dst_uuid, dst_file,
         Link_Role AS role, Link_Subrole AS subrole, Link_Type AS link_type,
         Is_Cross_File AS cross_file, trace_kind
  FROM (
    SELECT ec.*,
           ROW_NUMBER() OVER (
             PARTITION BY ec.src_uuid, COALESCE(ec.src_file, ''),
                          ec.dst_uuid, COALESCE(ec.dst_file, ''),
                          ec.Link_Role, COALESCE(ec.Link_Subrole, '')
             ORDER BY ec.kprio ASC
           ) AS pick
    FROM edge_candidates ec
    WHERE EXISTS (SELECT 1 FROM kept k WHERE k.uuid = ec.src_uuid AND k.file IS NOT DISTINCT FROM ec.src_file)
      AND EXISTS (SELECT 1 FROM kept k WHERE k.uuid = ec.dst_uuid AND k.file IS NOT DISTINCT FROM ec.dst_file)
  )
  WHERE pick = 1
),
-- Blind-Spot-Ausweis — dynamische Call-Steps (by name) aller getraceten Scripts.
scripts_traced AS (
  SELECT uuid, COALESCE(file, '') AS f FROM chain_all
  UNION SELECT uuid, COALESCE(file, '') FROM casc1
  UNION SELECT uuid, COALESCE(file, '') FROM casc2
  UNION SELECT uuid, COALESCE(file, '') FROM casc3
),
dyn AS (
  SELECT COUNT(DISTINCT sc.Step_UUID) AS n
  FROM StepCalculations sc
  JOIN scripts_traced st
    ON sc.Script_UUID = st.uuid AND COALESCE(sc.File_Name, '') = st.f
  WHERE sc.Step_ID IN (1, 164, 210) AND sc.Slot = 'List'
    -- Exclude: bewusst nicht expandierte Scripts zählen nicht als Blind-Spot.
    AND (st.uuid, st.f) NOT IN (SELECT uuid, file_key FROM excluded)
)
-- ── getaggte Ausgabe ───────────────────────────────────────────────────────
SELECT
  'node'                                                AS row_kind,
  k.uuid || COALESCE('::' || k.file, '')                AS id,
  k.uuid                                                AS uuid,
  k.label                                               AS label,
  k.type                                                AS type,
  k.file                                                AS file,
  abs(k.tdepth)                                         AS depth,
  k.degree                                              AS degree,
  (k.degree >= CAST(getvariable('hub_degree') AS INT))  AS is_hub,
  (k.uuid = getvariable('start')
     AND k.file IS NOT DISTINCT FROM (SELECT file FROM start_obj)) AS is_focus,
  (SELECT COUNT(*) FROM nodes_ranked)                   AS total_reachable,
  NULL                                                  AS community,
  NULL                                                  AS source,
  NULL                                                  AS target,
  NULL                                                  AS role,
  NULL                                                  AS subrole,
  NULL                                                  AS link_type,
  NULL                                                  AS cross_file,
  k.trace_role                                          AS trace_role,
  k.tdepth                                              AS trace_depth,
  NULL                                                  AS trace_kind,
  (SELECT n FROM dyn)                                   AS dynamic_calls,
  ((k.uuid, COALESCE(k.file, '')) IN
     (SELECT uuid, file_key FROM excluded))              AS is_excluded,
  sg.s_trig                                             AS sugg_trig_in,
  sg.s_call                                             AS sugg_fan_in,
  sg.s_touch                                            AS sugg_touch_out,
  sg.s_score                                            AS sugg_score,
  sg.s_reason                                           AS sugg_reason
FROM kept k
LEFT JOIN suggestions sg ON sg.uuid = k.uuid AND sg.f = COALESCE(k.file, '')
UNION ALL
SELECT
  'edge',
  (e.src_uuid || COALESCE('::' || e.src_file, '')
     || '|' || COALESCE(e.role, '') || '|'
     || e.dst_uuid || COALESCE('::' || e.dst_file, '')) AS id,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  (e.src_uuid || COALESCE('::' || e.src_file, ''))      AS source,
  (e.dst_uuid || COALESCE('::' || e.dst_file, ''))      AS target,
  e.role, e.subrole, e.link_type, e.cross_file,
  NULL,
  NULL,
  e.trace_kind,
  NULL,
  NULL,
  NULL, NULL, NULL, NULL, NULL
FROM final_edges e
UNION ALL
SELECT
  'seed',
  s.uuid || COALESCE('::' || s.file, '')                AS id,
  s.uuid,
  oc.Object_Name,
  oc.Object_Type,
  s.file,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL
FROM seeds s
JOIN ObjectCatalog oc
  ON oc.Object_UUID = s.uuid AND oc.File_Name IS NOT DISTINCT FROM s.file
ORDER BY row_kind, degree DESC NULLS LAST;
