-- @template_type: report
-- @title: Graph Trace Data (Field / Variable Data Flow Walk)
-- @description: Datenfluss-Trace ab einem Feld oder einer Variable — Herkunft (dir=up) bzw. Verwendung (dir=down) über Schritte, Variablen, Scriptparameter und -ergebnisse, Feldformeln und Einstiege; Walk über Zustände auf v_dataflow_edges
-- @params: start (required, UUID), start_file, dir, field_levels, var_levels, step_limit, call_context, include_control, include_sinks, node_limit, exclude, expand_way, include_reset, ways_limit, labels_all, prof_layouts, prof_scripts, prof_ui_vars, prof_hub_vars, start_step, start_role
-- @version: 1.5.0
-- @author: Marcel / Claude
-- @tags: graph, trace, dataflow, explorer
-- @note: 1.5.0 — Sammel-Ketten zählen als eine Variablen-Ebene: eine local_def_use-Kante,
--        deren Leser-Schritt dieselbe Variable selbst setzt ($x = $x & …), erhöht vl
--        nicht (vinc FALSE). Sonst brach eine Kette mit mehr Gliedern als var_levels
--        ab, obwohl der Wert ankommt.
--        1.4.0 — Schritt-Anker für lokale Startvariablen:
--        start_step + start_role (vom Service geprüft). read: Herkunft nur über die
--        Setzer, die diesen Leser erreichen (local_def_use, sonst „nicht
--        initialisiert“); set: Herkunft = Quellen dieses Setzers, Verwendung = die
--        Leser, die er erreicht.
--        1.3.0 — Variable als Startobjekt (ohne Schritt-Anker):
--        global/superglobal über den Variablenknoten (Herkunft step_sets_variable,
--        Verwendung variable_to_step + Senken); lokal über die Setz-Schritte
--        (step_sets_variable bleibt nur für die Startvariable erhalten) bzw. die
--        Leser aus local_def_use/local_uninitialized (Startkanten
--        variable_to_step). Weg = (Variable, Setz- bzw. Lese-Schritt). Der Start
--        ist nie Haltepunkt des Profils.
--        1.2.0 — Lösungsprofil: bestätigte Regeln als Knotenlisten;
--        technische Layouts verlieren ihre Eingabe-Einstiege, Infrastruktur-Scripts
--        (Script, Parameter, Ergebnis) und UI-Zustands-/Hub-Variablen sind Haltepunkte
--        (sichtbar, nicht expandiert); Zähler profile_applied, Wirkungsgruppe
--        infrastructure.
--        1.1.0 — Wege: Weg = (Feld der Ebene, Schreibstelle) bzw. bei
--        Verwendung (Feld, Lesestelle); je Weg Einstiegsgruppen, Pfad, Präzision;
--        Gruppe „Zurücksetzen“, Wirkungsliste, Übersicht Feld → Feld,
--        „Quelle verfolgen“ (expand_way).
--        1.0.0 — Core-Endpoint /api/graph/trace?mode=data.
--        Liest nur v_dataflow_edges (Schema 1.43.0, Datenfluss-Phase); der Service
--        prüft vorher, ob die Tabelle existiert (DATAFLOW_NOT_BUILT / SCHEMA_DRIFT).
--        Knotenidentität (UUID, Datei) als composite id uuid + '::' + file wie im
--        Subgraph; Pseudoknoten tragen eine UUID mit '#'-Suffix.
--
-- ============================================================================
-- PARAMETER (von graph.service.js via Joi mit Defaults gesetzt)
-- ============================================================================
--   start            Feld- oder Variablen-UUID (Pflicht)   start_file   Datei (Klon-Disambiguierung)
--   dir              'up' Herkunft | 'down' Verwendung                         (Default up)
--   field_levels     Feld-zu-Feld-Übergänge 1..10; ein Feld auf dieser Ebene ist
--                    Blatt (1 = direkte Schreibstellen mit Einstiegen)         (Default 1)
--   var_levels       Übergänge über Variable/Parameter/Ergebnis 1..10          (Default 5)
--                    (eine Sammel-Kette $x = $x & … zählt als ein Übergang)
--   step_limit       Schritte je Pfad 10..300                                  (Default 150)
--   call_context     1 = Aufrufkontext k = 1, 0 = kontextfrei                  (Default 1)
--   include_control  Steuer-/Guard-Kanten als Blätter                          (Default FALSE)
--   include_sinks    Senken als Blätter (nur down)                             (Default TRUE)
--   node_limit       Knoten-Deckel der Antwort                                 (Default 1000)
--   exclude          Composite-IDs uuid::file, kommasepariert; ausgeschlossene
--                    Knoten bleiben sichtbar, werden aber nicht expandiert
--   expand_way       Weg-IDs (12 Hex), kommasepariert: „Quelle verfolgen“ — die
--                    Quellfelder dieser Wege gehen eine Feldebene weiter
--   include_reset    Zurücksetzen-Schreibstellen als Wege statt als Gruppe
--   ways_limit       Wege in der Antwort 1..2000                               (Default 300)
--   labels_all       Beschriftung für alle Pfadknoten (Mermaid je Weg), sonst nur
--                    für Graphknoten, Weg-Enden, Felder und Einstiege
--   prof_layouts     Lösungsprofil (vom Service aufgelöst, nur bestätigte Regeln),
--   prof_scripts     je kommaseparierte Composite-IDs uuid::file: technische Layouts,
--   prof_ui_vars     Infrastruktur-Scripts, UI-Zustandsvariablen, Hub-Variablen;
--   prof_hub_vars    leer = Profil aus (profile=off oder keine Regel)
--   start_step       Schritt-Anker (Step-UUID) einer lokalen Startvariable, sonst leer
--   start_role       read | set — Rolle des Ankerschritts für die Startvariable
--
-- WALK — Zustand (Knoten, letztes Feld, Schreibstelle, dmode, cmode,
-- Aufrufstelle) mit USING KEY; je Zustand zählt der erste (kürzeste) Fund.
--   up:   Kanten rückwärts. data und entry immer, Ablaufkanten (script_runs_step,
--         step_calls_script) nur außerhalb dmode; nach einer Ablaufkante (cmode)
--         keine Datenkanten mehr. dmode = Wert kam über Variable/Parameter/Ergebnis.
--   down: Kanten vorwärts, nur data.
--   Aufrufkontext: up — result_to_step setzt die Aufrufstelle (Pair_Step_UUID);
--         step_passes_param führt dann nur zu ihr. down — step_passes_param setzt
--         sie, result_to_step führt nur zu Lesern mit dieser Paarung. Ohne
--         Aufrufstelle geht der Walk zu allen (context_open).
--   Deaktivierte Schritte (Is_Enabled = FALSE) sind aus (gezählt);
--   lokale Variablen nur über local_def_use (step_sets_variable auf eine lokale
--   Variable ist Anker, keine Kante des Walks).
--
-- AUSGABE — getaggte Union (row_kind), die der Service partitioniert:
--   'node'  Knoten (flow_role, Ebenen, Tiefe, Pseudo-Eigentümer)
--   'edge'  Kanten Datenfluss-Richtung From → To (flow_kind, flow_class, precision)
--   'ref'   Knoten außerhalb von node_limit, die Wege/Gruppen nennen (nur Beschriftung)
--   'way'   ein Weg (payload JSON: Ebene, Feld, Schreibstelle, Einstiegsgruppen, Pfad)
--   'reset' Gruppe „Zurücksetzen“ (payload JSON, nur up)
--   'usage' Wirkungsgruppe (payload JSON, nur down)
--   'overview' Weg 0: Feld → Feld über alle Ebenen (payload JSON)
--   'stats' eine Zeile mit Kennzahlen, Kürzungen und blinden Stellen
--
-- WEGE: Zustände mit gesetzter Schreibstelle tragen die Weg-ID
-- wid = left(md5(lastf || '>' || writer), 12). Ebene = min(fl) + 1. Pfad = die
-- Zustandskanten des Wegs (je Knoten der erste Fund) plus die Vorgängerkette vom
-- Feld des Wegs zurück zum Start. Einstiege (up) gruppiert nach Art: button ·
-- trigger (Ereignis) · file (Datei-Trigger, Ereignis) · menu · input · import ·
-- auto_enter (Art); Layouts der Einstiege gekappt.
-- ============================================================================

