-- @template_type: report
-- @title: Graph Depth Profile (Eccentricity + per-depth node counts)
-- @description: Max. erreichbare Tiefe ab dem Fokus + Knotenzahl je Tiefe — richtungsabhängig, ungedeckelt bis hard_cap
-- @params: focus (required, UUID), focus_file, direction, mode, include_builtins, roles, types, hard_cap
-- @version: 1.6.0
-- @author: Marcel / Claude
-- @tags: graph, explorer, depth
-- @note: Endpoint /api/graph/depth-profile. Spiegelt die CTEs 1–7 von graph_subgraph.sql
--        SPEZIALTYPEN (geerbt aus LogicalLinks 1.5.0, gespiegelt aus
--        graph_subgraph.sql — KEINE Logik-Änderung in diesem Template):
--        Chart/Web Viewer bleiben un-gehoistet, am Layout-Fokus rücken ihre
--        Felder/Variablen von d1 auf d2 (Kette über die operationale
--        parent_layout-Kante) und der Objekt-Knoten kommt auf d1 hinzu. Die
--        Tiefen-Verschiebung ist gewollt — sie muss mit graph_subgraph.sql
--        kumulativ deckungsgleich bleiben (Zähl-Konsistenz des Tiefen-Sliders).
--        1.6.0 (Anker-Durchgriff, gespiegelt aus graph_subgraph.sql v1.9.0):
--        synthetische Walk-Kante Fokus → Trigger-Ziele des Anker-Felds
--        (nur out/both) — hält die Tiefen-Slider-Zählung konsistent.
--        1.5.0 (gespiegelt aus graph_subgraph.sql v1.8.0): Selbst-Enklave ohne
--        triggers_script bei feld-gebundenem Fokus (das Feld ist der Sprecher).
--        1.4.0 (Fokus-Selbst-Enklave, gespiegelt aus graph_subgraph.sql v1.7.0):
--        alle rohen operationalen Kanten des Fokus; subsumiert die Sonderzweige
--        trigger_script + Feld-Kandidaten (Whitelist bereinigt, Richtungs-
--        Unabhängigkeit in der edges-CTE bleibt).
--        1.3.0 (Owner-Enklave, gespiegelt aus graph_subgraph.sql v1.6.0): rohe
--        operationale Kanten des Trigger-Owners (triggers_script ausgeschlossen) —
--        hält die Tiefen-Slider-Zählung konsistent zum Subgraph.
--        1.2.0 (Trigger-Fokus-Flanke, gespiegelt aus graph_subgraph.sql v1.5.0):
--        Fokus-Brücke reicht die `trigger_script`-Kante + OnWindowTransaction-Feld-
--        Kandidaten des Fokus-Triggers aus raw_links durch — LogicalLinks führt
--        beide seit der Graph-Policy von Converter 2.17.0 nicht mehr.
--        1.1.0: Fokus-Ausnahme im Typ-Filter (reached_f) — gespiegelt aus
--        graph_subgraph.sql v1.3.0, hält die kumulative Last konsistent mit total_reachable.
--        (Reuse des Walks), ERSETZT aber den Tiefen-Deckel `depth` durch `hard_cap`
--        (Runaway-Schutz) und aggregiert auf depth → COUNT(*). KEINE Knoten-Projektion/
--        Community-Anreicherung (leichtgewichtig). `reached` nutzt MIN(depth) je Knoten =
--        kürzester Pfad ⇒ MAX(depth) = Exzentrizität, COUNT je depth = Knoten dieser Distanz.
--        Richtung über den `direction`-Zweig der edges-CTE: out|in|both.
-- ============================================================================

