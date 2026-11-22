-- @template_type: report
-- @title: Graph Trace (Selective Flow Walk)
-- @description: Selektiver Ablauf-Graph ab einem Startobjekt — Callchain auf-/abwärts, berührte Objekte der Chain-Scripts, Kontext-Trigger betretener Layouts (budgetierte Kaskade)
-- @params: start (required, UUID), start_file, entry, up_depth, down_depth, trigger_depth, expand_up, include_local_vars, include_buttons, include_builtins, include_interaction_triggers, include_disabled, node_limit, hub_degree, exclude, expand_way
-- @version: 2.2.1
-- @author: Marcel / Claude
-- @tags: graph, trace, explorer
-- @note: 2.2.1 (Determinismus, Überlauf): Tiebreak der Ausgabe um subrole
--        und trace_kind ergänzt. Kanten mit gleicher id und anderer subrole
--        (Wiederholungsindex, on_server) standen gleichauf; zwei Abrufe
--        lieferten eine andere Zeilenfolge und damit eine andere Antwort.
--        Der Rang der repräsentativen Aufrufstelle (edge_sites.rep) läuft als
--        BIGINT — eine Aufrufstelle, die unerreichbar UND bedingt ist, brach
--        den Trace mit „Overflow in addition of INT32“ ab.
--        2.2.0 („Quelle verfolgen“ aufwärts):
--        Neuer Parameter expand_way — Weg-IDs (12 Hex, md5 'flow|up|' + Ziel-ID
--        wie im Service) von Aufwärts-Wegen, deren Einstieg eine Ebene weiter
--        verfolgt wird. Button-/Trigger-Einstieg: die Scripts, die ein Owner-
--        Layout per Go to Layout betreten (Schritt-Anker), und deren Aufrufer
--        bis up_depth. Budget-Einstieg: die Aufrufer jenseits des Budgets, wieder
--        bis up_depth. Neue Knoten sind nur solche außerhalb des Aufwärts-Walks.
--        Zeilenarten xpred (Vorgänger je Weg-ID, Art call bzw. enter mit Layout
--        und Ereignis) und xupinfo (Tiefe relativ zum Einstieg, Aufrufer-Zahl);
--        Einstiegsgruppen der neuen Knoten als entry-Zeilen. Ohne expand_way ist
--        die Ausgabe bitgleich zu 2.1.0.
--        2.1.0 (Wege-Material):
--        Aufrufstellen tragen `unreachable` — der Schritt steht hinter einem
--        aktiven Exit Script / Halt Script desselben Blocks (Logik der Regel
--        dead_code_after_exit, auf den ganzen Block bis zum nächsten Else /
--        Else If / End If / End Loop derselben Tiefe erweitert). Die Kante bleibt.
--        pred-Zeilen tragen je Schritt-Kante `hop` — die repräsentative
--        Aufrufstelle (erreichbar vor bedingt vor Schrittnummer) mit Kontext und
--        das Aggregat über alle Aufrufstellen (n, allConditional, anyLoop,
--        anyServer, anyParam, allUnreachable) — sowie crossFile.
--        Der Start hat nie einen Vorgänger (Layout-Start, auf den ein
--        Kettenscript zurücknavigiert, ergab eine zyklische Kette).
--        Neue Zeilenarten entry (Einstiegsgruppen je Script des Aufwärts-Walks:
--        button / trigger / menu / file, mit Ereignis, Zählern, Layouts,
--        Stichprobe; ungedeckelt) und upinfo (Aufrufer-Zahl je Knoten des
--        Aufwärts-Walks — root / budget / excluded für die Wege).
--        2.0.0 (schrittgenauer Ablauf-Trace):
--        Deaktivierte Schritte sind ausgeschlossen — Script-Kanten, deren
--        Schritte in v_script_step_links ALLE deaktiviert sind, fallen aus
--        raw_links (Anti-Join dead_keys; Aufrufe, Touches und Navigation, damit
--        auch Kaskaden-Auslöser). include_disabled = TRUE liefert die Knoten-
--        und Kantenmenge von 1.3.0. Script-Kanten ohne Schrittzeile (MBS
--        FM.RunScript) bleiben als Rückfall (precision approx).
--        Neue Spalte payload (JSON) je Zeilenart —
--          node  Wirkung je Script (Zahl verschiedener Ziele je Touch-Rolle)
--          edge  Aufrufstellen (calls_script, navigates_to_layout) mit Bedingung
--                aus v_step_guards, Schleife, Parameter, Ergebnis-Lesern und
--                precision (exact = Schritt-Anker, approx = ohne)
--          pred  Vorgänger je Knoten auf dem kürzesten Pfad (dir down/up, mit
--                Aufrufschritt bzw. Ereignis) — Grundlage der Wege
--          blind Aufrufschritte ohne statisches Ziel (by name / unaufgelöst)
--          stats deaktivierte Schritte der getraceten Scripts u. a.
--        Verlangt Schema 1.43.0 (v_script_step_links, v_step_guards,
--        v_dataflow_edges) — der Service prüft das vorher.
--        1.3.0 (Event-Klassen-Weiche + Feld-Exclude):
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
--   include_disabled   TRUE verfolgt auch deaktivierte Schritte     (Default FALSE)
--   node_limit        harter Knoten-Deckel                         (Default 1000)
--   hub_degree         Grad-Schwelle für isHub-Markierung           (Default 100)
--   expand_way         Weg-IDs (Komma-Liste, 12 Hex) für „Quelle   (Default NULL)
--                      verfolgen“ aufwärts — siehe @note 2.2.0
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
--   SET VARIABLE include_interaction_triggers = FALSE; SET VARIABLE include_disabled = FALSE;
--   SET VARIABLE node_limit = 1000; SET VARIABLE hub_degree = 100; SET VARIABLE exclude = NULL;
--   SET VARIABLE expand_way = NULL;
--
-- ============================================================================
-- AUSGABE — getaggte Union (row_kind), die der Service partitioniert.
--   row_kind='node' → nodes[]  (wie Subgraph + trace_role, trace_depth)
--   row_kind='edge' → edges[]  (wie Subgraph + trace_kind)
--   row_kind='seed' → seeds[]  (Seed-Scripts der Stufe 0 — Payload data.trace.seeds)
--   row_kind='pred' → Vorgänger je Knoten (role = dir down|up, source = Vorgänger;
--                     auch für Knoten außerhalb von node_limit, mit Beschriftung)
--   row_kind='blind'→ Aufrufschritte ohne statisches Ziel (type DynamicCall,
--                     source = aufrufendes Script)
--   row_kind='stats'→ eine Zeile mit Kennzahlen im payload
--   row_kind='entry'→ Einstiegsgruppe je Script des Aufwärts-Walks (source =
--                     Script, role = Gruppenart, subrole = Ereignis)
--   row_kind='upinfo'→ je Knoten des Aufwärts-Walks Tiefe, Aufrufer-Zahl,
--                     Ausschluss (Grundlage der Einstiege root / budget)
--   row_kind='xpred' → „Quelle verfolgen“: Vorgänger je Knoten und Weg-ID
--                     (role = Weg-ID des aufgeklappten Wegs, source = Vorgänger)
--   row_kind='xupinfo'→ „Quelle verfolgen“: neue Knoten mit Weg-ID, Tiefe ab
--                     dem Einstieg, Aufrufer-Zahl, Ausschluss
-- `payload`         = JSON je Zeilenart (siehe @note 2.0.0);
-- `total_reachable` = Knotenmenge VOR dem Deckel (truncated-Erkennung);
-- `dynamic_calls`   = aktive Call-Steps der getraceten Scripts mit Namensformel
--                     (Perform Script / on Server / with Callback „by name",
--                      Slot 'List' in StepCalculations) — ehrlicher Blind-Spot.
-- ============================================================================

