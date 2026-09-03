-- @template_type: report
-- @title: Graph Subgraph (Recursive k-Hop)
-- @description: Fokus-zentrierter k-Hop-Subgraph aus ObjectCatalog/ObjectLinks — gefiltert, gedeckelt, ehrlich gekürzt
-- @params: focus (required, UUID), focus_file, depth, direction, mode, types, roles, include_builtins, node_limit, hub_degree
-- @version: 1.9.0
-- @author: Marcel / Claude
-- @tags: graph, subgraph, explorer
-- @note: Core-Endpoint /api/graph/subgraph.
--        SPEZIALTYPEN (geerbt aus LogicalLinks 1.5.0, Converter 2.22.0 —
--        KEINE Logik-Änderung in diesem Template): Chart/Web Viewer werden in
--        der logischen Basis nicht mehr aufs Layout gehoisted. Folgen hier:
--        (a) am LAYOUT-Fokus liegt das Objekt auf d1 und seine Felder/Variablen
--        auf d2 — die Kette läuft über die operationale parent_layout-Kante des
--        Objekts; Tiefen- und total_reachable-Werte verschieben sich planmäßig.
--        (b) am OBJEKT-Fokus werden die Zeilen der Fokus-Selbst-Enklave (1.7.0)
--        zu Duplikaten der logischen Basis und falten per UNION/DISTINCT weg —
--        kein Typ-Filter nötig, das Doppel-Sprechen (roh + gehoistet) entfällt.
--        (c) diese parent_layout-Kante ist OPERATIONAL (nur LayoutPart→Layout
--        ist structural) — sie fällt damit nicht unter die Richtungs-
--        Unabhängigkeit der edges-CTE, sondern zählt regulär als out-Kante des
--        Objekts. Am Layout-Fokus ist sie folglich eine in-Kante: der reine
--        „Verwendet"-Modus zeigt die Spezialtyp-Ketten dort nicht (bewusster
--        v1-Trade-off; Default „Beides" ist unbetroffen).
--        1.9.0 (Anker-Durchgriff): ein feld-gebundener LayoutObject-Fokus erreicht
--        die Trigger-Ziele seines Anker-Felds schon bei depth 1 — als SYNTHETISCHE
--        Walk-Kante (Fokus → Trigger-Ziel), komponiert aus displays_field (roh,
--        nur LayoutObject-Quellen) × triggers_script des Felds. Sie lebt NUR in
--        der edges-CTE (Erreichbarkeits-Rechnung); final_edges liest aus base_f,
--        gezeichnet wird also KEINE Fokus→Script-Linie — sichtbar ist die ehrliche
--        Kette Fokus →repräsentiert→ Feld →Event→ Script. Bewusst NICHT die ganze
--        Feld-Nachbarschaft (Anker-Seed wäre bei Hub-Feldern die nächste Flut:
--        90/1518 Anker-Felder im Großkorpus mit Grad > 50, max 972); zählt als
--        „verwendet"-Richtung (nur out/both). Spiegelbild in graph_depth_profile.sql.
--        1.8.0 (ein Sprecher pro Trigger-Fakt): die Fokus-Selbst-Enklave klammert
--        `triggers_script` aus, wenn der Fokus FELD-GEBUNDEN ist (eigene
--        displays_field-Kante) — seit der Feld-Verankerung (LogicalLinks 1.4.0)
--        spricht dann das Feld; die Box sagt nur noch „repräsentiert Feld".
--        Vorher vertrat derselbe Fakt sich doppelt auf zwei Ebenen (Box UND
--        Feld). UI-Fokusse ohne Feld (Buttons/Panels) behalten ihre
--        triggers_script-/button_action-Kanten — kein anderer Träger.
--        Konsequenz der Tiefen-Semantik: am Feld-gebundenen Fokus liegt das
--        Script jetzt bei depth 2 (Fokus → Feld → Script). Spiegelbild in
--        graph_depth_profile.sql.
--        1.7.0 (Fokus-Selbst-Enklave): ALLE rohen operationalen Kanten des Fokus
--        selbst werden durchgereicht — ein LayoutObject-Fokus zeigt damit seine
--        eigenen Feld-/Script-/Variablen-Bezüge direkt (vorher Sackgasse: das
--        P5-Hoisting hebt sie aufs Layout), inkl. seiner eigenen triggers_script-
--        Kanten (am eigenen Fokus sind sie seine Logik — bewusst OHNE den
--        triggers_script-Ausschluss der Owner-Enklave). Für nicht-gehoistete
--        Fokus-Typen (Script, Field, Layout …) sind die Zeilen Duplikate der
--        logischen Basis und falten weg; LayoutPart wird mitgenommen. Subsumiert
--        die bisherigen Brücken-Sonderzweige trigger_script + Feld-Kandidaten
--        (Whitelist bereinigt; deren Richtungs-Unabhängigkeit in der edges-CTE
--        bleibt). Spiegelbild in graph_depth_profile.sql.
--        1.6.0 (Owner-Enklave): der Owner eines ScriptTrigger-Fokus kommt per
--        trigger_owner-Brücke in den Graph, hatte in der logischen Basis aber null
--        eigene Kanten (P5-Hoisting hebt LayoutObject-Kanten aufs Layout) — eine
--        Sackgasse. Die Enklave reicht die rohen operationalen Kanten GENAU dieses
--        Owners durch (triggers_script ausgeschlossen: Event-Spiegel duplizieren den
--        Trigger-Pfad und ziehen Geschwister-Trigger-Lärm hinein; button_action der
--        Einfachheit halber mit ausgeschlossen — Revisit-Option:
--        `AND NOT (Link_Role='triggers_script' AND Link_Subrole IS DISTINCT FROM
--        'button_action')` ließe Button-Aktionen zu). Ergebnis: Kette
--        Trigger → Owner → Feld ab depth 2; ins Layout läuft der Walk über die
--        operationale parent_layout-Kante des Owners regulär weiter. Spiegelbild in
--        graph_depth_profile.sql (Zähl-Konsistenz).
--        1.5.0 (Trigger-Fokus-Flanke): Fokus-Brücke reicht zusätzlich die
--        `trigger_script`-Kante und die OnWindowTransaction-Feld-Kandidaten
--        (reads_field·transaction_parameter_field) des Fokus-Triggers aus raw_links
--        durch — seit der Graph-Policy von Converter 2.17.0 (LogicalLinks ohne beide)
--        ist die Brücke der ALLEINIGE Kantenlieferant eines Trigger-Fokus (Owner via
--        trigger_owner, Script via trigger_script). Spiegelbild in
--        graph_depth_profile.sql.
--        1.4.0: Fokus-Brücke um `trigger_owner` ergänzt — ein ScriptTrigger-Fokus
--        zeigt im logical-Modus sonst nur die trigger_script-Kante (die Owner-Kante
--        ist strukturell und fehlt in LogicalLinks). Spiegelbild in
--        graph_depth_profile.sql (Zähl-Konsistenz des Tiefen-Sliders).
--        1.3.0: FOKUS-AUSNAHME im Typ-Filter (nodes_ranked) — der Fokus-Knoten bleibt
--        IMMER Teil des Subgraphen, unabhängig vom `types`-Filter. Vorher kollabierte
--        der Graph im „Nur gewählte Typen"-Modus, sobald man den Object_Type des Fokus
--        abwählte (Refetch ohne diesen Typ → Fokus weg → leer). Spiegelbild in
--        graph_depth_profile.sql (reached_f), damit total_reachable konsistent bleibt.
--        1.1.0: logische Sicht liest aus der View LogicalLinks (P5) statt Inline-CTE.
--        1.2.0: KLON-ROBUSTHEIT — die Knoten-Identität ist (UUID, File_Name), nicht die nackte
--        UUID. Der Walk folgt jeder Kante DATEI-GENAU (e.a_file = w.file); sonst merged eine
--        geklonte/shadow UUID die Nachbarschaften ALLER Dateien (focus_file skopierte vorher nur
--        den 409-Guard, nicht den Lauf → GM und LKU lieferten identisch). LogicalLinks/raw_links
--        führen jetzt Source_File/Target_File. Node-`id` = `uuid::file` (composite; synthetische
--        NULL-File-Objekte wie BuiltinFunction behalten id=uuid); das rohe `uuid` + `file` werden
--        separat ausgegeben, damit Navigation/Lazy-Expand weiter über (uuid, file) laufen.
--        VORAUSSETZUNG: die READ_ONLY-API-Kopie muss die View LogicalLinks (mit Source_File/
--        Target_File, P5 v≥…) enthalten — frischer convert-xml --batch synct sie mit.
--
-- ============================================================================
-- PARAMETER (von graph.service.js via Joi mit Defaults gesetzt, string-interpoliert)
-- ============================================================================
--   focus            UUID des Fokus-Knotens                       (Pflicht)
--   focus_file       File_Name des Fokus (Klon-Disambiguierung)    (Default NULL → Katalog-Auflösung)
--   depth            Rekursionstiefe 1..4                          (Default 1)
--   direction        'out' | 'in' | 'both'                        (Default 'both')
--   mode             'logical' | 'raw'                            (Default 'logical')
--   types            CSV der erlaubten Object_Type, NULL=alle      (Default NULL)
--   roles            CSV der erlaubten Link_Role, NULL=alle        (Default NULL)
--   include_builtins TRUE blendet BuiltinFunction-Ziele ein        (Default FALSE)
--   node_limit       harter Knoten-Deckel                         (Default 1000)
--   hub_degree       Grad-Schwelle für isHub-Markierung            (Default 100)
--
-- Die Template-Engine (template.service.js) ersetzt getvariable('x') durch das
-- escapte Literal. mode/direction werden als geschützte UNION-Zweige formuliert:
-- nach der Interpolation ist genau ein Zweig konstant-TRUE, den Optimizer kappt
-- den anderen (kein dynamisches SQL, weiterhin ein einziges Statement).
--
-- CLI-Test (getvariable existiert in DuckDB nativ):
--   SET VARIABLE focus = '…'; SET VARIABLE focus_file = '…'; SET VARIABLE depth = 2; …
--
-- ============================================================================
-- AUSGABE — eine getaggte Union (row_kind), die der Service partitioniert:
--   row_kind='node' → nodes[]   (id=uuid::file, uuid, label, type, file, depth, degree, is_hub, is_focus)
--   row_kind='edge' → edges[]   (id, source=uuid::file, target=uuid::file, role, subrole, link_type, cross_file)
-- `total_reachable` (auf jeder node-Zeile identisch) trägt die VOR-Deckel-Anzahl:
--   truncated = total_reachable > node_limit   (Prinzip "no silent caps").
-- ============================================================================