WITH RECURSIVE
-- 1) Roh-Kanten mit Waisen-Filter (beide Endpunkte katalogisiert). Datei mitführen.
raw_links AS (
  SELECT
    Source_UUID AS a, Source_File AS a_file,
    Target_UUID AS b, Target_File AS b_file,
    Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM ObjectLinks
  WHERE Source_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
    AND Target_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
),
-- 2) Logische Sicht (Sub-Objekte auf Container hochgezogen) aus der P5-View.
logical_dedup AS (
  SELECT
    Source_UUID AS a, Source_File AS a_file,
    Target_UUID AS b, Target_File AS b_file,
    Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM LogicalLinks
),
-- 3) Aktive Basis nach mode (ein Zweig wird nach Interpolation gekappt).
base AS (
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM logical_dedup
  WHERE getvariable('mode') = 'logical'
  UNION ALL
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM raw_links
  WHERE getvariable('mode') = 'logical'
    AND a = getvariable('focus')
    AND Link_Role IN ('parent_layout', 'parent_script', 'trigger_owner')
  UNION ALL
  -- Fokus-Selbst-Enklave (gespiegelt aus graph_subgraph.sql 1.7.0): alle rohen
  -- operationalen Kanten des Fokus; Duplikate der logischen Basis falten weg.
  -- Ausnahme (1.5.0): triggers_script eines feld-gebundenen Fokus — das Feld spricht.
  SELECT rl.a, rl.a_file, rl.b, rl.b_file, rl.Link_Role, rl.Link_Subrole, rl.Link_Type, rl.Is_Cross_File
  FROM raw_links rl
  WHERE getvariable('mode') = 'logical'
    AND rl.a = getvariable('focus')
    AND rl.Link_Type = 'operational'
    AND NOT (rl.Link_Role = 'triggers_script'
             AND EXISTS (SELECT 1 FROM ObjectLinks fx
                         WHERE fx.Source_UUID = rl.a
                           AND fx.Source_File = rl.a_file
                           AND fx.Link_Role = 'displays_field'))
  UNION ALL
  -- Owner-Enklave (gespiegelt aus graph_subgraph.sql 1.6.0): rohe operationale
  -- Kanten des Owners des Fokus-Triggers, datei-genauer Tupel-Join;
  -- triggers_script ausgeschlossen.
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM raw_links
  WHERE getvariable('mode') = 'logical'
    AND (a, a_file) IN (SELECT b, b_file FROM raw_links
                        WHERE a = getvariable('focus')
                          AND Link_Role = 'trigger_owner')
    AND Link_Type = 'operational'
    AND Link_Role <> 'triggers_script'
  UNION ALL
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM raw_links
  WHERE getvariable('mode') = 'raw'
),
-- 4) Kanten-Filter: Builtins + optionale Rollen-Whitelist (Ziel-Typ datei-genau).
base_f AS (
  SELECT base.a, base.a_file, base.b, base.b_file, base.Link_Role, base.Link_Subrole,
         base.Link_Type, base.Is_Cross_File
  FROM base
  JOIN ObjectCatalog tc
    ON tc.Object_UUID = base.b
   AND tc.File_Name IS NOT DISTINCT FROM base.b_file
  WHERE (getvariable('include_builtins') = TRUE OR tc.Object_Type <> 'BuiltinFunction')
    AND (getvariable('roles') IS NULL
         OR base.Link_Role IN (SELECT unnest(string_split(CAST(getvariable('roles') AS VARCHAR), ','))))
),
-- 5) Gerichtete Kantenmenge (direction): out|in|both, in-Zweig symmetrisch getauscht.
edges AS (
  SELECT a, a_file, b, b_file FROM base_f WHERE getvariable('direction') IN ('out', 'both')
  UNION
  SELECT b AS a, b_file AS a_file, a AS b, a_file AS b_file FROM base_f WHERE getvariable('direction') IN ('in', 'both')
  UNION
  SELECT a, a_file, b, b_file FROM base_f
  WHERE getvariable('mode') = 'logical'
    AND a = getvariable('focus')
    -- Trigger-Fokus-Flanke: trigger_script + Feld-Kandidaten (operational) kommen
    -- in base nur als Brücken-Zweig vor und bleiben wie die strukturellen
    -- Parent-Kanten richtungsunabhängig.
    AND (Link_Type = 'structural' OR Link_Role = 'trigger_script'
         OR (Link_Role = 'reads_field'
             AND Link_Subrole = 'transaction_parameter_field'))
  UNION
  -- Anker-Durchgriff (gespiegelt aus graph_subgraph.sql 1.9.0): synthetische
  -- Walk-Kante Fokus → Trigger-Ziele des Anker-Felds (df roh = nur
  -- LayoutObject-Quellen; ts gefiltert).
  SELECT df.a, df.a_file, ts.b, ts.b_file
  FROM raw_links df
  JOIN base_f ts
    ON ts.a = df.b AND ts.a_file IS NOT DISTINCT FROM df.b_file
   AND ts.Link_Role = 'triggers_script'
  WHERE getvariable('mode') = 'logical'
    AND getvariable('direction') IN ('out', 'both')
    AND df.a = getvariable('focus')
    AND df.Link_Role = 'displays_field'
),
-- 6) Fokus-Saat (UUID, File) — focus_file durchgereicht, sonst Katalog-Auflösung.
focus_seed AS (
  SELECT
    getvariable('focus') AS uuid,
    COALESCE(
      NULLIF(CAST(getvariable('focus_file') AS VARCHAR), ''),
      (SELECT File_Name FROM ObjectCatalog WHERE Object_UUID = getvariable('focus') LIMIT 1)
    ) AS file
),
-- 7) Rekursiver Walk — UNGEDECKELT bis hard_cap (Runaway-Schutz). UNION ⇒ Zyklen-Dedup.
walk AS (
  SELECT uuid, file, 0 AS depth FROM focus_seed
  UNION
  SELECT e.b, e.b_file, w.depth + 1
  FROM walk w
  JOIN edges e
    ON e.a = w.uuid
   AND e.a_file IS NOT DISTINCT FROM w.file
  WHERE w.depth < CAST(getvariable('hard_cap') AS INT)
),
reached AS (
  SELECT uuid, file, MIN(depth) AS depth FROM walk GROUP BY uuid, file
),
-- 8) Typ-Filter — SPIEGELT graph_subgraph.sql (dort `nodes_ranked`): der Walk läuft
--    ungefiltert (Knoten anderer Typen bleiben Brücken), nur die GEZÄHLTE Knotenmenge
--    wird auf die gewählten Object_Type beschränkt. So matcht die kumulative Last je
--    Tiefe exakt `total_reachable` des Subgraphen (sonst zählt das Profil alle Typen).
--    FOKUS-AUSNAHME (spiegelt graph_subgraph.sql v1.3.0): der Fokus zählt bei depth 0
--    IMMER mit, auch wenn sein eigener Object_Type abgewählt ist — sonst driftet die
--    kumulative Last gegen `total_reachable` des Subgraphen (der den Fokus stets führt).
reached_f AS (
  SELECT r.depth
  FROM reached r
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = r.uuid
   AND oc.File_Name IS NOT DISTINCT FROM r.file
  WHERE (getvariable('types') IS NULL
         OR oc.Object_Type IN (SELECT unnest(string_split(CAST(getvariable('types') AS VARCHAR), ',')))
         OR (r.uuid = getvariable('focus')
             AND r.file IS NOT DISTINCT FROM (SELECT file FROM focus_seed)))
)
-- Knoten je Distanz (depth 0 = Fokus). Service bildet maxDepth + kumulative Last.
SELECT depth, COUNT(*) AS nodes
FROM reached_f
GROUP BY depth
ORDER BY depth;