WITH RECURSIVE
-- 0) Tote Schlüssel — Script-Kanten (Script × Datei × Rolle × Ziel × Zieldatei),
--    deren Schritte ALLE deaktiviert sind. Nur Trace-Rollen; als Anti-Join auf
--    ObjectLinks billiger als eine Gruppierung aller Schrittzeilen (Messung
--    +0,07 s auf dem Großkorpus). Script-Kanten ohne Schrittzeile (MBS
--    FM.RunScript) haben keinen Schlüssel und bleiben (Rückfall, approx).
dead_keys AS MATERIALIZED (
  SELECT Script_UUID, File_Name, Link_Role, Target_UUID, Target_File
  FROM v_script_step_links
  WHERE getvariable('include_disabled') IS DISTINCT FROM TRUE
    AND Link_Role IN (
      'calls_script', 'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
      'navigates_to_field', 'inputs_to_field', 'imports_to_field', 'exports_from_field',
      'references_field', 'navigates_to_layout', 'navigates_to_to',
      'sorts_by_valuelist', 'installs_menuset',
      'calls_customfunction', 'calls_pluginfunction', 'calls_function',
      'sets_variable', 'reads_variable')
  GROUP BY ALL
  HAVING NOT bool_or(Is_Enabled)
),
-- 1) Roh-Kanten mit Waisen-Filter — beide Endpunkte katalogisiert; Typ + Datei
--    mitführen. Vorab auf die Trace-relevanten Rollen gefiltert und MATERIALIZED —
--    die CTE wird ~20× referenziert; ohne Rollen-Schnitt + Materialisierung
--    wiederholt sich der Orphan-Semi-Join über die volle ObjectLinks je Referenz
--    (gemessen auf dem Großkorpus der Unterschied zwischen ~1,4 s und < 1 s).
raw_links AS MATERIALIZED (
  SELECT
    ol.Source_UUID AS a, ol.Source_Type AS a_type, ol.Source_File AS a_file,
    ol.Target_UUID AS b, ol.Target_Type AS b_type, ol.Target_File AS b_file,
    ol.Link_Role, ol.Link_Subrole, ol.Link_Type, ol.Is_Cross_File
  FROM ObjectLinks ol
  LEFT JOIN dead_keys k
    ON ol.Source_Type = 'Script'
   AND k.Script_UUID = ol.Source_UUID AND k.File_Name IS NOT DISTINCT FROM ol.Source_File
   AND k.Link_Role = ol.Link_Role
   AND k.Target_UUID = ol.Target_UUID AND k.Target_File IS NOT DISTINCT FROM ol.Target_File
  WHERE k.Script_UUID IS NULL
    AND ol.Link_Role IN (
      'calls_script', 'triggers_script', 'parent_layout', 'displays_field',
      'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
      'navigates_to_field', 'inputs_to_field', 'imports_to_field',
      'exports_from_field', 'references_field',
      'navigates_to_layout', 'navigates_to_to',
      'sorts_by_valuelist', 'installs_menuset',
      'calls_customfunction', 'calls_pluginfunction', 'calls_function',
      'sets_variable', 'reads_variable',
      'displays_variable', 'context_table', 'uses_valuelist')
    AND ol.Source_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
    AND ol.Target_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
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
    c.d AS script_d,
    -- Originalobjekt und sein Layout (Einstiegsgruppen der Wege, 2.1.0)
    ts.a AS o_uuid, ts.a_type AS o_type, ts.a_file AS o_file,
    CASE WHEN ts.a_type = 'LayoutObject' THEN lp.layout_uuid
         WHEN ts.a_type = 'Layout' THEN ts.a END AS o_lay_uuid,
    CASE WHEN ts.a_type = 'LayoutObject' THEN lp.layout_file
         WHEN ts.a_type = 'Layout' THEN ts.a_file END AS o_lay_file
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
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
         rl.a AS lay_uuid, rl.a_file AS lay_file
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
    rl.b, rl.b_file, rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
    lp.layout_uuid, lp.layout_file
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
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
         rl.a AS lay_uuid, rl.a_file AS lay_file
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
    rl.b, rl.b_file, rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
    lp.layout_uuid, lp.layout_file
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
         rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
         rl.a AS lay_uuid, rl.a_file AS lay_file
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
    rl.b, rl.b_file, rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File,
    lp.layout_uuid, lp.layout_file
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
-- ============================================================================
-- SCHRITT-ANKER (2.0.0) — Aufrufstellen, Aufrufkontext, Vorgänger, Wirkung,
-- blinde Stellen. Läuft nach dem Walk und nur über die getraceten Scripts.
-- ============================================================================
-- ── „Quelle verfolgen“ aufwärts (2.2.0) ───────────────────────────────────
-- Angeforderte Wege = Knoten des Aufwärts-Walks, deren Weg-ID (md5 wie im
-- Service: 'flow|up|' + Knoten-ID, 12 Hex) in expand_way steht.
x_req AS (
  SELECT DISTINCT trim(item) AS way_id
  FROM (SELECT unnest(string_split(COALESCE(CAST(getvariable('expand_way') AS VARCHAR), ''), ',')) AS item)
  WHERE trim(item) <> ''
),
x_up_nodes AS MATERIALIZED (
  SELECT uuid, file, MIN(d) AS d
  FROM chain_up_walk
  GROUP BY uuid, file
),
x_seed AS (
  SELECT n.uuid, n.file, n.d, r.way_id
  FROM x_up_nodes n
  JOIN x_req r ON r.way_id = left(md5('flow|up|' || n.uuid || COALESCE('::' || n.file, '')), 12)
  WHERE (n.uuid, COALESCE(n.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
),
-- Button-/Trigger-Einstieg: Owner-Layouts (Layout-Trigger bzw. Layout des
-- Objekts); die eigenen Trigger eines Start-Layouts sind Seeds, keine Einstiege.
x_owner_lay AS (
  SELECT s.way_id, s.uuid AS s_uuid, s.file AS s_file,
         CASE WHEN t.a_type = 'LayoutObject' THEN lp.layout_uuid ELSE t.a END AS lay_uuid,
         CASE WHEN t.a_type = 'LayoutObject' THEN lp.layout_file ELSE t.a_file END AS lay_file,
         t.Link_Subrole AS event
  FROM x_seed s
  JOIN raw_links t
    ON t.Link_Role = 'triggers_script'
   AND t.b = s.uuid AND t.b_file IS NOT DISTINCT FROM s.file
  LEFT JOIN lo_parent lp ON t.a_type = 'LayoutObject' AND lp.lo = t.a AND lp.lo_file = COALESCE(t.a_file, '')
  WHERE t.a_type IN ('LayoutObject', 'Layout')
),
-- Start des Erweiterungs-Walks: Navigierer der Owner-Layouts (enter) bzw. die
-- Aufrufer eines am Budget gekappten Einstiegs (call). Nur neue Knoten.
x_start AS (
  SELECT o.way_id, n.a AS uuid, n.a_file AS file, 1 AS xd,
         o.s_uuid AS p_uuid, o.s_file AS p_file, 'enter' AS kind,
         o.lay_uuid, o.lay_file, o.event
  FROM x_owner_lay o
  JOIN raw_links n
    ON n.Link_Role = 'navigates_to_layout' AND n.a_type = 'Script'
   AND n.b = o.lay_uuid AND n.b_file IS NOT DISTINCT FROM o.lay_file
  WHERE o.lay_uuid IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM start_obj so
                    WHERE so.otype = 'Layout' AND so.uuid = o.lay_uuid
                      AND so.file IS NOT DISTINCT FROM o.lay_file)
    AND (n.a, COALESCE(n.a_file, '')) NOT IN (SELECT uuid, COALESCE(file, '') FROM x_up_nodes)
  UNION
  SELECT s.way_id, e.a, e.a_file, 1, s.uuid, s.file, 'call',
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR)
  FROM x_seed s
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.b = s.uuid AND e.b_file IS NOT DISTINCT FROM s.file
  WHERE s.d >= CAST(getvariable('up_depth') AS INT)
    AND (e.a, COALESCE(e.a_file, '')) NOT IN (SELECT uuid, COALESCE(file, '') FROM x_up_nodes)
),
x_walk AS (
  SELECT * FROM x_start
  UNION
  SELECT w.way_id, e.a, e.a_file, w.xd + 1, w.uuid, w.file, 'call',
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR)
  FROM x_walk w
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.b = w.uuid AND e.b_file IS NOT DISTINCT FROM w.file
  WHERE w.xd < CAST(getvariable('up_depth') AS INT)
    AND (w.uuid, COALESCE(w.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
    AND (e.a, COALESCE(e.a_file, '')) NOT IN (SELECT uuid, COALESCE(file, '') FROM x_up_nodes)
),
-- Ein Knoten je Weg-ID mit seinem Vorgänger auf dem kürzesten Pfad.
x_best AS (
  SELECT * FROM x_walk
  QUALIFY row_number() OVER (
    PARTITION BY way_id, uuid, COALESCE(file, '')
    ORDER BY xd, p_uuid, COALESCE(p_file, ''), lay_uuid NULLS LAST, COALESCE(lay_file, ''),
             event NULLS LAST) = 1
),
-- Jeder neue Knoten wird ein Weg — unter dem ersten aufgeklappten Weg, der ihn
-- am nächsten erreicht.
x_assign AS (
  SELECT * FROM x_best
  QUALIFY row_number() OVER (PARTITION BY uuid, COALESCE(file, '') ORDER BY xd, way_id) = 1
),
-- Getracete Scripts; x_only = nur über „Quelle verfolgen“ erreicht (liefert
-- Aufrufstellen für die Wege, zählt aber nicht zu blinden Stellen und Kennzahlen).
scripts_traced AS MATERIALIZED (
  SELECT uuid, f, bool_and(x) AS x_only
  FROM (
    SELECT uuid, COALESCE(file, '') AS f, FALSE AS x FROM chain_all
    UNION ALL SELECT uuid, COALESCE(file, ''), FALSE FROM casc1
    UNION ALL SELECT uuid, COALESCE(file, ''), FALSE FROM casc2
    UNION ALL SELECT uuid, COALESCE(file, ''), FALSE FROM casc3
    UNION ALL SELECT uuid, COALESCE(file, ''), TRUE FROM x_walk
  )
  GROUP BY uuid, f
),
-- Schrittzeilen der getraceten Scripts in den Trace-Rollen — EIN Scan der
-- Schrittsicht für Aufrufstellen, blinde Stellen und die Zählung deaktivierter
-- Schritte. Ausgeschlossene Scripts sind markiert (sie expandieren nicht).
traced_links AS MATERIALIZED (
  SELECT l.Script_UUID, l.File_Name, l.Step_UUID, l.Step_Index, l.Step_ID,
         l.Is_Enabled, l.Link_Role, l.Target_UUID, l.Target_File,
         (st.uuid, st.f) IN (SELECT uuid, file_key FROM excluded) AS src_excluded,
         st.x_only
  FROM v_script_step_links l
  JOIN scripts_traced st ON l.Script_UUID = st.uuid AND COALESCE(l.File_Name, '') = st.f
  WHERE l.Link_Role IN (
      'calls_script', 'sets_field', 'reads_field', 'finds_in_field', 'sorts_by_field',
      'navigates_to_field', 'inputs_to_field', 'imports_to_field', 'exports_from_field',
      'references_field', 'navigates_to_layout', 'navigates_to_to',
      'sorts_by_valuelist', 'installs_menuset',
      'calls_customfunction', 'calls_pluginfunction', 'calls_function',
      'sets_variable', 'reads_variable')
),
-- Aufruf- und Navigationsschritte (eine Zeile je Schritt und Ziel; Via spielt
-- keine Rolle). Deaktivierte nur mit include_disabled.
site_steps AS MATERIALIZED (
  SELECT DISTINCT Script_UUID, File_Name, Step_UUID, Step_Index, Step_ID,
         Is_Enabled, Link_Role, Target_UUID, Target_File
  FROM traced_links
  WHERE Link_Role IN ('calls_script', 'navigates_to_layout')
    AND Target_UUID IS NOT NULL
    AND (Is_Enabled OR getvariable('include_disabled') = TRUE)
),
-- Blinde Stellen — Aufrufschritte (Perform Script, … on Server, … with
-- Callback) ohne statisches Ziel. by_name = Namensformel im Slot List,
-- unresolved = weder Ziel noch Formel (z. B. gelöschtes Script). Bewusst nicht
-- expandierte (ausgeschlossene) Scripts zählen nicht.
list_slot AS (
  SELECT sc.Step_UUID, sc.File_Name, min_by(sc.Calc_Text, sc.Slot_Seq) AS txt
  FROM StepCalculations sc
  WHERE sc.Step_ID IN (1, 164, 210) AND sc.Slot = 'List'
  GROUP BY sc.Step_UUID, sc.File_Name
),
blind_steps AS MATERIALIZED (
  SELECT b.Script_UUID, b.File_Name, b.Step_UUID, CAST(b.Step_Index AS INTEGER) AS Step_Index,
         CAST(b.Step_ID AS INTEGER) AS Step_ID, b.Is_Enabled, ls.txt AS name_calc
  FROM v_script_block_tree b
  JOIN scripts_traced st ON b.Script_UUID = st.uuid AND COALESCE(b.File_Name, '') = st.f
  LEFT JOIN list_slot ls ON ls.Step_UUID = b.Step_UUID AND ls.File_Name IS NOT DISTINCT FROM b.File_Name
  WHERE b.Step_ID IN (1, 164, 210)
    AND (b.Is_Enabled OR getvariable('include_disabled') = TRUE)
    AND (st.uuid, st.f) NOT IN (SELECT uuid, file_key FROM excluded)
    AND NOT st.x_only
    AND NOT EXISTS (SELECT 1 FROM traced_links l
                    WHERE l.Step_UUID = b.Step_UUID AND l.File_Name IS NOT DISTINCT FROM b.File_Name
                      AND l.Link_Role = 'calls_script' AND l.Target_UUID IS NOT NULL)
),
ctx_keys AS (
  SELECT DISTINCT Step_UUID, File_Name FROM site_steps
  UNION SELECT Step_UUID, File_Name FROM blind_steps
),
-- Innerste If-/Else-If-/Else-Ebene (Guard_Level 1 = außen) und Zahl der
-- umschließenden Bedingungen. v_step_guards kennt seit Konverter 2.51.3 jeden
-- aktiven Aufruf- und Navigationsschritt; deaktivierte Schritte haben keine Zeile.
site_guard AS (
  SELECT g.Step_UUID, g.File_Name, g.Guard_Kind, CAST(g.Guard_Level AS INTEGER) AS lvl,
         CAST(g.Guard_Step_Index AS INTEGER) AS g_idx, g.Guard_Calculation_UUID AS g_calc,
         CAST(count(*) OVER (PARTITION BY g.Step_UUID, g.File_Name) AS INTEGER) AS n_if
  FROM v_step_guards g
  JOIN ctx_keys k ON k.Step_UUID = g.Step_UUID AND k.File_Name IS NOT DISTINCT FROM g.File_Name
  WHERE g.Guard_Kind IN ('if', 'elseif', 'else')
  QUALIFY row_number() OVER (PARTITION BY g.Step_UUID, g.File_Name ORDER BY g.Guard_Level DESC) = 1
),
-- Parameterformel des Aufrufs (Slot „Parameter:“ — der Hauptparameter; die
-- Callback-Slots von 210 heißen anders). Ohne DDR-Info vorhanden.
param_slot AS (
  SELECT sc.Step_UUID, sc.File_Name, min_by(sc.Calc_Text, sc.Slot_Seq) AS txt
  FROM StepCalculations sc
  JOIN ctx_keys k ON k.Step_UUID = sc.Step_UUID AND k.File_Name IS NOT DISTINCT FROM sc.File_Name
  WHERE sc.Step_ID IN (1, 164, 210) AND sc.Slot = 'Parameter:'
  GROUP BY sc.Step_UUID, sc.File_Name
),
-- Schritte, die das Ergebnis dieses Aufrufs lesen (Paarung, nur mit DDR-Info).
result_reads AS (
  SELECT e.Pair_Step_UUID AS Step_UUID, e.File_Name,
         list_sort(list_distinct(list(e.Step_Index))) AS readers
  FROM v_dataflow_edges e
  JOIN ctx_keys k ON k.Step_UUID = e.Pair_Step_UUID AND k.File_Name IS NOT DISTINCT FROM e.File_Name
  WHERE e.Flow_Kind = 'result_to_step'
    AND (e.Is_Enabled OR getvariable('include_disabled') = TRUE)
  GROUP BY e.Pair_Step_UUID, e.File_Name
),
-- Unerreichbare Bereiche (2.1.0) — Logik der Regel dead_code_after_exit,
-- auf den Block erweitert: hinter einem aktiven Exit Script (103) / Halt Script
-- (90) ist alles tot bis zum nächsten aktiven Else (69), End If (70), End Loop
-- (73) oder Else If (125), dessen Blocktiefe nicht größer ist (der Zweig bzw.
-- die Schleife, in der der Abbruch steht, endet dort; tiefere Blöcke dazwischen
-- sind mit tot). Ohne solchen Schritt reicht der Bereich bis zum Script-Ende.
blk_marks AS MATERIALIZED (
  SELECT b.Script_UUID, b.File_Name, CAST(b.Step_Index AS INTEGER) AS idx,
         CAST(b.Step_ID AS INTEGER) AS sid, CAST(b.block_depth_before AS INTEGER) AS bd
  FROM v_script_block_tree b
  JOIN scripts_traced st ON b.Script_UUID = st.uuid AND COALESCE(b.File_Name, '') = st.f
  WHERE b.Is_Enabled AND b.Step_ID IN (103, 90, 69, 70, 73, 125)
),
dead_ranges AS MATERIALIZED (
  SELECT t.Script_UUID, t.File_Name, t.idx AS from_idx,
         COALESCE(min(u.idx), 2147483647) AS to_idx
  FROM blk_marks t
  LEFT JOIN blk_marks u
    ON u.Script_UUID = t.Script_UUID AND u.File_Name IS NOT DISTINCT FROM t.File_Name
   AND u.sid IN (69, 70, 73, 125) AND u.idx > t.idx AND u.bd <= t.bd
  WHERE t.sid IN (103, 90)
  GROUP BY t.Script_UUID, t.File_Name, t.idx
),
-- Aufrufkontext je Schritt als Struktur (Formeltexte einzeilig, gekürzt auf
-- 80 Zeichen; der volle Text bis 2 000 Zeichen nur, wenn gekürzt wurde).
step_ctx AS MATERIALIZED (
  SELECT k.Step_UUID, k.File_Name,
    bt.Step_Name AS step_name,
    EXISTS (SELECT 1 FROM dead_ranges dr
            WHERE dr.Script_UUID = bt.Script_UUID AND dr.File_Name IS NOT DISTINCT FROM bt.File_Name
              AND bt.Step_Index > dr.from_idx AND bt.Step_Index < dr.to_idx) AS unreachable,
    CASE WHEN g.Guard_Kind IS NULL THEN NULL ELSE {
      'kind': g.Guard_Kind,
      'level': g.lvl,
      'stepIndex': g.g_idx,
      'calcUuid': g.g_calc,
      'text': CASE WHEN length(gt.t) > 80 THEN left(gt.t, 79) || '…' ELSE gt.t END,
      'textFull': CASE WHEN length(gt.t) > 80 THEN left(c.Formula_Text, 2000) END
    } END AS guard,
    COALESCE(g.n_if, 0) AS n_if,
    CAST(COALESCE(bt.if_depth_before, 0) AS INTEGER) AS if_depth,
    COALESCE(bt.loop_depth_before, 0) > 0 AS in_loop,
    CASE WHEN length(pt.t) > 80 THEN left(pt.t, 79) || '…' ELSE pt.t END AS param_txt,
    rr.readers
  FROM ctx_keys k
  LEFT JOIN v_script_block_tree bt
    ON bt.Step_UUID = k.Step_UUID AND bt.File_Name IS NOT DISTINCT FROM k.File_Name
  LEFT JOIN site_guard g
    ON g.Step_UUID = k.Step_UUID AND g.File_Name IS NOT DISTINCT FROM k.File_Name
  LEFT JOIN CalculationsCatalog c
    ON c.Calculation_UUID = g.g_calc AND c.File_Name IS NOT DISTINCT FROM k.File_Name
  LEFT JOIN param_slot ps
    ON ps.Step_UUID = k.Step_UUID AND ps.File_Name IS NOT DISTINCT FROM k.File_Name
  LEFT JOIN result_reads rr
    ON rr.Step_UUID = k.Step_UUID AND rr.File_Name IS NOT DISTINCT FROM k.File_Name
  CROSS JOIN LATERAL (SELECT trim(regexp_replace(c.Formula_Text, '\s+', ' ', 'g')) AS t) gt
  CROSS JOIN LATERAL (SELECT trim(regexp_replace(ps.txt, '\s+', ' ', 'g')) AS t) pt
),
-- Aufrufstellen je Kante (Script × Rolle × Ziel), nach Schritt sortiert.
-- hop (2.1.0) = Material der Wege: die repräsentative Aufrufstelle (erreichbar
-- vor unerreichbar, unbedingt vor bedingt, dann kleinste Schrittnummer) mit
-- ihrem Kontext und das Aggregat über alle Aufrufstellen der Kante.
edge_sites AS MATERIALIZED (
  SELECT s.Script_UUID AS a, s.File_Name AS a_file, s.Link_Role,
         s.Target_UUID AS b, s.Target_File AS b_file,
         list({
           'stepUuid': s.Step_UUID,
           'stepIndex': s.Step_Index,
           'stepId': s.Step_ID,
           'enabled': s.Is_Enabled,
           'guard': x.guard,
           'conditions': x.n_if,
           'ifDepth': x.if_depth,
           'inLoop': x.in_loop,
           'passesParam': x.param_txt,
           'resultReadAt': x.readers,
           'unreachable': COALESCE(x.unreachable, FALSE)
         } ORDER BY s.Step_Index, s.Step_UUID) AS sites,
         arg_min({
           'stepUuid': s.Step_UUID,
           'stepIndex': s.Step_Index,
           'stepId': s.Step_ID,
           'stepName': x.step_name,
           'guard': x.guard,
           'conditions': x.n_if,
           'ifDepth': x.if_depth,
           'inLoop': x.in_loop,
           'passesParam': x.param_txt,
           'unreachable': COALESCE(x.unreachable, FALSE)
         -- Rang als BIGINT: unerreichbar UND bedingt ergab 3·10⁹ — INT32-Überlauf
         }, CAST(CASE WHEN COALESCE(x.unreachable, FALSE) THEN 2000000000 ELSE 0 END AS BIGINT)
            + CASE WHEN COALESCE(x.if_depth, 0) > 0 THEN 1000000000 ELSE 0 END
            + s.Step_Index) AS rep,
         CAST(count(*) AS INTEGER) AS n_sites,
         bool_and(COALESCE(x.if_depth, 0) > 0) AS all_cond,
         bool_or(COALESCE(x.in_loop, FALSE)) AS any_loop,
         bool_or(s.Step_ID IN (164, 210)) AS any_server,
         bool_or(x.param_txt IS NOT NULL) AS any_param,
         bool_and(COALESCE(x.unreachable, FALSE)) AS all_unreach
  FROM site_steps s
  LEFT JOIN step_ctx x ON x.Step_UUID = s.Step_UUID AND x.File_Name IS NOT DISTINCT FROM s.File_Name
  GROUP BY s.Script_UUID, s.File_Name, s.Link_Role, s.Target_UUID, s.Target_File
),
edge_hops AS MATERIALIZED (
  SELECT a, a_file, Link_Role, b, b_file,
         rep.stepUuid AS step_uuid, rep.stepIndex AS step_index, rep.stepId AS step_id,
         {
           'stepUuid': rep.stepUuid, 'stepIndex': rep.stepIndex, 'stepId': rep.stepId,
           'stepName': rep.stepName, 'guard': rep.guard, 'conditions': rep.conditions,
           'ifDepth': rep.ifDepth, 'inLoop': rep.inLoop, 'passesParam': rep.passesParam,
           'unreachable': rep.unreachable,
           'n': n_sites, 'allConditional': all_cond, 'anyLoop': any_loop,
           'anyServer': any_server, 'anyParam': any_param, 'allUnreachable': all_unreach
         } AS hop
  FROM edge_sites
),
-- ── Vorgänger je Knoten auf dem kürzesten Pfad (Grundlage der Wege) ────────
-- abwärts — Stufe 0 = Chain ab den Seeds, Stufen 1–3 = Kaskaden. Je Knoten
-- gewinnt die früheste Stufe, dann die kleinste Tiefe; Tiebreak UUID und Datei
-- des Vorgängers, dann Schritt. Pfade werden nicht aufgezählt.
down_sets AS (
  SELECT 0 AS stage, uuid, file, d FROM chain_down
  UNION ALL SELECT 1, uuid, file, d FROM casc1
  UNION ALL SELECT 2, uuid, file, d FROM casc2
  UNION ALL SELECT 3, uuid, file, d FROM casc3
),
trig_all AS (
  SELECT 1 AS stage, src_uuid, src_file, b, b_file, Link_Subrole, lay_uuid, lay_file FROM trig_edges1
  UNION ALL SELECT 2, src_uuid, src_file, b, b_file, Link_Subrole, lay_uuid, lay_file FROM trig_edges2
  UNION ALL SELECT 3, src_uuid, src_file, b, b_file, Link_Subrole, lay_uuid, lay_file FROM trig_edges3
),
trig_layouts AS (
  SELECT DISTINCT stage, lay_uuid, COALESCE(lay_file, '') AS lay_f FROM trig_all
),
nav_all AS (
  SELECT 1 AS stage, a, a_file, b, b_file, src_d FROM touch_edges0 WHERE Link_Role = 'navigates_to_layout'
  UNION ALL SELECT 2, a, a_file, b, b_file, src_d FROM touch_edges1 WHERE Link_Role = 'navigates_to_layout'
  UNION ALL SELECT 3, a, a_file, b, b_file, src_d FROM touch_edges2 WHERE Link_Role = 'navigates_to_layout'
),
pred_down_cand AS (
  -- Aufruf innerhalb derselben Stufe (Tiefe d − 1 → d)
  SELECT n.stage, n.uuid, n.file, n.d, c.uuid AS p_uuid, c.file AS p_file, 'call' AS kind, 0 AS kprio,
         ef.step_uuid, ef.step_index, ef.step_id,
         CAST(NULL AS VARCHAR) AS event, CAST(NULL AS VARCHAR) AS o_uuid, CAST(NULL AS VARCHAR) AS o_file,
         ef.hop
  FROM down_sets n
  JOIN down_sets c ON c.stage = n.stage AND c.d = n.d - 1
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.a = c.uuid AND e.a_file IS NOT DISTINCT FROM c.file
   AND e.b = n.uuid AND e.b_file IS NOT DISTINCT FROM n.file
  LEFT JOIN edge_hops ef
    ON ef.Link_Role = 'calls_script'
   AND ef.a = c.uuid AND ef.a_file IS NOT DISTINCT FROM c.file
   AND ef.b = n.uuid AND ef.b_file IS NOT DISTINCT FROM n.file
  WHERE n.d > 0
    AND (c.uuid, COALESCE(c.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
  UNION ALL
  -- Kaskaden-Seed ← betretenes Layout (Ereignis; Owner = gehobene Trigger-Quelle)
  SELECT t.stage, t.b, t.b_file, 0, t.lay_uuid, t.lay_file, 'event', 0,
         NULL, NULL, NULL, t.Link_Subrole, t.src_uuid, t.src_file, NULL
  FROM trig_all t
  UNION ALL
  -- Layout-Start (layout_runtime) — Seed ← Start-Layout (Ereignis)
  SELECT 0, st.b, st.b_file, 0, so.uuid, so.file, 'event', 0,
         NULL, NULL, NULL, st.Link_Subrole, st.a, st.a_file, NULL
  FROM seed_trigger_edges st, start_obj so
  UNION ALL
  -- Kaskaden-Layout ← navigierendes Script (Go to Layout, Schritt-Anker).
  -- Stufe 1 bevorzugt Chain-abwärts-Scripts vor Aufwärts-Touch (expand_up).
  SELECT n.stage - 1, n.b, n.b_file, n.src_d + 1, n.a, n.a_file, 'navigate',
         CASE WHEN n.stage = 1
                   AND (n.a, COALESCE(n.a_file, '')) NOT IN (SELECT uuid, COALESCE(file, '') FROM chain_down)
              THEN 1 ELSE 0 END,
         ef.step_uuid, ef.step_index, ef.step_id, NULL, NULL, NULL, ef.hop
  FROM nav_all n
  JOIN trig_layouts tl ON tl.stage = n.stage AND tl.lay_uuid = n.b AND tl.lay_f = COALESCE(n.b_file, '')
  LEFT JOIN edge_hops ef
    ON ef.Link_Role = 'navigates_to_layout'
   AND ef.a = n.a AND ef.a_file IS NOT DISTINCT FROM n.a_file
   AND ef.b = n.b AND ef.b_file IS NOT DISTINCT FROM n.b_file
),
-- Ein Script nimmt nur Vorgänger seiner frühesten Stufe — sonst bekäme ein
-- Seed (der Start), den eine Kaskade erneut aufruft, einen Vorgänger, und die
-- Vorgängerkette würde zyklisch. So fällt (Stufe, Tiefe) entlang jeder Kette.
node_min_stage AS (
  SELECT uuid, COALESCE(file, '') AS f, MIN(stage) AS stage FROM down_sets GROUP BY 1, 2
),
pred_down AS (
  SELECT * FROM (
    SELECT pc.* FROM pred_down_cand pc
    LEFT JOIN node_min_stage m ON m.uuid = pc.uuid AND m.f = COALESCE(pc.file, '')
    WHERE (m.stage IS NULL OR pc.stage = m.stage)
      -- Der Start hat nie einen Vorgänger (2.1.0): ein Layout-Start, auf den ein
      -- Kettenscript zurücknavigiert, machte die Vorgängerkette sonst zyklisch.
      AND NOT EXISTS (SELECT 1 FROM start_obj so
                      WHERE so.uuid = pc.uuid AND so.file IS NOT DISTINCT FROM pc.file)
  )
  QUALIFY row_number() OVER (
    PARTITION BY uuid, COALESCE(file, '')
    ORDER BY stage, kprio, d, p_uuid, COALESCE(p_file, ''), step_index NULLS LAST, event NULLS LAST,
             o_uuid NULLS LAST, COALESCE(o_file, '')) = 1
),
-- aufwärts — Vorgänger = das aufgerufene Script eine Ebene näher am Start; der
-- Schritt liegt im Aufrufer selbst. Über ALLE Knoten des Aufwärts-Walks (auch
-- solche, die abwärts schon erreicht sind).
chain_up_all AS (
  SELECT uuid, file, MIN(d) AS d FROM chain_up_walk GROUP BY uuid, file
),
pred_up AS (
  SELECT n.uuid, n.file, n.d, c.uuid AS p_uuid, c.file AS p_file,
         ef.step_uuid, ef.step_index, ef.step_id, ef.hop
  FROM chain_up_all n
  JOIN chain_up_all c ON c.d = n.d - 1
  JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.a = n.uuid AND e.a_file IS NOT DISTINCT FROM n.file
   AND e.b = c.uuid AND e.b_file IS NOT DISTINCT FROM c.file
  LEFT JOIN edge_hops ef
    ON ef.Link_Role = 'calls_script'
   AND ef.a = n.uuid AND ef.a_file IS NOT DISTINCT FROM n.file
   AND ef.b = c.uuid AND ef.b_file IS NOT DISTINCT FROM c.file
  WHERE n.d > 0
    AND (c.uuid, COALESCE(c.file, '')) NOT IN (SELECT uuid, file_key FROM excluded)
  QUALIFY row_number() OVER (
    PARTITION BY n.uuid, COALESCE(n.file, '')
    ORDER BY c.uuid, COALESCE(c.file, ''), ef.step_index NULLS LAST) = 1
),
pred_rows AS (
  SELECT 'down' AS dir, uuid, file, d, p_uuid, p_file, kind, stage,
         step_uuid, step_index, step_id, event, o_uuid, o_file, hop
  FROM pred_down
  UNION ALL
  SELECT 'up', uuid, file, d, p_uuid, p_file, 'call', 0,
         step_uuid, step_index, step_id, NULL, NULL, NULL, hop
  FROM pred_up
),
-- ── Einstiege aufwärts (2.1.0) ─────────────────────────────────────────────
-- je Knoten des Aufwärts-Walks: Aufrufer im Katalog (nach dem Filter deaktivierter Schritte) — 0 =
-- Wurzel; sonst endet der Walk dort am Budget oder am Ausschluss.
up_info AS (
  SELECT n.uuid, n.file, n.d,
         CAST(count(DISTINCT e.a || '~' || COALESCE(e.a_file, '')) AS INTEGER) AS n_callers,
         (n.uuid, COALESCE(n.file, '')) IN (SELECT uuid, file_key FROM excluded) AS is_excl
  FROM chain_up_all n
  LEFT JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.b = n.uuid AND e.b_file IS NOT DISTINCT FROM n.file
  GROUP BY n.uuid, n.file, n.d
),
-- Owner-Kanten (Trigger, Buttons, Menü, Datei) der Aufwärts-Knoten, nach Art
-- gruppiert. Bei einem Layout-Start sind die eigenen Trigger des Start-Layouts
-- die Seeds, keine Einstiege.
entry_raw AS (
  SELECT oe.dst_uuid AS s_uuid, oe.dst_file AS s_file,
         CASE WHEN oe.o_type = 'CustomMenuItem' THEN 'menu'
              WHEN oe.o_type = 'File' THEN 'file'
              WHEN oe.Link_Subrole = 'button_action' THEN 'button'
              ELSE 'trigger' END AS gkind,
         CASE WHEN oe.o_type IN ('CustomMenuItem') OR oe.Link_Subrole IN ('button_action', 'menu_action')
              THEN NULL ELSE oe.Link_Subrole END AS event,
         oe.o_uuid, oe.o_type, oe.o_file, oe.o_lay_uuid, oe.o_lay_file
  FROM owner_edges oe
  JOIN chain_up_all u ON u.uuid = oe.dst_uuid AND u.file IS NOT DISTINCT FROM oe.dst_file
  WHERE NOT EXISTS (SELECT 1 FROM start_obj so
                    WHERE so.otype = 'Layout' AND so.uuid = oe.o_lay_uuid
                      AND so.file IS NOT DISTINCT FROM oe.o_lay_file)
),
-- Einstiege der neuen Knoten aus „Quelle verfolgen“ (2.2.0) — dieselbe
-- Gruppierung; die Knoten liegen außerhalb des Aufwärts-Walks.
x_entry_raw AS (
  SELECT t.b AS s_uuid, t.b_file AS s_file,
         CASE WHEN t.a_type = 'CustomMenuItem' THEN 'menu'
              WHEN t.a_type = 'File' THEN 'file'
              WHEN t.Link_Subrole = 'button_action' THEN 'button'
              ELSE 'trigger' END AS gkind,
         CASE WHEN t.a_type IN ('CustomMenuItem') OR t.Link_Subrole IN ('button_action', 'menu_action')
              THEN NULL ELSE t.Link_Subrole END AS event,
         t.a AS o_uuid, t.a_type AS o_type, t.a_file AS o_file,
         CASE WHEN t.a_type = 'LayoutObject' THEN lp.layout_uuid
              WHEN t.a_type = 'Layout' THEN t.a END AS o_lay_uuid,
         CASE WHEN t.a_type = 'LayoutObject' THEN lp.layout_file
              WHEN t.a_type = 'Layout' THEN t.a_file END AS o_lay_file
  FROM raw_links t
  JOIN (SELECT DISTINCT uuid, file FROM x_assign) x
    ON t.b = x.uuid AND t.b_file IS NOT DISTINCT FROM x.file
  LEFT JOIN lo_parent lp ON t.a_type = 'LayoutObject' AND lp.lo = t.a AND lp.lo_file = COALESCE(t.a_file, '')
  WHERE t.Link_Role = 'triggers_script'
),
entry_all AS (
  SELECT s_uuid, s_file, gkind, event, o_uuid, o_type, o_file, o_lay_uuid, o_lay_file FROM entry_raw
  UNION ALL
  SELECT s_uuid, s_file, gkind, event, o_uuid, o_type, o_file, o_lay_uuid, o_lay_file FROM x_entry_raw
),
x_info AS (
  SELECT x.way_id, x.uuid, x.file, x.xd,
         CAST(count(DISTINCT e.a || '~' || COALESCE(e.a_file, '')) AS INTEGER) AS n_callers,
         (x.uuid, COALESCE(x.file, '')) IN (SELECT uuid, file_key FROM excluded) AS is_excl
  FROM x_assign x
  LEFT JOIN raw_links e
    ON e.Link_Role = 'calls_script'
   AND e.b = x.uuid AND e.b_file IS NOT DISTINCT FROM x.file
  GROUP BY x.way_id, x.uuid, x.file, x.xd
),
entry_rows AS (
  SELECT r.s_uuid, r.s_file, r.gkind, r.event,
         CAST(count(DISTINCT r.o_uuid || '~' || COALESCE(r.o_file, '')) AS INTEGER) AS n,
         CAST(count(DISTINCT r.o_lay_uuid || '~' || COALESCE(r.o_lay_file, '')) AS INTEGER) AS n_layouts,
         (SELECT list({'uuid': x.lu, 'name': x.ln, 'file': x.lf} ORDER BY x.ln, x.lf, x.lu)
            FROM (SELECT DISTINCT r2.o_lay_uuid AS lu, lo.Object_Name AS ln, r2.o_lay_file AS lf
                  FROM entry_all r2
                  JOIN ObjectCatalog lo ON lo.Object_UUID = r2.o_lay_uuid
                                       AND lo.File_Name IS NOT DISTINCT FROM r2.o_lay_file
                  WHERE r2.s_uuid = r.s_uuid AND r2.s_file IS NOT DISTINCT FROM r.s_file
                    AND r2.gkind = r.gkind AND r2.event IS NOT DISTINCT FROM r.event
                  ORDER BY ln, lf, lu LIMIT 10) x) AS layouts,
         (SELECT list({'id': x.oid, 'type': x.ot, 'label': x.ol} ORDER BY x.oid)
            FROM (SELECT DISTINCT r2.o_uuid || COALESCE('::' || r2.o_file, '') AS oid,
                         r2.o_type AS ot, oo.Object_Name AS ol
                  FROM entry_all r2
                  LEFT JOIN ObjectCatalog oo ON oo.Object_UUID = r2.o_uuid
                                            AND oo.File_Name IS NOT DISTINCT FROM r2.o_file
                  WHERE r2.s_uuid = r.s_uuid AND r2.s_file IS NOT DISTINCT FROM r.s_file
                    AND r2.gkind = r.gkind AND r2.event IS NOT DISTINCT FROM r.event
                  ORDER BY oid LIMIT 3) x) AS sample
  FROM entry_all r
  GROUP BY r.s_uuid, r.s_file, r.gkind, r.event
),
-- ── Wirkung je Script (Zahl verschiedener Ziele je Touch-Rolle) ─────────────
-- für alle ausgegebenen Scripts, mit denselben Schaltern wie die Touch-Stufe.
effects AS (
  SELECT a AS uuid, a_file AS file,
         list({'role': Link_Role, 'n': n} ORDER BY Link_Role) AS eff
  FROM (
    SELECT rl.a, rl.a_file, rl.Link_Role,
           CAST(count(DISTINCT rl.b || '~' || COALESCE(rl.b_file, '')) AS INTEGER) AS n
    FROM raw_links rl
    JOIN kept k ON k.type = 'Script' AND k.uuid = rl.a AND k.file IS NOT DISTINCT FROM rl.a_file
    WHERE rl.a_type = 'Script'
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
    GROUP BY rl.a, rl.a_file, rl.Link_Role
  )
  GROUP BY a, a_file
),
-- ── Kennzahlen ─────────────────────────────────────────────────────────────
dyn AS (
  SELECT COUNT(*) FILTER (WHERE name_calc IS NOT NULL) AS n,
         COUNT(*) FILTER (WHERE name_calc IS NULL) AS n_unresolved
  FROM blind_steps
),
disabled_steps AS (
  SELECT COUNT(DISTINCT Step_UUID || '~' || COALESCE(File_Name, '')) AS n
  FROM traced_links
  WHERE NOT Is_Enabled AND NOT src_excluded AND NOT x_only
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
  sg.s_reason                                           AS sugg_reason,
  CASE WHEN ef.eff IS NOT NULL
       THEN CAST(to_json({'effects': ef.eff}) AS VARCHAR) END AS payload
FROM kept k
LEFT JOIN suggestions sg ON sg.uuid = k.uuid AND sg.f = COALESCE(k.file, '')
LEFT JOIN effects ef ON ef.uuid = k.uuid AND ef.file IS NOT DISTINCT FROM k.file
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
  NULL, NULL, NULL, NULL, NULL,
  -- Aufrufstellen nur an Aufruf- und Navigationskanten; ohne Schrittzeile
  -- (MBS FM.RunScript) ist die Kante approx.
  CASE WHEN e.role IN ('calls_script', 'navigates_to_layout') THEN CAST(to_json({
    'precision': CASE WHEN es.sites IS NULL THEN 'approx' ELSE 'exact' END,
    'callSites': es.sites
  }) AS VARCHAR) END
FROM final_edges e
LEFT JOIN edge_sites es
  ON e.role IN ('calls_script', 'navigates_to_layout')
 AND es.Link_Role = e.role
 AND es.a = e.src_uuid AND es.a_file IS NOT DISTINCT FROM e.src_file
 AND es.b = e.dst_uuid AND es.b_file IS NOT DISTINCT FROM e.dst_file
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
  NULL, NULL, NULL, NULL, NULL,
  NULL
FROM seeds s
JOIN ObjectCatalog oc
  ON oc.Object_UUID = s.uuid AND oc.File_Name IS NOT DISTINCT FROM s.file
UNION ALL
-- Vorgänger je Knoten (auch außerhalb von node_limit — Beschriftung inklusive)
SELECT
  'pred',
  pr.uuid || COALESCE('::' || pr.file, '')              AS id,
  pr.uuid,
  oc.Object_Name,
  oc.Object_Type,
  pr.file,
  pr.d,
  NULL, NULL, NULL, NULL, NULL,
  pr.p_uuid || COALESCE('::' || pr.p_file, '')          AS source,
  NULL,
  pr.dir                                                AS role,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  CAST(to_json({
    'dir': pr.dir,
    'pred': pr.p_uuid || COALESCE('::' || pr.p_file, ''),
    'kind': pr.kind,
    'stage': pr.stage,
    'depth': pr.d,
    'stepUuid': pr.step_uuid,
    'stepIndex': pr.step_index,
    'stepId': pr.step_id,
    'event': pr.event,
    'owner': pr.o_uuid || COALESCE('::' || pr.o_file, ''),
    'crossFile': pr.file IS DISTINCT FROM pr.p_file,
    'hop': pr.hop
  }) AS VARCHAR)
FROM pred_rows pr
JOIN ObjectCatalog oc
  ON oc.Object_UUID = pr.uuid AND oc.File_Name IS NOT DISTINCT FROM pr.file
UNION ALL
-- Blinde Stellen — Aufrufschritte ohne statisches Ziel, am aufrufenden Script
SELECT
  'blind',
  bs.Step_UUID || '#dyncall' || COALESCE('::' || bs.File_Name, '') AS id,
  bs.Step_UUID,
  CASE WHEN length(nt.t) > 80 THEN left(nt.t, 79) || '…' ELSE nt.t END,
  'DynamicCall',
  bs.File_Name,
  NULL, NULL, NULL, NULL, NULL, NULL,
  bs.Script_UUID || COALESCE('::' || bs.File_Name, '')  AS source,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  CAST(to_json({
    'kind': CASE WHEN bs.name_calc IS NULL THEN 'unresolved' ELSE 'by_name' END,
    'stepUuid': bs.Step_UUID,
    'stepIndex': bs.Step_Index,
    'stepId': bs.Step_ID,
    'enabled': bs.Is_Enabled,
    'name': CASE WHEN length(nt.t) > 80 THEN left(nt.t, 79) || '…' ELSE nt.t END,
    'nameFull': CASE WHEN length(nt.t) > 80 THEN left(bs.name_calc, 2000) END,
    'guard': x.guard,
    'conditions': x.n_if,
    'ifDepth': x.if_depth,
    'inLoop': x.in_loop,
    'passesParam': x.param_txt,
    'unreachable': COALESCE(x.unreachable, FALSE),
    'stepName': x.step_name
  }) AS VARCHAR)
FROM blind_steps bs
LEFT JOIN step_ctx x ON x.Step_UUID = bs.Step_UUID AND x.File_Name IS NOT DISTINCT FROM bs.File_Name
CROSS JOIN LATERAL (SELECT trim(regexp_replace(bs.name_calc, '\s+', ' ', 'g')) AS t) nt
UNION ALL
SELECT
  'stats', 'stats',
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  CAST(to_json({
    'disabledSteps': (SELECT n FROM disabled_steps),
    'dynamicCalls': (SELECT n FROM dyn),
    'unresolvedCalls': (SELECT n_unresolved FROM dyn),
    'includeDisabled': getvariable('include_disabled') = TRUE
  }) AS VARCHAR)
UNION ALL
-- Einstiegsgruppen je Script des Aufwärts-Walks (ungedeckelt)
SELECT
  'entry',
  er.s_uuid || COALESCE('::' || er.s_file, '') || '|' || er.gkind || '|' || COALESCE(er.event, '') AS id,
  NULL, NULL, NULL, er.s_file,
  NULL, NULL, NULL, NULL, NULL, NULL,
  er.s_uuid || COALESCE('::' || er.s_file, '')          AS source,
  NULL,
  er.gkind                                              AS role,
  er.event                                              AS subrole,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  CAST(to_json({
    'kind': er.gkind, 'event': er.event, 'n': er.n, 'nLayouts': er.n_layouts,
    'layouts': COALESCE(er.layouts, []), 'sample': COALESCE(er.sample, [])
  }) AS VARCHAR)
FROM entry_rows er
UNION ALL
-- Aufwärts-Knoten: Tiefe, Aufrufer im Katalog, Ausschluss
SELECT
  'upinfo',
  ui.uuid || COALESCE('::' || ui.file, '')              AS id,
  ui.uuid, oc.Object_Name, oc.Object_Type, ui.file,
  ui.d,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  CAST(to_json({'depth': ui.d, 'nCallers': ui.n_callers, 'excluded': ui.is_excl}) AS VARCHAR)
FROM up_info ui
JOIN ObjectCatalog oc
  ON oc.Object_UUID = ui.uuid AND oc.File_Name IS NOT DISTINCT FROM ui.file
UNION ALL
-- „Quelle verfolgen“ (2.2.0): Vorgänger je Weg-ID (enter = Go to Layout auf ein
-- Owner-Layout des Einstiegs, call = Aufruf), mit Schritt-Kontext
SELECT
  'xpred',
  xb.uuid || COALESCE('::' || xb.file, '')              AS id,
  xb.uuid,
  oc.Object_Name,
  oc.Object_Type,
  xb.file,
  xb.xd,
  NULL, NULL, NULL, NULL, NULL,
  xb.p_uuid || COALESCE('::' || xb.p_file, '')          AS source,
  NULL,
  xb.way_id                                             AS role,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  CAST(to_json({
    'way': xb.way_id,
    'pred': xb.p_uuid || COALESCE('::' || xb.p_file, ''),
    'kind': xb.kind,
    'depth': xb.xd,
    'layout': xb.lay_uuid || COALESCE('::' || xb.lay_file, ''),
    'layoutLabel': lo.Object_Name,
    'event': xb.event,
    'crossFile': xb.file IS DISTINCT FROM xb.p_file,
    'hop': ef.hop
  }) AS VARCHAR)
FROM x_best xb
JOIN ObjectCatalog oc
  ON oc.Object_UUID = xb.uuid AND oc.File_Name IS NOT DISTINCT FROM xb.file
LEFT JOIN ObjectCatalog lo
  ON xb.kind = 'enter' AND lo.Object_UUID = xb.lay_uuid AND lo.File_Name IS NOT DISTINCT FROM xb.lay_file
LEFT JOIN edge_hops ef
  ON ef.Link_Role = CASE WHEN xb.kind = 'enter' THEN 'navigates_to_layout' ELSE 'calls_script' END
 AND ef.a = xb.uuid AND ef.a_file IS NOT DISTINCT FROM xb.file
 AND ef.b = CASE WHEN xb.kind = 'enter' THEN xb.lay_uuid ELSE xb.p_uuid END
 AND ef.b_file IS NOT DISTINCT FROM CASE WHEN xb.kind = 'enter' THEN xb.lay_file ELSE xb.p_file END
UNION ALL
-- „Quelle verfolgen“: neue Knoten (ein Weg je Knoten) mit Tiefe ab dem Einstieg
SELECT
  'xupinfo',
  xi.uuid || COALESCE('::' || xi.file, '')              AS id,
  xi.uuid, oc.Object_Name, oc.Object_Type, xi.file,
  xi.xd,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  xi.way_id                                             AS role,
  NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL,
  CAST(to_json({'way': xi.way_id, 'depth': xi.xd, 'nCallers': xi.n_callers, 'excluded': xi.is_excl}) AS VARCHAR)
FROM x_info xi
JOIN ObjectCatalog oc
  ON oc.Object_UUID = xi.uuid AND oc.File_Name IS NOT DISTINCT FROM xi.file
-- Tiebreak über id, role (Richtung der pred-Zeilen), subrole und trace_kind —
-- Kanten derselben id unterscheiden sich in der subrole (Wiederholungsindex
-- eines Felds, on_server neben dem einfachen Aufruf); zwei Abrufe liefern
-- dieselbe Zeilenfolge.
ORDER BY row_kind, degree DESC NULLS LAST, id, role NULLS FIRST,
         subrole NULLS FIRST, trace_kind NULLS FIRST;