WITH RECURSIVE
start_obj0 AS (
  SELECT
    CAST(getvariable('start') AS VARCHAR) AS uuid,
    COALESCE(
      NULLIF(CAST(getvariable('start_file') AS VARCHAR), ''),
      (SELECT File_Name FROM ObjectCatalog
       WHERE Object_UUID = getvariable('start') AND Object_Type IN ('Field', 'Variable')
       ORDER BY File_Name LIMIT 1)
    ) AS file
),
-- Startart: Field oder Variable (lokal: Startkanten über die Schritte, s. start_var_edges)
start_obj AS (
  SELECT o.uuid, o.file,
         COALESCE((SELECT any_value(c.Object_Type) FROM ObjectCatalog c
                   WHERE c.Object_UUID = o.uuid AND c.File_Name IS NOT DISTINCT FROM o.file
                     AND c.Object_Type IN ('Field', 'Variable')), 'Field') AS kind
  FROM start_obj0 o
),
start_node AS (
  SELECT uuid || '::' || COALESCE(file, '') AS id, kind FROM start_obj
),
params AS (
  SELECT
    CAST(getvariable('dir') AS VARCHAR)            AS dir,
    CAST(getvariable('field_levels') AS INTEGER)   AS fl_max,
    CAST(getvariable('var_levels') AS INTEGER)     AS vl_max,
    CAST(getvariable('step_limit') AS INTEGER)     AS depth_max,
    CAST(getvariable('call_context') AS INTEGER)   AS cc,
    CAST(getvariable('include_control') AS BOOLEAN) AS inc_ctl,
    CAST(getvariable('include_sinks') AS BOOLEAN)  AS inc_sinks,
    CAST(getvariable('node_limit') AS INTEGER)     AS node_limit,
    COALESCE(CAST(getvariable('include_reset') AS BOOLEAN), FALSE) AS inc_reset,
    COALESCE(CAST(getvariable('ways_limit') AS INTEGER), 300)       AS ways_limit,
    COALESCE(CAST(getvariable('labels_all') AS BOOLEAN), FALSE)    AS labels_all,
    200000                                         AS state_limit
),
-- Ausschlussliste (composite id; Start nie ausschließbar)
excluded AS (
  SELECT x.id
  FROM (
    SELECT CASE WHEN contains(item, '::') THEN trim(item) ELSE trim(item) || '::' END AS id
    FROM (SELECT unnest(string_split(COALESCE(CAST(getvariable('exclude') AS VARCHAR), ''), ',')) AS item)
    WHERE trim(item) <> ''
  ) x
  WHERE x.id NOT IN (SELECT id FROM start_node)
),
-- „Quelle verfolgen“: Weg-IDs, deren Quellfelder eine Ebene weiter dürfen
expand_ids AS (
  SELECT DISTINCT lower(trim(item)) AS id
  FROM (SELECT unnest(string_split(COALESCE(CAST(getvariable('expand_way') AS VARCHAR), ''), ',')) AS item)
  WHERE trim(item) <> ''
),
-- Lösungsprofil: bestätigte Regeln als Knotenlisten
prof_list AS (
  SELECT k.kind, trim(k.item) AS id
  FROM (
    SELECT 'technical_layout' AS kind, unnest(string_split(COALESCE(CAST(getvariable('prof_layouts') AS VARCHAR), ''), ',')) AS item
    UNION ALL
    SELECT 'boundary_script', unnest(string_split(COALESCE(CAST(getvariable('prof_scripts') AS VARCHAR), ''), ','))
    UNION ALL
    SELECT 'ui_state_variable', unnest(string_split(COALESCE(CAST(getvariable('prof_ui_vars') AS VARCHAR), ''), ','))
    UNION ALL
    SELECT 'hub_variable', unnest(string_split(COALESCE(CAST(getvariable('prof_hub_vars') AS VARCHAR), ''), ','))
  ) k
  WHERE trim(k.item) <> ''
),
-- Feldobjekte auf technischen Layouts: ihre Eingabe-Einstiege entfallen
prof_tech_lo AS MATERIALIZED (
  SELECT DISTINCT lo.Object_UUID || '::' || lo.File_Name AS id
  FROM prof_list p
  JOIN Layouts l ON p.kind = 'technical_layout' AND l.L_UUID || '::' || l.File_Name = p.id
  JOIN LayoutObjects lo ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
),
-- Haltepunkte: Infrastruktur-Script mit Parameter und Ergebnis, Variablen
prof_stop AS MATERIALIZED (
  SELECT id, kind FROM prof_list WHERE kind IN ('ui_state_variable', 'hub_variable', 'boundary_script')
  UNION ALL
  SELECT split_part(id, '::', 1) || sfx || substr(id, length(split_part(id, '::', 1)) + 1), 'boundary_script'
  FROM prof_list, (VALUES ('#param'), ('#result')) v(sfx)
  WHERE kind = 'boundary_script'
),
-- Schritt-Anker: leer = kein Anker
start_anchor AS (
  SELECT NULLIF(CAST(getvariable('start_step') AS VARCHAR), '') AS step,
         COALESCE(NULLIF(CAST(getvariable('start_role') AS VARCHAR), ''), 'read') AS role
),
-- erlaubte Setzer der Startvariable bei Anker: read → die den Leser erreichen,
-- set → der Ankerschritt selbst
start_setters AS (
  SELECT d.From_UUID AS uuid
  FROM v_dataflow_edges d, start_obj so, start_anchor a
  WHERE a.step IS NOT NULL AND a.role = 'read' AND so.kind = 'Variable'
    AND d.Flow_Kind = 'local_def_use' AND d.Variable_UUID = so.uuid
    AND d.File_Name IS NOT DISTINCT FROM so.file AND d.To_UUID = a.step
  UNION
  SELECT a.step FROM start_anchor a WHERE a.step IS NOT NULL AND a.role = 'set'
),
-- lokale Variablen: step_sets_variable auf sie ist nur Anker
locvar AS MATERIALIZED (
  SELECT DISTINCT md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) AS uuid
  FROM VariablesCatalog WHERE Variable_Scope = 'local'
),
-- Sammel-Glieder: Schritte, die eine lokale Variable setzen (für vinc: liest ein
-- Schritt die Variable, die er selbst setzt, ist die local_def_use-Kante kein
-- neuer Übergang über eine Variable, sondern Teil derselben Sammel-Kette)
var_setters AS MATERIALIZED (
  SELECT DISTINCT From_UUID AS acc_step, From_File AS acc_file, To_UUID AS acc_var
  FROM v_dataflow_edges WHERE Flow_Kind = 'step_sets_variable'
),
-- Lokale Startvariable, Verwendung: Variable → jeder Leser im Script (aus
-- local_def_use bzw. local_uninitialized mit dieser Variable) als variable_to_step
start_var_edges AS (
  SELECT DISTINCT
    so.uuid || '::' || COALESCE(so.file, '') AS f, 'Variable' AS fk,
    d.To_UUID || '::' || COALESCE(d.To_File, '') AS t, d.To_Kind AS tk,
    'variable_to_step' AS kind, 'data' AS cls, 'exact' AS prec,
    CAST(NULL AS VARCHAR) AS subrole, FALSE AS cross_file,
    COALESCE(d.Is_Enabled, TRUE) AS enabled,
    d.To_UUID || '::' || COALESCE(d.File_Name, '') AS step_id,
    CAST(NULL AS VARCHAR) AS pair, CAST(NULL AS VARCHAR) AS callsite,
    TRUE AS vinc, CAST(NULL AS VARCHAR) AS sql_res, CAST(NULL AS VARCHAR) AS wk
  FROM start_obj so
  CROSS JOIN start_anchor a
  JOIN v_dataflow_edges d
    ON so.kind = 'Variable' AND so.uuid IN (SELECT uuid FROM locvar)
   AND d.Variable_UUID = so.uuid AND d.File_Name IS NOT DISTINCT FROM so.file
   AND d.Flow_Kind IN ('local_def_use', 'local_uninitialized')
  -- mit Anker (set): nur die Leser, die dieser Setzer erreicht
  WHERE a.step IS NULL OR (a.role = 'set' AND d.Flow_Kind = 'local_def_use' AND d.From_UUID = a.step)
  UNION
  -- Anker an einem Leser ohne erreichenden Setzer: Quelle „nicht initialisiert“
  SELECT DISTINCT
    d.From_UUID || '::' || COALESCE(d.From_File, '') AS f, d.From_Kind AS fk,
    so.uuid || '::' || COALESCE(so.file, '') AS t, 'Variable' AS tk,
    'local_uninitialized' AS kind, 'data' AS cls, d.Precision AS prec,
    CAST(NULL AS VARCHAR) AS subrole, FALSE AS cross_file,
    COALESCE(d.Is_Enabled, TRUE) AS enabled,
    d.To_UUID || '::' || COALESCE(d.File_Name, '') AS step_id,
    CAST(NULL AS VARCHAR) AS pair, CAST(NULL AS VARCHAR) AS callsite,
    FALSE AS vinc, CAST(NULL AS VARCHAR) AS sql_res, CAST(NULL AS VARCHAR) AS wk
  FROM start_obj so
  CROSS JOIN start_anchor a
  JOIN v_dataflow_edges d
    ON so.kind = 'Variable' AND a.step IS NOT NULL AND a.role = 'read'
   AND d.Flow_Kind = 'local_uninitialized' AND d.Variable_UUID = so.uuid
   AND d.File_Name IS NOT DISTINCT FROM so.file AND d.To_UUID = a.step
),
-- Kanten des Walks (ohne deaktivierte Schritte); cls: data · entry · flow
-- (Ablaufkanten) · ctl (Steuer-/Guard-Blätter) · sink
e_all AS MATERIALIZED (
  SELECT
    From_UUID || '::' || COALESCE(From_File, '') AS f, From_Kind AS fk,
    To_UUID || '::' || COALESCE(To_File, '')     AS t, To_Kind AS tk,
    Flow_Kind AS kind,
    CASE WHEN Flow_Class IN ('data', 'entry', 'sink') THEN Flow_Class
         WHEN Flow_Kind IN ('script_runs_step', 'step_calls_script') THEN 'flow'
         ELSE 'ctl' END AS cls,
    Precision AS prec,
    Link_Subrole AS subrole,
    COALESCE(Is_Cross_File, FALSE) AS cross_file,
    COALESCE(Is_Enabled, TRUE) AS enabled,
    Step_UUID || '::' || COALESCE(File_Name, '') AS step_id,
    CASE WHEN Flow_Kind = 'result_to_step' AND Pair_Step_UUID IS NOT NULL
         THEN Pair_Step_UUID || '::' || COALESCE(File_Name, '') END AS pair,
    CASE WHEN Flow_Kind = 'step_passes_param' THEN From_UUID || '::' || COALESCE(From_File, '') END AS callsite,
    (Flow_Kind IN ('local_def_use', 'variable_to_step', 'param_to_step', 'result_to_step')
     AND acc.acc_step IS NULL) AS vinc,
    Sql_Resolution AS sql_res,
    Writer_Kind AS wk
  FROM v_dataflow_edges
  LEFT JOIN var_setters acc ON Flow_Kind = 'local_def_use' AND acc.acc_step = To_UUID
                           AND acc.acc_file = To_File AND acc.acc_var = Variable_UUID
  WHERE From_UUID IS NOT NULL AND To_UUID IS NOT NULL
    AND NOT (Flow_Kind = 'step_sets_variable' AND To_UUID IN (SELECT uuid FROM locvar)
             AND To_UUID NOT IN (SELECT uuid FROM start_obj WHERE kind = 'Variable'))
    -- Schritt-Anker: von den Setzern der Startvariable nur die erlaubten
    AND NOT (Flow_Kind = 'step_sets_variable'
             AND To_UUID IN (SELECT uuid FROM start_obj WHERE kind = 'Variable')
             AND (SELECT step FROM start_anchor) IS NOT NULL
             AND From_UUID NOT IN (SELECT uuid FROM start_setters))
  UNION ALL
  SELECT * FROM start_var_edges
),
e AS MATERIALIZED (
  SELECT * FROM e_all
  WHERE enabled AND NOT (kind = 'entry_input' AND f IN (SELECT id FROM prof_tech_lo))
),
-- ── Herkunft: rückwärts ─────────────────────────────────────────────────────
walk_up(node, nk, lastf, writer, dmode, cmode, cs, fl, vl, depth, prev, pkind, lim)
  USING KEY (node, lastf, writer, dmode, cmode, cs, lim) AS (
  SELECT s.id, s.kind, s.id, CAST(NULL AS VARCHAR), FALSE, FALSE, CAST(NULL AS VARCHAR), 0, 0, 0,
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), p.fl_max
  FROM start_node s, params p WHERE p.dir = 'up'
  UNION
  SELECT n.* FROM (
    SELECT
      e.f AS node, e.fk AS nk,
      CASE WHEN w.nk = 'Field' OR w.depth = 0 THEN w.node ELSE w.lastf END AS lastf,
      CASE WHEN w.nk = 'Field' OR w.depth = 0 THEN e.f ELSE w.writer END AS writer,
      CASE WHEN e.fk IN ('Variable', 'ScriptParam', 'ScriptResult') OR e.kind = 'local_def_use' THEN TRUE
           WHEN e.fk = 'Field' THEN FALSE ELSE w.dmode END AS dmode,
      w.cmode OR e.cls = 'flow' AS cmode,
      CASE WHEN p.cc = 1 AND e.kind = 'result_to_step' THEN e.pair
           WHEN e.kind = 'step_passes_param' THEN CAST(NULL AS VARCHAR) ELSE w.cs END AS cs,
      w.fl + CASE WHEN e.fk = 'Field' THEN 1 ELSE 0 END AS fl,
      w.vl + CASE WHEN e.vinc THEN 1 ELSE 0 END AS vl,
      w.depth + 1 AS depth,
      w.node AS prev, e.kind AS pkind,
      -- Grenzfeld eines Wegs aus expand_way: eine Feldebene weiter
      CASE WHEN w.nk = 'Field' AND w.depth > 0 AND w.fl >= w.lim THEN w.fl + 1 ELSE w.lim END AS lim
    FROM walk_up w
    CROSS JOIN params p
    JOIN e ON e.t = w.node
    WHERE (e.cls = 'entry'
           OR (e.cls = 'data' AND NOT w.cmode)
           OR (e.cls = 'flow' AND NOT w.dmode))
      AND NOT (w.nk = 'Field' AND w.depth > 0 AND w.fl >= w.lim
               AND (w.writer IS NULL
                    OR left(md5(w.lastf || '>' || w.writer), 12) NOT IN (SELECT id FROM expand_ids)))
      AND w.node NOT IN (SELECT id FROM excluded)
      AND (w.depth = 0 OR w.node NOT IN (SELECT id FROM prof_stop))
      AND NOT (p.cc = 1 AND e.kind = 'step_passes_param' AND w.cs IS NOT NULL AND e.f <> w.cs)
      AND w.vl + CASE WHEN e.vinc THEN 1 ELSE 0 END <= p.vl_max
      AND w.depth < p.depth_max
      AND (SELECT count(*) FROM recurring.walk_up) < p.state_limit
  ) n
  WHERE NOT EXISTS (
    SELECT 1 FROM recurring.walk_up r
    WHERE r.node = n.node AND r.lastf = n.lastf AND r.writer IS NOT DISTINCT FROM n.writer
      AND r.dmode = n.dmode AND r.cmode = n.cmode AND r.cs IS NOT DISTINCT FROM n.cs AND r.lim = n.lim)
  QUALIFY row_number() OVER (PARTITION BY n.node, n.lastf, n.writer, n.dmode, n.cmode, n.cs, n.lim
                             ORDER BY n.depth, n.fl, n.vl, n.prev, n.pkind) = 1
),
-- ── Verwendung: vorwärts, nur Datenkanten ──────────────────────────────────
walk_down(node, nk, lastf, writer, dmode, cmode, cs, fl, vl, depth, prev, pkind, lim)
  USING KEY (node, lastf, writer, dmode, cmode, cs, lim) AS (
  SELECT s.id, s.kind, s.id, CAST(NULL AS VARCHAR), FALSE, FALSE, CAST(NULL AS VARCHAR), 0, 0, 0,
         CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), p.fl_max
  FROM start_node s, params p WHERE p.dir = 'down'
  UNION
  SELECT n.* FROM (
    SELECT
      e.t AS node, e.tk AS nk,
      CASE WHEN w.nk = 'Field' OR w.depth = 0 THEN w.node ELSE w.lastf END AS lastf,
      CASE WHEN w.nk = 'Field' OR w.depth = 0 THEN e.t ELSE w.writer END AS writer,
      CASE WHEN e.tk IN ('Variable', 'ScriptParam', 'ScriptResult') OR e.kind = 'local_def_use' THEN TRUE
           WHEN e.tk = 'Field' THEN FALSE ELSE w.dmode END AS dmode,
      FALSE AS cmode,
      CASE WHEN p.cc = 1 AND e.kind = 'step_passes_param' THEN e.callsite
           WHEN e.kind = 'result_to_step' THEN CAST(NULL AS VARCHAR) ELSE w.cs END AS cs,
      w.fl + CASE WHEN e.tk = 'Field' THEN 1 ELSE 0 END AS fl,
      w.vl + CASE WHEN e.vinc THEN 1 ELSE 0 END AS vl,
      w.depth + 1 AS depth,
      w.node AS prev, e.kind AS pkind,
      -- Grenzfeld eines Wegs aus expand_way: eine Feldebene weiter
      CASE WHEN w.nk = 'Field' AND w.depth > 0 AND w.fl >= w.lim THEN w.fl + 1 ELSE w.lim END AS lim
    FROM walk_down w
    CROSS JOIN params p
    JOIN e ON e.f = w.node
    WHERE e.cls = 'data'
      AND NOT (w.nk = 'Field' AND w.depth > 0 AND w.fl >= w.lim
               AND (w.writer IS NULL
                    OR left(md5(w.lastf || '>' || w.writer), 12) NOT IN (SELECT id FROM expand_ids)))
      AND w.node NOT IN (SELECT id FROM excluded)
      AND (w.depth = 0 OR w.node NOT IN (SELECT id FROM prof_stop))
      AND NOT (p.cc = 1 AND e.kind = 'result_to_step' AND w.cs IS NOT NULL
               AND e.pair IS DISTINCT FROM w.cs)
      AND w.vl + CASE WHEN e.vinc THEN 1 ELSE 0 END <= p.vl_max
      AND w.depth < p.depth_max
      AND (SELECT count(*) FROM recurring.walk_down) < p.state_limit
  ) n
  WHERE NOT EXISTS (
    SELECT 1 FROM recurring.walk_down r
    WHERE r.node = n.node AND r.lastf = n.lastf AND r.writer IS NOT DISTINCT FROM n.writer
      AND r.dmode = n.dmode AND r.cmode = n.cmode AND r.cs IS NOT DISTINCT FROM n.cs AND r.lim = n.lim)
  QUALIFY row_number() OVER (PARTITION BY n.node, n.lastf, n.writer, n.dmode, n.cmode, n.cs, n.lim
                             ORDER BY n.depth, n.fl, n.vl, n.prev, n.pkind) = 1
),
-- Weg-Schlüssel: Schreibstelle, außer bei Eingabe von Hand — alle editierbaren
-- Feldobjekte eines Felds bilden einen Weg (Layouts in der Einstiegsgruppe).
-- Ein Eingabe-Objekt hat keine Nachfolger im Walk, der Schlüssel betrifft nur
-- seinen eigenen Zustand.
st AS MATERIALIZED (
  SELECT y.*, CASE WHEN y.wkey IS NOT NULL THEN left(md5(y.lastf || '>' || y.wkey), 12) END AS wid
  FROM (
    SELECT x.*,
           CASE WHEN x.writer IS NULL THEN NULL
                WHEN x.node = x.writer AND x.pkind = 'entry_input' THEN 'input'
                ELSE x.writer END AS wkey
    FROM (SELECT * FROM walk_up UNION ALL SELECT * FROM walk_down) x
  ) y
),
dirp AS (SELECT dir FROM params),
-- besuchte Knoten mit kleinster Tiefe/Ebene
visited AS MATERIALIZED (
  SELECT node AS id, any_value(nk) AS nk, min(depth) AS depth, min(fl) AS fl, min(vl) AS vl
  FROM st GROUP BY node
),
-- Kanten zwischen besuchten Knoten, die der Walk gehen darf
walk_edges AS (
  SELECT DISTINCT e.f, e.t, e.kind, e.cls, e.prec, e.subrole, e.cross_file
  FROM e
  JOIN visited a ON a.id = e.f
  JOIN visited b ON b.id = e.t
  WHERE ((SELECT dir FROM dirp) = 'up' AND e.cls IN ('data', 'entry', 'flow'))
     OR ((SELECT dir FROM dirp) = 'down' AND e.cls = 'data')
),
-- Blätter: Steuer-/Guard-Kanten (include_control) und Senken (include_sinks, nur down)
leaf_edges AS (
  SELECT DISTINCT e.f, e.t, e.kind, e.cls, e.prec, e.subrole, e.cross_file,
         CASE WHEN (SELECT dir FROM dirp) = 'up' THEN e.f ELSE e.t END AS leaf,
         CASE WHEN (SELECT dir FROM dirp) = 'up' THEN e.fk ELSE e.tk END AS leaf_kind
  FROM e
  WHERE (e.cls = 'ctl' AND (SELECT inc_ctl FROM params)
         AND (((SELECT dir FROM dirp) = 'up' AND e.t IN (SELECT id FROM visited))
           OR ((SELECT dir FROM dirp) = 'down' AND e.f IN (SELECT id FROM visited))))
     OR (e.cls = 'sink' AND (SELECT inc_sinks FROM params) AND (SELECT dir FROM dirp) = 'down'
         AND e.f IN (SELECT id FROM visited))
),
leaf_nodes AS (
  SELECT l.leaf AS id, any_value(l.leaf_kind) AS nk, any_value(l.cls) AS cls
  FROM leaf_edges l
  WHERE l.leaf NOT IN (SELECT id FROM visited)
  GROUP BY l.leaf
),
-- Knoten-Ranking für den Deckel: Walk-Knoten nach Tiefe, dann Blätter
all_nodes AS (
  SELECT v.id, v.nk, v.depth, v.fl, v.vl, FALSE AS is_leaf, CAST(NULL AS VARCHAR) AS leaf_cls FROM visited v
  UNION ALL
  SELECT l.id, l.nk, NULL, NULL, NULL, TRUE, l.cls FROM leaf_nodes l
),
ranked AS MATERIALIZED (
  SELECT a.*, row_number() OVER (ORDER BY a.is_leaf, a.depth NULLS LAST, a.id) AS rn
  FROM all_nodes a
),
-- ── Wege ────────────────────────────────────────────────────────────────────
way_all AS MATERIALIZED (
  SELECT wid, any_value(lastf) AS lastf,
         CASE WHEN bool_or(wkey = 'input') THEN NULL ELSE any_value(writer) END AS writer,
         bool_or(wkey = 'input') AS is_input,
         min(fl) + 1 AS level
  FROM st WHERE wid IS NOT NULL GROUP BY wid
),
-- Kante zwischen Feld und Schreibstelle (up: writer → Feld, down: Feld → Lesestelle)
way_wedge AS MATERIALIZED (
  SELECT w.wid, min(e.kind) AS wkind, min(e.wk) AS wk,
         bool_or(e.kind IN ('step_writes_field', 'step_writes_dynamic'))
           AND bool_and(e.kind NOT IN ('step_writes_field', 'step_writes_dynamic') OR e.wk = 'reset') AS is_reset
  FROM way_all w JOIN e ON e.f = w.writer AND e.t = w.lastf AND e.cls IN ('data', 'entry')
  WHERE (SELECT dir FROM dirp) = 'up'
  GROUP BY w.wid
  UNION ALL
  SELECT w.wid, min(e.kind), min(e.wk), FALSE
  FROM way_all w JOIN e ON e.f = w.lastf AND e.t = w.writer AND e.cls = 'data'
  WHERE (SELECT dir FROM dirp) = 'down'
  GROUP BY w.wid
  UNION ALL
  SELECT w.wid, 'entry_input', 'input', FALSE FROM way_all w WHERE w.is_input
),
-- je Knoten der beste Zustand (kleinste Tiefe) — gesamt und je Weg
best_node AS MATERIALIZED (
  SELECT node, wid, prev, pkind FROM st
  QUALIFY row_number() OVER (PARTITION BY node ORDER BY depth, wid NULLS FIRST, prev NULLS FIRST, pkind NULLS FIRST) = 1
),
best_seg AS MATERIALIZED (
  SELECT wid, node, prev, pkind FROM st WHERE wid IS NOT NULL
  QUALIFY row_number() OVER (PARTITION BY wid, node ORDER BY depth, prev NULLS FIRST, pkind NULLS FIRST) = 1
),
-- Wege, die gezählt und nummeriert werden (Zurücksetzen nur mit include_reset)
way_cand AS MATERIALIZED (
  SELECT w.*, ww.wkind, ww.wk, COALESCE(ww.is_reset, FALSE) AS is_reset,
         bn.wid AS parent_wid
  FROM way_all w
  LEFT JOIN way_wedge ww ON ww.wid = w.wid
  LEFT JOIN best_node bn ON bn.node = w.lastf
),
-- Einstiege je Weg (up): Zustandskante Einstieg → Ziel mit Art und Ereignis
way_entry_raw AS MATERIALIZED (
  SELECT DISTINCT s.wid, s.node, e.fk,
    CASE e.kind
      WHEN 'entry_input' THEN 'input'
      WHEN 'entry_buttonbar' THEN 'button'
      WHEN 'entry_import' THEN 'import'
      WHEN 'entry_auto_enter' THEN 'auto_enter'
      ELSE CASE WHEN e.subrole = 'button_action' THEN 'button'
                WHEN e.subrole = 'menu_action' THEN 'menu'
                WHEN e.fk = 'File' THEN 'file'
                ELSE 'trigger' END
    END AS gkind,
    CASE WHEN e.kind IN ('entry_import', 'entry_auto_enter') THEN e.subrole
         WHEN e.kind = 'triggers_script' AND e.subrole NOT IN ('button_action', 'menu_action') THEN e.subrole
    END AS event
  FROM st s
  JOIN e ON e.f = s.node AND e.t = s.prev AND e.kind = s.pkind
  WHERE s.wid IS NOT NULL AND e.cls = 'entry' AND (SELECT dir FROM dirp) = 'up'
),
entry_layout AS MATERIALIZED (
  SELECT r.node, l.L_UUID AS luuid, l.L_Name AS lname, l.File_Name AS lfile
  FROM (SELECT DISTINCT node, fk FROM way_entry_raw) r
  JOIN LayoutObjects lo ON r.fk = 'LayoutObject'
   AND lo.Object_UUID = split_part(r.node, '::', 1)
   AND lo.File_Name = substr(r.node, length(split_part(r.node, '::', 1)) + 3)
  JOIN Layouts l ON l.L_ID = lo.Layout_ID AND l.File_Name = lo.File_Name
  UNION
  SELECT r.node, l.L_UUID, l.L_Name, l.File_Name
  FROM (SELECT DISTINCT node, fk FROM way_entry_raw) r
  JOIN Layouts l ON r.fk = 'Layout'
   AND l.L_UUID = split_part(r.node, '::', 1)
   AND l.File_Name = substr(r.node, length(split_part(r.node, '::', 1)) + 3)
),
-- Zurücksetzen: Schreibstellen, die nur "" schreiben, bilden keinen Weg
way_num AS MATERIALIZED (
  SELECT c.*, COALESCE(ne.n, 0) AS n_entries
  FROM way_cand c
  LEFT JOIN (SELECT wid, count(DISTINCT node) AS n FROM way_entry_raw GROUP BY wid) ne ON ne.wid = c.wid
  WHERE NOT c.is_reset OR (SELECT inc_reset FROM params)
),
-- ── Wirkungsliste (down) ────────────────────────────────────────────────────
usage_all AS MATERIALIZED (
  SELECT CASE e.kind
           WHEN 'sink_display' THEN 'display' WHEN 'sink_sort' THEN 'sort'
           WHEN 'sink_export' THEN 'export' WHEN 'sink_find' THEN 'find'
           WHEN 'sink_navigate' THEN 'navigate' WHEN 'sink_relationship' THEN 'relationship'
           WHEN 'sink_valuelist' THEN 'valuelist' ELSE 'other' END AS gkind,
         e.f AS src, e.t AS target, e.tk AS tk
  FROM e JOIN visited v ON v.id = e.f
  WHERE e.cls = 'sink' AND (SELECT dir FROM dirp) = 'down'
  UNION
  SELECT CASE WHEN s.pkind IN ('step_writes_field', 'step_writes_dynamic') THEN 'writes' ELSE 'calc' END,
         s.prev, s.node, 'Field'
  FROM st s
  WHERE (SELECT dir FROM dirp) = 'down' AND s.nk = 'Field' AND s.depth > 0
  UNION
  -- Infrastruktur-Scripts (Profil): Sammelsenke mit dem Script als Ziel
  SELECT 'infrastructure', s.prev,
         split_part(split_part(s.node, '::', 1), '#', 1) || substr(s.node, length(split_part(s.node, '::', 1)) + 1),
         'Script'
  FROM st s JOIN prof_stop ps ON ps.id = s.node AND ps.kind = 'boundary_script'
  WHERE (SELECT dir FROM dirp) = 'down'
),
usage_sample AS MATERIALIZED (
  SELECT gkind, target, tk FROM (SELECT DISTINCT gkind, target, tk FROM usage_all)
  QUALIFY row_number() OVER (PARTITION BY gkind ORDER BY target) <= 3
),
-- ── Beschriftung ────────────────────────────────────────────────────────────
need_ids AS (
  SELECT lastf AS id FROM way_all
  UNION SELECT writer FROM way_all WHERE writer IS NOT NULL
  UNION SELECT node FROM way_entry_raw
  UNION SELECT node FROM st WHERE nk = 'Field'
  UNION SELECT node FROM st WHERE (SELECT labels_all FROM params)
),
label_ids AS MATERIALIZED (
  SELECT r.id, r.nk, r.depth, r.fl, r.vl, r.is_leaf, r.leaf_cls, r.rn
  FROM ranked r
  WHERE r.rn <= (SELECT node_limit FROM params) OR r.id IN (SELECT id FROM need_ids)
  UNION ALL
  SELECT DISTINCT u.target, u.tk, NULL, NULL, NULL, TRUE, 'sink', NULL
  FROM usage_sample u WHERE u.target NOT IN (SELECT id FROM ranked)
),
label_parts AS (
  SELECT k.*,
         split_part(k.id, '::', 1) AS uuid,
         substr(k.id, length(split_part(k.id, '::', 1)) + 3) AS file,
         CASE WHEN contains(split_part(k.id, '::', 1), '#')
              THEN split_part(split_part(k.id, '::', 1), '#', 1) END AS owner_uuid
  FROM label_ids k
),
-- Beschriftung: Katalogobjekt; Schritt = Script #n Schritt; Pseudoknoten über den Eigentümer
step_lbl AS (
  SELECT s.Step_UUID, s.File_Name, s.Script_UUID, s.Step_Index, s.Step_ID,
         sc.Script_Name || ' #' || CAST(s.Step_Index + 1 AS VARCHAR) || ' ' || s.Step_Name AS lbl
  FROM StepsForScripts s
  JOIN ScriptCatalog sc ON sc.Script_UUID = s.Script_UUID AND sc.File_Name = s.File_Name
  WHERE (s.Step_UUID, s.File_Name) IN (
    SELECT COALESCE(owner_uuid, uuid), file FROM label_parts)
),
node_rows AS MATERIALIZED (
  SELECT
    k.id, k.uuid, NULLIF(k.file, '') AS file, k.nk AS type,
    COALESCE(sl.lbl, oc.Object_Name, osl.lbl, oo.Object_Name, k.uuid) AS label,
    k.owner_uuid,
    CASE WHEN k.owner_uuid IS NOT NULL THEN COALESCE(oo.Object_Type, CASE WHEN osl.lbl IS NOT NULL THEN 'ScriptStep' END) END AS owner_type,
    k.depth, k.fl, k.vl, k.is_leaf, k.rn,
    CASE WHEN k.id IN (SELECT id FROM start_node) THEN 'start'
         WHEN k.is_leaf AND k.leaf_cls = 'sink' THEN 'sink'
         WHEN k.is_leaf THEN 'control'
         WHEN k.nk = 'Field' THEN 'field'
         WHEN k.nk = 'ScriptStep' THEN 'step'
         WHEN k.nk = 'Variable' THEN 'variable'
         WHEN k.nk = 'ScriptParam' THEN 'param'
         WHEN k.nk = 'ScriptResult' THEN 'result'
         WHEN k.nk = 'Calculation' THEN 'calc'
         WHEN k.nk = 'Script' THEN 'control'
         WHEN k.nk IN ('DynamicTarget', 'Uninitialized') THEN 'blind'
         ELSE 'entry' END AS flow_role,
    k.id IN (SELECT id FROM excluded) AS is_excluded,
    k.id IN (SELECT id FROM start_node) AS is_focus,
    sl.Step_Index AS step_index, sl.Step_ID AS step_id, sl.Script_UUID AS script_uuid,
    (SELECT min(ps.kind) FROM prof_stop ps WHERE ps.id = k.id) AS profile_stop
  FROM label_parts k
  LEFT JOIN step_lbl sl ON k.nk = 'ScriptStep' AND sl.Step_UUID = k.uuid AND sl.File_Name = k.file
  LEFT JOIN step_lbl osl ON k.owner_uuid IS NOT NULL AND osl.Step_UUID = k.owner_uuid AND osl.File_Name = k.file
  LEFT JOIN ObjectCatalog oc ON k.owner_uuid IS NULL AND k.nk <> 'ScriptStep'
                            AND oc.Object_UUID = k.uuid AND oc.File_Name = k.file
  LEFT JOIN ObjectCatalog oo ON k.owner_uuid IS NOT NULL AND oo.Object_UUID = k.owner_uuid AND oo.File_Name = k.file
                            AND oo.Object_Type <> 'ScriptStep'
  QUALIFY row_number() OVER (PARTITION BY k.id ORDER BY oc.Object_Type NULLS LAST, oo.Object_Type NULLS LAST) = 1
),
kept AS MATERIALIZED (
  SELECT id FROM node_rows WHERE rn <= (SELECT node_limit FROM params)
),
-- ── Wege nummerieren, Pfade, Präzision ──────────────────────────────────────
way_sorted AS MATERIALIZED (
  SELECT w.*, row_number() OVER (
           ORDER BY w.level, fl.label, w.lastf, wr.label, w.writer, w.wid) AS way_no
  FROM way_num w
  LEFT JOIN node_rows fl ON fl.id = w.lastf
  LEFT JOIN node_rows wr ON wr.id = w.writer
),
way_out AS MATERIALIZED (
  SELECT * FROM way_sorted WHERE way_no <= (SELECT ways_limit FROM params)
),
-- Zustandskanten der Wege (Datenfluss-Richtung)
seg_edges AS MATERIALIZED (
  SELECT DISTINCT s.wid,
    CASE WHEN (SELECT dir FROM dirp) = 'up' THEN s.node ELSE s.prev END AS f,
    CASE WHEN (SELECT dir FROM dirp) = 'up' THEN s.prev ELSE s.node END AS t,
    s.pkind AS kind
  FROM best_seg s
  WHERE s.prev IS NOT NULL AND s.wid IN (SELECT wid FROM way_out)
),
-- Vorgängerkette vom Feld des Wegs zurück zum Start (Ebene > 1)
anc(way, wid, node, prev, kind, n) AS (
  SELECT w.wid, bn.wid, w.lastf, bn.prev, bn.pkind, 0
  FROM way_out w JOIN best_node bn ON bn.node = w.lastf
  WHERE bn.prev IS NOT NULL
  UNION
  SELECT a.way, nx.wid, a.prev, nx.prev, nx.pkind, a.n + 1
  FROM anc a
  JOIN way_all wa ON wa.wid = a.wid
  LEFT JOIN best_node pb ON a.prev = wa.lastf AND pb.node = a.prev
  JOIN best_seg nx ON nx.wid = CASE WHEN a.prev = wa.lastf THEN pb.wid ELSE a.wid END
                  AND nx.node = a.prev
  WHERE nx.prev IS NOT NULL AND a.n < (SELECT depth_max FROM params)
),
path_edges AS MATERIALIZED (
  SELECT wid, f, t, kind FROM seg_edges
  UNION
  SELECT a.way,
    CASE WHEN (SELECT dir FROM dirp) = 'up' THEN a.node ELSE a.prev END,
    CASE WHEN (SELECT dir FROM dirp) = 'up' THEN a.prev ELSE a.node END,
    a.kind
  FROM anc a
),
path_nodes AS MATERIALIZED (
  SELECT wid, f AS id FROM path_edges UNION SELECT wid, t FROM path_edges
  UNION SELECT wid, lastf FROM way_out
),
path_prec AS (
  SELECT p.wid,
    max(CASE x.prec WHEN 'dynamic' THEN 3 WHEN 'approx' THEN 2 ELSE 1 END) AS pr
  FROM path_edges p JOIN e x ON x.f = p.f AND x.t = p.t AND x.kind = p.kind
  GROUP BY p.wid
),
-- Felder im Weg (up: Quellfelder, down: erreichte Felder) mit der Kante, über
-- die der Walk sie erreicht hat
way_field_flat AS MATERIALIZED (
  SELECT s.wid, s.node AS id, s.pkind AS via
  FROM best_seg s
  JOIN visited v ON v.id = s.node AND v.nk = 'Field'
  JOIN way_out o ON o.wid = s.wid AND o.lastf <> s.node
),
way_fields AS (
  SELECT wid, list({ 'id': id, 'via': via } ORDER BY id) AS fields
  FROM way_field_flat GROUP BY wid
),
-- Einstiegsgruppen je Weg
entry_grp AS (
  SELECT r.wid, r.gkind, r.event, count(DISTINCT r.node) AS n,
         count(DISTINCT el.luuid || '::' || el.lfile) AS n_layouts
  FROM way_entry_raw r LEFT JOIN entry_layout el ON el.node = r.node
  WHERE r.wid IN (SELECT wid FROM way_out)
  GROUP BY ALL
),
entry_grp_layouts AS (
  SELECT wid, gkind, event, list({ 'uuid': luuid, 'name': lname, 'file': lfile } ORDER BY lname, lfile, luuid) AS layouts
  FROM (
    SELECT * FROM (
      SELECT DISTINCT r.wid, r.gkind, r.event, el.luuid, el.lname, el.lfile
      FROM way_entry_raw r JOIN entry_layout el ON el.node = r.node
      WHERE r.wid IN (SELECT wid FROM way_out)
    )
    QUALIFY row_number() OVER (PARTITION BY wid, gkind, event ORDER BY lname, lfile, luuid) <= 10
  )
  GROUP BY ALL
),
entry_grp_sample AS (
  SELECT wid, gkind, event, list(node ORDER BY node) AS sample
  FROM (
    SELECT * FROM (
      SELECT DISTINCT r.wid, r.gkind, r.event, r.node FROM way_entry_raw r
      WHERE r.wid IN (SELECT wid FROM way_out)
    )
    QUALIFY row_number() OVER (PARTITION BY wid, gkind, event ORDER BY node) <= 3
  )
  GROUP BY ALL
),
way_groups AS (
  SELECT g.wid,
         list({ 'kind': g.gkind, 'event': g.event, 'n': g.n, 'nLayouts': g.n_layouts,
                'layouts': COALESCE(l.layouts, []), 'sample': COALESCE(sm.sample, []) }
              ORDER BY g.gkind, g.event NULLS FIRST) AS groups
  FROM entry_grp g
  LEFT JOIN entry_grp_layouts l ON l.wid = g.wid AND l.gkind = g.gkind AND l.event IS NOT DISTINCT FROM g.event
  LEFT JOIN entry_grp_sample sm ON sm.wid = g.wid AND sm.gkind = g.gkind AND sm.event IS NOT DISTINCT FROM g.event
  GROUP BY g.wid
),
way_paths AS (
  SELECT pe.wid,
         list({ 'source': pe.f, 'target': pe.t, 'kind': pe.kind } ORDER BY pe.f, pe.kind, pe.t) AS edges
  FROM path_edges pe GROUP BY pe.wid
),
way_pnodes AS (
  SELECT wid, list(id ORDER BY id) AS nodes FROM path_nodes GROUP BY wid
),
way_rows AS (
  SELECT w.way_no, w.wid,
    CAST(to_json({
      'wayNo': w.way_no, 'wayId': w.wid, 'level': w.level,
      'field': w.lastf, 'writer': w.writer,
      'writerFlowKind': w.wkind, 'writerKind': w.wk, 'isReset': w.is_reset,
      'parentWayId': w.parent_wid,
      'precision': CASE pp.pr WHEN 3 THEN 'dynamic' WHEN 2 THEN 'approx' ELSE 'exact' END,
      'nEntries': w.n_entries,
      'entryGroups': COALESCE(g.groups, []),
      'fields': COALESCE(f.fields, []),
      'pathNodes': COALESCE(pn.nodes, []),
      'pathEdges': COALESCE(wp.edges, [])
    }) AS VARCHAR) AS payload
  FROM way_out w
  LEFT JOIN path_prec pp ON pp.wid = w.wid
  LEFT JOIN way_groups g ON g.wid = w.wid
  LEFT JOIN way_fields f ON f.wid = w.wid
  LEFT JOIN way_pnodes pn ON pn.wid = w.wid
  LEFT JOIN way_paths wp ON wp.wid = w.wid
),
-- Gruppe „Zurücksetzen“ (up, ohne include_reset)
reset_row AS (
  SELECT CAST(to_json({
      'n': count(*),
      'ways': list({ 'wayId': c.wid, 'level': c.level, 'field': c.lastf, 'writer': c.writer }
                   ORDER BY c.level, c.lastf, c.writer)
    }) AS VARCHAR) AS payload
  FROM way_cand c
  WHERE c.is_reset AND NOT (SELECT inc_reset FROM params) AND (SELECT dir FROM dirp) = 'up'
  HAVING count(*) > 0
),
usage_rows AS (
  SELECT u.gkind,
    CAST(to_json({
      'kind': u.gkind, 'n': count(DISTINCT u.target), 'nSources': count(DISTINCT u.src),
      'sample': (SELECT list(x.target ORDER BY x.target) FROM usage_sample x WHERE x.gkind = u.gkind)
    }) AS VARCHAR) AS payload
  FROM usage_all u GROUP BY u.gkind
),
-- Weg 0: Feld → Feld (Datenfluss-Richtung) über die ausgegebenen Wege
overview_row AS (
  SELECT CAST(to_json({
      'fields': (SELECT list(x ORDER BY x) FROM (
                   SELECT lastf AS x FROM way_out UNION SELECT id FROM way_field_flat)),
      'links': (SELECT list({ 'source': CASE WHEN (SELECT dir FROM dirp) = 'up' THEN fl.id ELSE o.lastf END,
                              'target': CASE WHEN (SELECT dir FROM dirp) = 'up' THEN o.lastf ELSE fl.id END,
                              'wayId': o.wid, 'wayNo': o.way_no }
                            ORDER BY o.way_no, fl.id)
                FROM way_out o JOIN way_field_flat fl ON fl.wid = o.wid)
    }) AS VARCHAR) AS payload
),
-- Knoten außerhalb von node_limit, die die Ausgabe nennt (nur Beschriftung)
ref_ids AS (
  SELECT lastf AS id FROM way_out
  UNION SELECT writer FROM way_out
  UNION SELECT id FROM way_field_flat
  UNION SELECT unnest(sample) FROM entry_grp_sample
  UNION SELECT target FROM usage_sample
  UNION SELECT lastf FROM way_cand WHERE is_reset
  UNION SELECT writer FROM way_cand WHERE is_reset
  UNION SELECT id FROM path_nodes WHERE (SELECT labels_all FROM params)
),
edge_rows AS (
  SELECT f, t, kind, cls, prec, subrole, cross_file FROM walk_edges
  UNION
  SELECT f, t, kind, cls, prec, subrole, cross_file FROM leaf_edges
),
edges_kept AS (
  SELECT r.* FROM edge_rows r
  WHERE r.f IN (SELECT id FROM kept) AND r.t IN (SELECT id FROM kept)
),
-- ── Kennzahlen, Kürzungen, blinde Stellen ──────────────────────────────────
-- Feld auf der Grenzebene mit weiteren Kanten → Kürzung durch field_levels
cut_fl AS (
  SELECT count(DISTINCT s.node) AS n FROM st s, params p
  WHERE s.nk = 'Field' AND s.depth > 0 AND s.fl >= s.lim
    AND EXISTS (SELECT 1 FROM e WHERE (p.dir = 'up' AND e.t = s.node AND e.cls IN ('data', 'entry'))
                                   OR (p.dir = 'down' AND e.f = s.node AND e.cls = 'data'))
),
cut_vl AS (
  SELECT count(*) AS n FROM st s CROSS JOIN params p
  JOIN e ON (p.dir = 'up' AND e.t = s.node) OR (p.dir = 'down' AND e.f = s.node)
  WHERE e.vinc AND s.vl >= p.vl_max AND e.cls = 'data'
),
cut_depth AS (
  SELECT count(*) AS n FROM st s, params p WHERE s.depth >= p.depth_max
),
-- deaktivierte Schritte an besuchten Knoten
disabled AS (
  SELECT count(DISTINCT x.step_id) AS n FROM e_all x, params p
  WHERE NOT x.enabled
    AND ((p.dir = 'up' AND x.t IN (SELECT id FROM visited)) OR (p.dir = 'down' AND x.f IN (SELECT id FROM visited)))
),
-- Scripts der besuchten Schritte (für blinde Stellen im Script)
visited_scripts AS (
  SELECT DISTINCT s.Script_UUID, s.File_Name
  FROM visited v
  JOIN StepsForScripts s ON v.nk = 'ScriptStep'
   AND s.Step_UUID = split_part(v.id, '::', 1) AND s.File_Name = substr(v.id, length(split_part(v.id, '::', 1)) + 3)
),
blind AS (
  SELECT
    (SELECT count(*) FROM visited WHERE nk = 'Uninitialized') AS uninitialized,
    (SELECT count(DISTINCT d.Step_UUID) FROM v_dataflow_edges d JOIN visited_scripts vs
       ON vs.Script_UUID = d.Script_UUID AND vs.File_Name = d.File_Name
     WHERE d.Flow_Kind = 'step_writes_dynamic' AND COALESCE(d.Is_Enabled, TRUE)) AS dynamic_writes,
    (SELECT count(DISTINCT sc.Step_UUID) FROM StepCalculations sc JOIN visited_scripts vs
       ON vs.Script_UUID = sc.Script_UUID AND vs.File_Name = sc.File_Name
     WHERE sc.Step_ID IN (1, 164, 210) AND sc.Slot = 'List') AS dynamic_calls,
    (SELECT count(*) FROM walk_edges WHERE prec = 'approx') AS approx_edges,
    (SELECT count(DISTINCT e.step_id) FROM e JOIN visited v ON v.id = e.t
     WHERE e.sql_res = 'dynamic') AS dynamic_sql
),
context_open AS (
  SELECT count(*) AS n FROM st s, params p
  WHERE p.cc = 1 AND s.cs IS NULL
    AND ((p.dir = 'up' AND s.pkind = 'step_passes_param') OR (p.dir = 'down' AND s.pkind = 'result_to_step'))
),
stats_row AS (
  SELECT CAST(to_json({
    'states': (SELECT count(*) FROM st),
    'total_reachable': (SELECT count(*) FROM all_nodes),
    'cut_field_levels': (SELECT n FROM cut_fl),
    'cut_var_levels': (SELECT n FROM cut_vl),
    'cut_step_limit': (SELECT n FROM cut_depth),
    'cut_state_limit': (SELECT count(*) FROM st) >= (SELECT state_limit FROM params),
    'disabled_steps': (SELECT n FROM disabled),
    'context_open': (SELECT n FROM context_open),
    'blind_uninitialized': b.uninitialized,
    'blind_dynamic_writes': b.dynamic_writes,
    'blind_dynamic_calls': b.dynamic_calls,
    'blind_dynamic_sql': b.dynamic_sql,
    'approx_edges': b.approx_edges,
    'max_field_level': (SELECT max(fl) FROM st),
    'max_var_level': (SELECT max(vl) FROM st),
    'max_depth': (SELECT max(depth) FROM st),
    'ways_total': (SELECT count(*) FROM way_num),
    'reset_ways': (SELECT count(*) FROM way_cand WHERE is_reset),
    'entries': (SELECT count(DISTINCT node) FROM way_entry_raw),
    'reached_fields': (SELECT count(DISTINCT node) FROM st WHERE nk = 'Field' AND depth > 0),
    'profile_applied': {
      -- Eingabe-Einstiege auf technischen Layouts, die das Profil ausblendet (up)
      'technical_layout': (SELECT count(DISTINCT x.f) FROM e_all x
                           WHERE x.enabled AND x.kind = 'entry_input' AND (SELECT dir FROM dirp) = 'up'
                             AND x.f IN (SELECT id FROM prof_tech_lo)
                             AND x.t IN (SELECT node FROM st WHERE nk = 'Field' AND (depth = 0 OR fl < lim))),
      'boundary_script': (SELECT count(DISTINCT split_part(split_part(v.id, '::', 1), '#', 1) || substr(v.id, length(split_part(v.id, '::', 1)) + 1))
                          FROM visited v JOIN prof_stop ps ON ps.id = v.id AND ps.kind = 'boundary_script'),
      'ui_state_variable': (SELECT count(*) FROM visited v JOIN prof_stop ps ON ps.id = v.id AND ps.kind = 'ui_state_variable'),
      'hub_variable': (SELECT count(*) FROM visited v JOIN prof_stop ps ON ps.id = v.id AND ps.kind = 'hub_variable'),
      -- Leser der erreichten Hub-Variablen (nur Zähler)
      'hub_readers': (SELECT count(DISTINCT x.t) FROM e x
                      WHERE x.kind = 'variable_to_step'
                        AND x.f IN (SELECT v.id FROM visited v JOIN prof_stop ps ON ps.id = v.id AND ps.kind = 'hub_variable'))
    }
  }) AS VARCHAR) AS payload
  FROM blind b
)
SELECT
  CASE WHEN n.rn IS NOT NULL AND n.rn <= (SELECT node_limit FROM params) THEN 'node' ELSE 'ref' END AS row_kind,
  n.id, n.uuid, n.label, n.type, n.file, n.owner_uuid, n.owner_type,
  n.depth, n.fl AS field_level, n.vl AS var_level, n.is_leaf, n.flow_role, n.is_excluded, n.is_focus,
  n.step_index, n.step_id, n.script_uuid,
  CAST(NULL AS VARCHAR) AS source, CAST(NULL AS VARCHAR) AS target, CAST(NULL AS VARCHAR) AS flow_kind,
  CAST(NULL AS VARCHAR) AS flow_class, CAST(NULL AS VARCHAR) AS precision, CAST(NULL AS VARCHAR) AS subrole,
  CAST(NULL AS BOOLEAN) AS cross_file, n.rn AS ord, CAST(NULL AS VARCHAR) AS payload, n.profile_stop
FROM node_rows n
WHERE (n.rn IS NOT NULL AND n.rn <= (SELECT node_limit FROM params)) OR n.id IN (SELECT id FROM ref_ids)
UNION ALL
SELECT
  'edge',
  r.f || '|' || r.kind || '|' || r.t, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  NULL, NULL, NULL,
  -- nach außen die Katalogklasse: Ablauf- und Steuerkanten sind beide control
  r.f, r.t, r.kind, CASE WHEN r.cls IN ('flow', 'ctl') THEN 'control' ELSE r.cls END, r.prec, r.subrole, r.cross_file,
  NULL, NULL, NULL
FROM edges_kept r
UNION ALL
SELECT 'way', w.wid, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, w.way_no, w.payload, NULL
FROM way_rows w
UNION ALL
SELECT 'reset', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, payload, NULL
FROM reset_row
UNION ALL
SELECT 'usage', u.gkind, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, u.payload, NULL
FROM usage_rows u
UNION ALL
SELECT 'overview', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, payload, NULL
FROM overview_row
UNION ALL
SELECT 'stats', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, payload, NULL
FROM stats_row
ORDER BY row_kind, ord, id;