WITH RECURSIVE
-- 1) Roh-Kanten mit Waisen-Filter: beide Endpunkte katalogisiert. Datei mitführen.
raw_links AS (
  SELECT
    Source_UUID AS a, Source_File AS a_file,
    Target_UUID AS b, Target_File AS b_file,
    Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM ObjectLinks
  WHERE Source_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
    AND Target_UUID IN (SELECT Object_UUID FROM ObjectCatalog)
),
-- 2) Logische Sicht: Sub-Objekt-Endpunkte auf Container hochgezogen — aus der
--    P5-View LogicalLinks, die seit v1.2.0 Source_File/Target_File mitführt (Container
--    liegt datei-lokal beim Sub-Objekt). Spalten auf (a,b)+file gemappt.
logical_dedup AS (
  SELECT
    Source_UUID AS a, Source_File AS a_file,
    Target_UUID AS b, Target_File AS b_file,
    Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM LogicalLinks
),
-- 3) Aktive Basis nach mode wählen (ein Zweig wird nach Interpolation gekappt).
base AS (
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM logical_dedup
  WHERE getvariable('mode') = 'logical'
  UNION ALL
  -- Fokus-Brücke (logical), strukturelle Seite: ist der Fokus selbst ein
  -- Sub-Objekt (ScriptStep / LayoutObject / CustomMenuItem / ScriptTrigger),
  -- hält die echte strukturelle Parent-Kante (Fokus → Script/Layout/CustomMenu/
  -- Owner) den Einstieg anschlussfähig. Greift nur für den Fokus.
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM raw_links
  WHERE getvariable('mode') = 'logical'
    AND a = getvariable('focus')
    AND Link_Role IN ('parent_layout', 'parent_script', 'parent_menu', 'trigger_owner')
  UNION ALL
  -- Fokus-Selbst-Enklave (s. Kopf-Note 1.7.0): ALLE rohen operationalen Kanten
  -- des Fokus selbst — liefert einem gehoisteten Fokus (LayoutObject, LayoutPart)
  -- seine eigenen Bezüge und einem ScriptTrigger-Fokus trigger_script + Feld-
  -- Kandidaten (LogicalLinks führt beide seit der Graph-Policy 2.17.0 nicht mehr).
  -- Nicht-gehoistete Fokus-Typen erzeugen nur Duplikate der logischen Basis
  -- (UNION der edges-CTE + DISTINCT der final_edges falten sie weg).
  -- AUSNAHME (Kopf-Note 1.8.0): triggers_script eines FELD-GEBUNDENEN Fokus —
  -- das Feld ist der Sprecher, die Box nur die Repräsentation.
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
  -- Owner-Enklave (s. Kopf-Note 1.6.0): rohe operationale Kanten des Trigger-Owners.
  -- Nur für den Owner des FOKUS-Triggers; Tupel-Join datei-genau (Klon-Robustheit).
  -- triggers_script komplett ausgeschlossen (Kopf-Note); Duplikate bei Layout-/File-
  -- Ownern (deren Kanten liegen schon in LogicalLinks) schlucken das UNION der
  -- edges-CTE und das DISTINCT der final_edges.
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM raw_links
  WHERE getvariable('mode') = 'logical'
    AND (a, a_file) IN (SELECT b, b_file FROM raw_links
                        WHERE a = getvariable('focus')
                          AND Link_Role = 'trigger_owner')
    AND Link_Type = 'operational'
    AND Link_Role <> 'triggers_script'
  UNION ALL
  -- Fokus-Brücke Container-Seite: ist der Fokus ein CustomMenu, seine
  -- CustomMenuItems (parent_menu) als strukturelle Kinder zeigen. Menüs haben
  -- wenige Items und die Item↔Menü-Struktur ist die fachlich relevante Sicht
  -- (bei Skripten mit vielen Steps bewusst NICHT — daher auf parent_menu skopiert).
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM raw_links
  WHERE getvariable('mode') = 'logical'
    AND b = getvariable('focus')
    AND Link_Role = 'parent_menu'
  UNION ALL
  SELECT a, a_file, b, b_file, Link_Role, Link_Subrole, Link_Type, Is_Cross_File
  FROM raw_links
  WHERE getvariable('mode') = 'raw'
),
-- 4) Kanten-Filter: Builtins + optionale Rollen-Whitelist. Builtin-Filter über
--    den Ziel-Typ → Join auf ObjectCatalog DATEI-GENAU (sonst fächert eine geklonte
--    Ziel-UUID den Join über alle Dateien; synthetische NULL-File-Ziele via NULL-safe).
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
-- 5) Gerichtete Kantenmenge (direction): file-Paar auf beiden Endpunkten mitgeführt,
--    beim 'in'-Zweig symmetrisch getauscht.
edges AS (
  SELECT a, a_file, b, b_file FROM base_f WHERE getvariable('direction') IN ('out', 'both')
  UNION
  SELECT b AS a, b_file AS a_file, a AS b, a_file AS b_file FROM base_f WHERE getvariable('direction') IN ('in', 'both')
  UNION
  -- Fokus-Brücke richtungsunabhängig walkbar halten (auch bei direction='in').
  -- a=focus: Sub-Objekt → Container (parent_*) + Trigger → Script/Feld-Kandidaten
  -- (operational — kommen in base nur als Brücken-Zweig vor). b=focus:
  -- CustomMenu → seine Items (parent_menu, Container-Seite).
  SELECT a, a_file, b, b_file FROM base_f
  WHERE getvariable('mode') = 'logical'
    AND ((a = getvariable('focus')
          AND (Link_Type = 'structural' OR Link_Role = 'trigger_script'
               OR (Link_Role = 'reads_field'
                   AND Link_Subrole = 'transaction_parameter_field')))
         OR (b = getvariable('focus')
             AND Link_Type = 'structural' AND Link_Role = 'parent_menu'))
  UNION
  -- Anker-Durchgriff (Kopf-Note 1.9.0): Fokus → Trigger-Ziele des Anker-Felds.
  -- df aus raw_links (rohe displays_field-Kanten haben NUR LayoutObject-Quellen —
  -- das gehoistete Layout→Feld matcht hier nicht, ein Layout-Fokus bekommt keinen
  -- Durchgriff); ts aus base_f (Builtin-/Rollen-Filter gelten fürs Ziel). Datei-
  -- genauer Tupel-Join; a_file = Datei der eigenen displays_field-Kante = Fokus-Datei.
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
-- 6) Fokus-Saat: (UUID, File). focus_file wird durchgereicht; fehlt es (Nicht-Klon,
--    Downgrade), wird die eindeutige Datei aus dem Katalog aufgelöst. (Bei KLON ohne
--    focus_file hätte der Controller bereits 409 geworfen — dieser Pfad ist geschützt.)
focus_seed AS (
  SELECT
    getvariable('focus') AS uuid,
    COALESCE(
      NULLIF(CAST(getvariable('focus_file') AS VARCHAR), ''),
      (SELECT File_Name FROM ObjectCatalog WHERE Object_UUID = getvariable('focus') LIMIT 1)
    ) AS file
),
-- 7) Rekursiver Walk ab (Fokus, Fokus-Datei). UNION (nicht ALL) ⇒ Zyklen-Dedup.
--    DATEI-GENAU: der nächste Hop beginnt in genau der Datei, in der der vorige endete.
walk AS (
  SELECT uuid, file, 0 AS depth FROM focus_seed
  UNION
  SELECT e.b, e.b_file, w.depth + 1
  FROM walk w
  JOIN edges e
    ON e.a = w.uuid
   AND e.a_file IS NOT DISTINCT FROM w.file
  WHERE w.depth < CAST(getvariable('depth') AS INT)
),
reached AS (
  SELECT uuid, file, MIN(depth) AS depth FROM walk GROUP BY uuid, file
),
-- 8) Globaler operationaler Grad — als Hub-Signal bewusst UUID-aggregiert (datei-
--    übergreifend); für die isHub-Markierung ausreichend.
deg AS (
  SELECT id, COUNT(*) AS degree
  FROM (
    SELECT Source_UUID AS id FROM ObjectLinks
    WHERE Link_Type = 'operational' AND Source_UUID IN (SELECT uuid FROM reached)
    UNION ALL
    SELECT Target_UUID AS id FROM ObjectLinks
    WHERE Link_Type = 'operational' AND Target_UUID IN (SELECT uuid FROM reached)
  )
  GROUP BY id
),
-- 9) Knoten + optionaler Typ-Filter; Katalog-Join DATEI-GENAU (eine Zeile je (uuid,file)).
--    FOKUS-AUSNAHME: der Fokus-Knoten überlebt den Typ-Filter IMMER — auch wenn sein
--    eigener Object_Type abgewählt ist. Ohne diese Ausnahme kollabiert der Graph im
--    „Nur gewählte Typen"-Modus komplett, sobald man den Typ des Fokus deaktiviert
--    (Refetch ohne diesen Typ → Fokus weg → leerer Graph). Identität = (uuid, file),
--    deckungsgleich mit der is_focus-Projektion in der Ausgabe.
nodes_ranked AS (
  SELECT
    r.uuid, r.file, r.depth,
    oc.Object_Type AS type, oc.Object_Name AS label,
    COALESCE(d.degree, 0) AS degree
  FROM reached r
  JOIN ObjectCatalog oc
    ON oc.Object_UUID = r.uuid
   AND oc.File_Name IS NOT DISTINCT FROM r.file
  LEFT JOIN deg d ON d.id = r.uuid
  WHERE (getvariable('types') IS NULL
         OR oc.Object_Type IN (SELECT unnest(string_split(CAST(getvariable('types') AS VARCHAR), ',')))
         OR (r.uuid = getvariable('focus')
             AND r.file IS NOT DISTINCT FROM (SELECT file FROM focus_seed)))
),
-- 10) Deckel: kleinste depth zuerst, dann höchster Grad.
nodes_capped AS (
  SELECT *, ROW_NUMBER() OVER (ORDER BY depth ASC, degree DESC, label ASC) AS rn
  FROM nodes_ranked
),
kept AS (
  SELECT * FROM nodes_capped
  WHERE rn <= CAST(getvariable('node_limit') AS INT)
),
-- 11) Kanten des Subgraphen: beide (uuid,file)-Endpunkte überleben den Deckel
--     (NULL-safe membership via EXISTS, damit synthetische NULL-File-Ziele matchen).
final_edges AS (
  SELECT DISTINCT
    bf.a AS source_uuid, bf.a_file AS source_file,
    bf.b AS target_uuid, bf.b_file AS target_file,
    bf.Link_Role AS role, bf.Link_Subrole AS subrole,
    bf.Link_Type AS link_type, bf.Is_Cross_File AS cross_file
  FROM base_f bf
  WHERE EXISTS (SELECT 1 FROM kept k WHERE k.uuid = bf.a AND k.file IS NOT DISTINCT FROM bf.a_file)
    AND EXISTS (SELECT 1 FROM kept k WHERE k.uuid = bf.b AND k.file IS NOT DISTINCT FROM bf.b_file)
)
-- ── getaggte Ausgabe ───────────────────────────────────────────────────────
SELECT
  'node'                                                AS row_kind,
  k.uuid || COALESCE('::' || k.file, '')                AS id,
  k.uuid                                                AS uuid,
  k.label                                               AS label,
  k.type                                                AS type,
  k.file                                                AS file,
  k.depth                                               AS depth,
  k.degree                                              AS degree,
  (k.degree >= CAST(getvariable('hub_degree') AS INT))  AS is_hub,
  (k.uuid = getvariable('focus')
     AND k.file IS NOT DISTINCT FROM (SELECT file FROM focus_seed)) AS is_focus,
  (SELECT COUNT(*) FROM nodes_ranked)                   AS total_reachable,
  -- P5-Naht: community/communityName reicht der Service (enrichCommunities) nach.
  NULL                                                  AS community,
  NULL                                                  AS source,
  NULL                                                  AS target,
  NULL                                                  AS role,
  NULL                                                  AS subrole,
  NULL                                                  AS link_type,
  NULL                                                  AS cross_file
FROM kept k
UNION ALL
SELECT
  'edge',
  (e.source_uuid || COALESCE('::' || e.source_file, '')
     || '|' || COALESCE(e.role, '') || '|'
     || e.target_uuid || COALESCE('::' || e.target_file, '')) AS id,
  NULL                                                  AS uuid,
  -- 9 NULLs: label, type, file, depth, degree, is_hub, is_focus, total_reachable, community
  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  (e.source_uuid || COALESCE('::' || e.source_file, '')) AS source,
  (e.target_uuid || COALESCE('::' || e.target_file, '')) AS target,
  e.role, e.subrole, e.link_type, e.cross_file
FROM final_edges e
ORDER BY row_kind, degree DESC NULLS LAST;
