-- ============================================
-- create_analysis_views.sql
-- ============================================
-- Fundament der statischen Code-Analyse (PMD-inspirierte Rule-Bundles).
--
-- Eigene, BATCH-WEITE, TABLE-ONLY Phase NACH P6 (Validate). Liest ausschließlich
-- DuckDB-Tabellen (kein read_xml). Wird — wie die universal catalogs — bei JEDEM
-- convert-xml-Lauf vollständig neu gebaut (volatil, keine Migration).
--
-- NIEMALS in P2 einbauen: P2 läuft partitioniert read-only über die Master-DB;
-- ALTER/UPDATE/CREATE dort bricht alle Slices ab.
--
-- Erzeugt:
--   - step_metadata        Seed: Step_ID → Block-/Semantik-Marker (Single Source
--                          der Kontrollfluss-Deltas für den Block-Tree)
--   - v_script_block_tree  MATERIALIZED: pro Step die Loop-/If-Verschachtelungstiefe,
--                          partitioniert nach (File_Name, Script_ID)
--   - v_script_step_links  MATERIALIZED: die Script-Kanten je Script-Schritt (Rolle,
--                          Ziel, Quelle Schritt-Parameter oder Schritt-Formel), Schema 1.41.0
--   - v_table_occurrence_usage  MATERIALIZED: jede Fundstelle einer Table Occurrence
--                          (TO × nutzendes Objekt × Kategorie × Rolle), Schema 1.38.0
--   - v_table_occurrence_class  MATERIALIZED: eine Zeile je TO — Nutzungsklasse aus
--                          Zählung + Pfadanalyse im Beziehungsgraphen, Schema 1.38.0
--   - v_object_usage       MATERIALIZED: eine Zeile je Objekt (Field, Script, Layout,
--                          CustomFunction, ValueList, BaseTable, ExternalDataSource,
--                          PrivilegeSet, TableOccurrence, Relationship) — Nutzungszahlen,
--                          Marker und Nutzungsklasse, Schema 1.40.0
--   - v_layout_object_font MATERIALIZED: eine Zeile je Text zeigendem Layout-Objekt —
--                          effektive Schrift, Größe, Gewicht, Schnitt und ihre Herkunft
--                          (lokal → Stil → Bereich → Typ → Gruppe → Datei-Standard),
--                          Schema 1.44.0
--   - v_layout_object_style VIEW: eine Zeile je Layout-Objekt (alle Typen) — angewandter
--                          Stil, Design des Layouts, eigener Stil, Stil ohne Regel im
--                          Design, Schema 1.45.0

-- --------------------------------------------
-- step_metadata — Block-/Semantik-Marker je ScriptStep-Typ
-- --------------------------------------------
-- Step-Namen + Analyse-Semantik. Die Kontrollfluss-Marker (loop_delta/if_delta,
-- control_kind) sind verifiziert (Master-DB 2026-06-30) und treiben den Block-Tree.
-- Die übrigen Spalten (has_side_effects/is_find_mode/is_mutation/deprecated_in)
-- sind Handpflege und hier auf die für die MVP-Rules relevanten Steps geseedet;
-- bewusst erweiterbar (weitere Step-IDs additiv ergänzen).
DROP TABLE IF EXISTS step_metadata;
CREATE TABLE step_metadata (
    Step_ID          INTEGER PRIMARY KEY,
    Step_Name        VARCHAR,
    is_control_flow  BOOLEAN DEFAULT FALSE,
    control_kind     VARCHAR,            -- if_open | if_branch | if_close | loop_open | loop_exit | loop_close | script_exit
    loop_delta       INTEGER DEFAULT 0,  -- +1 Loop, -1 End Loop
    if_delta         INTEGER DEFAULT 0,  -- +1 If,   -1 End If
    has_side_effects BOOLEAN DEFAULT FALSE,
    is_find_mode     BOOLEAN DEFAULT FALSE,
    is_mutation      BOOLEAN DEFAULT FALSE,
    deprecated_in    VARCHAR
);

INSERT INTO step_metadata
    (Step_ID, Step_Name, is_control_flow, control_kind, loop_delta, if_delta, has_side_effects, is_find_mode, is_mutation, deprecated_in)
VALUES
    -- Kontrollfluss (Block-Tree-treibend)
    ( 68, 'If',                TRUE, 'if_open',     0,  1, FALSE, FALSE, FALSE, NULL),
    ( 69, 'Else',              TRUE, 'if_branch',   0,  0, FALSE, FALSE, FALSE, NULL),
    (125, 'Else If',           TRUE, 'if_branch',   0,  0, FALSE, FALSE, FALSE, NULL),
    ( 70, 'End If',            TRUE, 'if_close',    0, -1, FALSE, FALSE, FALSE, NULL),
    ( 71, 'Loop',              TRUE, 'loop_open',   1,  0, FALSE, FALSE, FALSE, NULL),
    ( 72, 'Exit Loop If',      TRUE, 'loop_exit',   0,  0, FALSE, FALSE, FALSE, NULL),
    ( 73, 'End Loop',          TRUE, 'loop_close', -1,  0, FALSE, FALSE, FALSE, NULL),
    (103, 'Exit Script',       TRUE, 'script_exit', 0,  0, FALSE, FALSE, FALSE, NULL),
    ( 90, 'Halt Script',       TRUE, 'script_exit', 0,  0, FALSE, FALSE, FALSE, NULL),
    -- Nebenwirkungen / Find-Mode / Mutationen (für Performance-/Korrektheits-Rules)
    ( 28, 'Perform Find',      FALSE, NULL,         0,  0, TRUE,  TRUE,  FALSE, NULL),
    ( 39, 'Sort Records',      FALSE, NULL,         0,  0, TRUE,  FALSE, FALSE, NULL),
    (  6, 'Go to Layout',      FALSE, NULL,         0,  0, TRUE,  FALSE, FALSE, NULL),
    ( 76, 'Set Field',         FALSE, NULL,         0,  0, TRUE,  FALSE, TRUE,  NULL),
    ( 75, 'Commit Records/Requests', FALSE, NULL,   0,  0, TRUE,  FALSE, TRUE,  NULL),
    (141, 'Set Variable',      FALSE, NULL,         0,  0, FALSE, FALSE, FALSE, NULL),
    ( 86, 'Set Error Capture', FALSE, NULL,         0,  0, FALSE, FALSE, FALSE, NULL);

-- --------------------------------------------
-- v_script_block_tree — Block-Verschachtelung pro Step (MATERIALIZED)
-- --------------------------------------------
-- PARTITION BY (File_Name, Script_ID): NICHT Script_UUID — die ist in 2 Fällen
-- nicht global eindeutig (Merge-Artefakt) und würde fremde Scripts verklammern.
--
-- Loop-Marker sind global balanciert (1220=1220) → loop_depth_before bleibt roh
-- (keine negative Tiefe). If-Marker sind leicht unbalanciert (2 defekte Scripts
-- in "Artikel Bilder") → if_depth_* wird per GREATEST(0,…) geclampt, damit ein
-- End If ohne offenes If den Block-Tree nicht ins Negative zieht.
DROP TABLE IF EXISTS v_script_block_tree;
CREATE TABLE v_script_block_tree AS
WITH stepped AS (
    SELECT
        s.File_Name, s.Script_ID, s.Script_UUID, s.Script_Name,
        s.Step_Index, s.Step_ID, s.Step_Name, s.Step_UUID, s.Is_Enabled,
        COALESCE(m.loop_delta, 0) AS loop_delta,
        COALESCE(m.if_delta,   0) AS if_delta
    FROM StepsForScripts s
    LEFT JOIN step_metadata m ON s.Step_ID = m.Step_ID
),
acc AS (
    SELECT *,
        COALESCE(SUM(loop_delta) OVER w_before, 0) AS loop_depth_before_raw,
        COALESCE(SUM(if_delta)   OVER w_before, 0) AS if_depth_before_raw,
        COALESCE(SUM(loop_delta) OVER w_incl,   0) AS loop_depth_after_raw,
        COALESCE(SUM(if_delta)   OVER w_incl,   0) AS if_depth_after_raw
    FROM stepped
    WINDOW
        w_before AS (PARTITION BY File_Name, Script_ID ORDER BY Step_Index
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
        w_incl   AS (PARTITION BY File_Name, Script_ID ORDER BY Step_Index
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
)
SELECT
    File_Name, Script_ID, Script_UUID, Script_Name,
    Step_Index, Step_ID, Step_Name, Step_UUID, Is_Enabled,
    loop_delta, if_delta,
    loop_depth_before_raw                                AS loop_depth_before,
    GREATEST(0, if_depth_before_raw)                     AS if_depth_before,
    GREATEST(0, loop_depth_after_raw)                    AS loop_depth_after,
    GREATEST(0, if_depth_after_raw)                      AS if_depth_after,
    -- Rohe (ungeclampte) laufende If-Tiefe nach dem Step: < 0 markiert ein End If
    -- ohne offenes If — das negative Signal, das if_depth_after (geclampt) bewusst
    -- verschluckt. Zählt ALLE Steps; die unbalanced-if-Rule rechnet die Bilanz
    -- selbst nur über aktive Steps (deaktivierte Block-Reste laufen nicht).
    if_depth_after_raw                                   AS if_running_depth,
    loop_depth_before_raw + GREATEST(0, if_depth_before_raw) AS block_depth_before
FROM acc;

CREATE INDEX idx_block_tree_script ON v_script_block_tree (File_Name, Script_ID);
CREATE INDEX idx_block_tree_step   ON v_script_block_tree (Step_UUID);

-- --------------------------------------------
-- v_script_step_links — Script-Kanten je Schritt (MATERIALIZED, Schema 1.41.0)
-- --------------------------------------------
-- ObjectLinks führt die Nutzung eines Scripts je Referenz, aber am Script: welcher
-- SCHRITT ein Feld setzt, ein Script aufruft oder ein Layout ansteuert, geht dort
-- verloren. Diese Sicht projiziert dieselben Kanten auf den Schritt, ohne neue
-- XML-Auswertung — die Antwort auf „welcher Schritt setzt Feld F?" ohne Regex auf
-- Parameters_XML/Step_XML.
--
-- Zwei Quellen (Spalte Via):
--   parameter   — Referenzen im Schritt selbst (XMLStepReferences, nach den P4-
--                 Korrekturen: Cross-File-Auflösung, UUID-Heilung, TO-relative
--                 Feld-UUIDs). Rolle wie P4-Block 15/16/16b/24/24b/24c/installs_menuset:
--                 Felder über StepFieldParamRoles (Rolle je Parameter bei Steps mit
--                 Quelle UND Ziel) bzw. ScriptStepRoleMap (Fallback references_field), Script-
--                 Aufrufe calls_script (+ Subrole on_server/on_server_callback),
--                 Layout navigates_to_layout, GTRR-TO navigates_to_to, Werteliste
--                 sorts_by_valuelist, Menüset installs_menuset, Datenquelle data_source.
--   calculation — Referenzen in den Formeln des Schritts (CalculationsCatalog,
--                 Owner_Type = ScriptStep, über v_calculation_links; dort schrittgenau).
-- Variablen (Konverter 2.50.0) aus VariableUsages (schrittgenau über Script_UUID +
-- Step_Index): sets_variable/reads_variable wie P4-Block 24/25, Ziel-Datei aus
-- VariablesCatalog wie dort. Via 'parameter' = Zielvariable des Schritts (Set Variable,
-- Insert …/Show Custom Dialog/… in eine Variable), 'calculation' = in einer Formel
-- (gelesen oder per Let gesetzt); Calculation_UUID über den Formel-Hash im Schritt
-- (CalculationsCatalog.Formula_Hash = VariableUsages.Calc_Hash), NULL bei mehrdeutigem
-- Hash oder ohne DDR-Info. Link_Subrole = Herkunft, wo sie nicht der Normalfall ist
-- (let_assign, regex_fallback, mbs_variable_call). let_local zählt nicht (formelintern).
--
-- Target_File/Is_Cross_File kommen aus ObjectLinks selbst (gleiche Kante = gleiche
-- Ziel-Auflösung inkl. prefer-local/keep), statt die Reihenfolge hier nachzubauen;
-- ein Ziel in mehreren Dateien (Klone, bewusst behalten) ergibt mehrere Zeilen.
-- In_Graph = FALSE: Referenz ohne Kante, weil das Ziel kein Katalogobjekt ist
-- (z. B. das eingebaute Menüset „[Standard FileMaker Menus]"). Eine offene Kante
-- (Ziel in einer nicht importierten Datei, Target_File NULL) zählt als In_Graph.
-- Schlüssel eines Schritts ist (Step_UUID, File_Name): geklonte Dateien teilen
-- Schritt-UUIDs. Nicht enthalten: Script-Aufrufe aus Formeln über MBS FM.RunScript
-- (in ObjectLinks mit Subrole MBS:FM.RunScript; v_calculation_links kennt sie nicht).
DROP TABLE IF EXISTS v_script_step_links;
CREATE TABLE v_script_step_links AS
WITH steps AS (
    SELECT DISTINCT Step_UUID, Script_UUID, File_Name, Step_Index, Step_ID, Step_Name, Is_Enabled
    FROM StepsForScripts
),
refs AS (
    -- Occurrence wie P4-Block 16: paart gleiche Feld-Referenzen eines Steps mit den
    -- Parameter-Rollen aus StepFieldParamRoles (Quelle UND Ziel im selben Step).
    SELECT x.Script_UUID, x.File_Name, x.Step_UUID, x.Ref_Type, x.Ref_UUID, x.TO_UUID, x.Data_Source_UUID,
           x.Ref_ID, x.TO_Ref_ID,
           row_number() OVER (PARTITION BY x.Step_UUID, x.File_Name, x.Ref_Type, x.Ref_ID, x.TO_Ref_ID
                              ORDER BY x.Ref_UUID) AS Occurrence
    FROM XMLStepReferences x
    WHERE x.Ref_Type IN ('field', 'script', 'layout', 'tableOccurrence', 'valuelist', 'menuset', 'data_source')
      AND x.Ref_UUID IS NOT NULL
),
typed AS (
    SELECT r.*, s.Step_Index, s.Step_ID, s.Step_Name, s.Is_Enabled,
           CASE r.Ref_Type
               WHEN 'field'           THEN COALESCE(pr.Link_Role, rm.Link_Role, 'references_field')
               WHEN 'script'          THEN 'calls_script'
               WHEN 'layout'          THEN 'navigates_to_layout'
               WHEN 'tableOccurrence' THEN 'navigates_to_to'
               WHEN 'valuelist'       THEN 'sorts_by_valuelist'
               WHEN 'menuset'         THEN 'installs_menuset'
               WHEN 'data_source'     THEN 'data_source'
           END AS Link_Role,
           CASE r.Ref_Type
               WHEN 'field'           THEN 'Field'
               WHEN 'script'          THEN 'Script'
               WHEN 'layout'          THEN 'Layout'
               WHEN 'tableOccurrence' THEN 'TableOccurrence'
               WHEN 'valuelist'       THEN 'ValueList'
               WHEN 'menuset'         THEN 'CustomMenuSet'
               WHEN 'data_source'     THEN 'ExternalDataSource'
           END AS Target_Type,
           CASE WHEN r.Ref_Type = 'script' THEN
               CASE s.Step_ID WHEN 164 THEN 'on_server' WHEN 210 THEN 'on_server_callback' END
           END AS Link_Subrole
    FROM refs r
    LEFT JOIN steps s
           ON s.Step_UUID = r.Step_UUID AND s.Script_UUID = r.Script_UUID AND s.File_Name = r.File_Name
    LEFT JOIN ScriptStepRoleMap rm ON rm.Step_ID = s.Step_ID
    LEFT JOIN StepFieldParamRoles pr
           ON r.Ref_Type = 'field'
          AND pr.Step_UUID = r.Step_UUID AND pr.File_Name = r.File_Name
          AND pr.Ref_ID = r.Ref_ID AND pr.TO_Ref_ID IS NOT DISTINCT FROM r.TO_Ref_ID
          AND pr.Occurrence = r.Occurrence
),
edges AS (
    SELECT DISTINCT Source_UUID, Source_File, Target_UUID, Target_Type, Link_Role, Target_File, Is_Cross_File
    FROM ObjectLinks
    WHERE Source_Type = 'Script'
)
SELECT DISTINCT
    t.Script_UUID, t.File_Name, t.Step_UUID,
    CAST(t.Step_Index AS INTEGER) AS Step_Index,
    CAST(t.Step_ID AS INTEGER)    AS Step_ID,
    t.Step_Name, t.Is_Enabled,
    'parameter'                   AS Via,
    CAST(NULL AS VARCHAR)         AS Calculation_UUID,
    t.Link_Role, t.Link_Subrole,
    t.Target_Type, t.Ref_UUID     AS Target_UUID, e.Target_File, e.Is_Cross_File,
    t.TO_UUID, t.Data_Source_UUID,
    (e.Source_UUID IS NOT NULL)   AS In_Graph
FROM typed t
LEFT JOIN edges e
       ON e.Source_UUID = t.Script_UUID AND e.Source_File = t.File_Name
      AND e.Target_UUID = t.Ref_UUID AND e.Target_Type = t.Target_Type AND e.Link_Role = t.Link_Role
UNION ALL
SELECT
    s.Script_UUID, s.File_Name, s.Step_UUID,
    CAST(s.Step_Index AS INTEGER), CAST(s.Step_ID AS INTEGER),
    s.Step_Name, s.Is_Enabled,
    'calculation', c.Calculation_UUID,
    l.Link_Role, CAST(NULL AS VARCHAR),
    l.Target_Type, l.Target_UUID, l.Target_File, l.Is_Cross_File,
    CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    TRUE
FROM CalculationsCatalog c
JOIN steps s               ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
JOIN v_calculation_links l ON l.Calculation_UUID = c.Calculation_UUID
WHERE c.Owner_Type = 'ScriptStep'
UNION ALL
SELECT DISTINCT
    s.Script_UUID, s.File_Name, s.Step_UUID,
    CAST(s.Step_Index AS INTEGER), CAST(s.Step_ID AS INTEGER),
    s.Step_Name, s.Is_Enabled,
    CASE WHEN vu.Source IN ('set_variable_step', 'target_variable_step') THEN 'parameter'
         ELSE 'calculation' END,
    CASE WHEN vu.Source IN ('ddr_chunk', 'let_assign') THEN fh.Calculation_UUID END,
    CASE vu.Usage_Type WHEN 'set' THEN 'sets_variable' ELSE 'reads_variable' END,
    CASE WHEN vu.Source IN ('let_assign', 'regex_fallback', 'mbs_variable_call') THEN vu.Source END,
    'Variable',
    md5(vu.Variable_Scope || '::' || vu.Scope_Anchor || '::' || vu.Variable_Name),
    vc.File_Name, (vu.File_Name IS DISTINCT FROM vc.File_Name),
    CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
    (vc.Variable_Name IS NOT NULL)
FROM VariableUsages vu
JOIN steps s ON s.Script_UUID = vu.Script_UUID AND s.File_Name = vu.File_Name
            AND s.Step_Index = vu.Step_Index
LEFT JOIN VariablesCatalog vc
       ON vc.Variable_Name = vu.Variable_Name AND vc.Variable_Scope = vu.Variable_Scope
      AND vc.Scope_Anchor = vu.Scope_Anchor
      AND (vu.Variable_Scope = 'superglobal' OR vc.File_Name = vu.File_Name)
LEFT JOIN (
    -- Formel-Hash → Formel des Schritts; nur eindeutige Zuordnungen
    SELECT Owner_UUID, File_Name, Formula_Hash, any_value(Calculation_UUID) AS Calculation_UUID
    FROM CalculationsCatalog
    WHERE Owner_Type = 'ScriptStep' AND Formula_Hash IS NOT NULL
    GROUP BY ALL
    HAVING COUNT(*) = 1
) fh ON fh.Owner_UUID = s.Step_UUID AND fh.File_Name = s.File_Name AND fh.Formula_Hash = vu.Calc_Hash
WHERE vu.Context_Type = 'script_step'
  AND vu.Variable_Scope IN ('global', 'local', 'superglobal')
  AND vu.Script_UUID IS NOT NULL;

CREATE INDEX idx_step_links_step   ON v_script_step_links (Step_UUID, File_Name);
CREATE INDEX idx_step_links_script ON v_script_step_links (Script_UUID, File_Name);
CREATE INDEX idx_step_links_target ON v_script_step_links (Target_UUID, Link_Role);

-- v_check_script_step_links — Vollständigkeit der Schritt-Projektion (eine Zeile).
-- Jede Script-Kante in ObjectLinks, die aus einem Schritt stammt, muss mindestens
-- eine Zeile mit gleichem Ziel und gleicher Rolle in v_script_step_links haben.
-- Nicht aus Schritten: parent_folder (Ordner). Die Variablen-Rollen sind seit
-- Konverter 2.50.0 enthalten (Quelle VariableUsages wie P4-Block 24/25). explained_n = bekannte Lücke: Script-Aufrufe
-- über MBS FM.RunScript aus Formeln (Link_Subrole 'MBS:…'). Umgekehrt zählt
-- surplus_n Schritt-Zeilen (Script × Ziel × Zieldatei × Rolle) ohne Kante — etwa ein
-- Ziel in der falschen Datei, wenn geklonte Dateien UUIDs teilen. Der Konverter
-- warnt bei unexplained_n > 0 oder surplus_n > 0 (postcheck_script_step_links).
CREATE OR REPLACE VIEW v_check_script_step_links AS
WITH e AS (
    SELECT DISTINCT Source_UUID, Source_File, Target_UUID, Link_Role, Link_Subrole
    FROM ObjectLinks
    WHERE Source_Type = 'Script'
      AND Link_Role <> 'parent_folder'
),
v AS (
    SELECT DISTINCT Script_UUID, File_Name, Target_UUID, Link_Role
    FROM v_script_step_links
    WHERE In_Graph
),
missing AS (
    SELECT e.*, COALESCE(e.Link_Subrole LIKE 'MBS:%', FALSE) AS explained
    FROM e
    LEFT JOIN v ON v.Script_UUID = e.Source_UUID AND v.File_Name = e.Source_File
               AND v.Target_UUID = e.Target_UUID AND v.Link_Role = e.Link_Role
    WHERE v.Script_UUID IS NULL
),
surplus AS (
    SELECT DISTINCT v.Script_UUID, v.File_Name, v.Target_UUID, v.Target_File, v.Link_Role
    FROM v_script_step_links v
    WHERE v.In_Graph AND v.Target_File IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM ObjectLinks o
                      WHERE o.Source_Type = 'Script' AND o.Source_UUID = v.Script_UUID
                        AND o.Source_File = v.File_Name AND o.Target_UUID = v.Target_UUID
                        AND o.Target_File = v.Target_File AND o.Link_Role = v.Link_Role)
)
SELECT
    (SELECT COUNT(*) FROM e)                                      AS edges_n,
    COUNT(*)                                                      AS missing_n,
    COUNT(*) FILTER (WHERE explained)                             AS explained_n,
    COUNT(*) FILTER (WHERE NOT explained)                         AS unexplained_n,
    COUNT(*) FILTER (WHERE NOT explained AND Link_Role = 'sets_field') AS sets_field_missing_n,
    (SELECT string_agg(Link_Role || '×' || n, ', ' ORDER BY n DESC, Link_Role)
     FROM (SELECT Link_Role, COUNT(*) AS n FROM missing WHERE NOT explained GROUP BY Link_Role)) AS detail,
    (SELECT COUNT(*) FROM surplus)                                AS surplus_n,
    (SELECT string_agg(Link_Role || '×' || n, ', ' ORDER BY n DESC, Link_Role)
     FROM (SELECT Link_Role, COUNT(*) AS n FROM surplus GROUP BY Link_Role)) AS surplus_detail
FROM missing;

-- --------------------------------------------
-- v_check_calculation_sql_refs — Konsistenz der SQL-Bezüge (eine Zeile; Schema 1.42.0)
-- --------------------------------------------
-- missing_n        SQL-Formeln (Funktions-Baustein ExecuteSQL/ExecuteSQLe) mit FROM im
--                  Text, aber ohne Zeile in CalculationSqlRefs → Zerlegung lückenhaft
-- ref_no_edge_n    Formel-Referenzen (Bausteinpfad) ohne passende Owner-Kante in
--                  ObjectLinks (Block 30) → Ziel-Auflösung weicht von Block 30 ab
-- dup_edge_n       Namens-Bezüge, deren Kante in ObjectLinks doppelt steht → Block 30b
--                  dedupliziert nicht gegen Block 30
-- unresolved_n     Namen bzw. Referenzen ohne Ziel (gebrochene Bezüge, z. B. fehlende
--                  TO oder <Field Missing>) — Information, kein Defekt der Pipeline
CREATE OR REPLACE VIEW v_check_calculation_sql_refs AS
WITH sql_calcs AS (
    SELECT DISTINCT c.Calculation_UUID, c.File_Name, c.Display_Text
    FROM CalculationsCatalog c
    JOIN DDR_Calculations d ON d.Calc_UUID = c.DDR_Calc_UUID AND d.File_Name = c.File_Name
    WHERE d.Chunk_Type = 'FunctionRef'
      AND (d.Chunk_Content LIKE '%>ExecuteSQL<%' OR d.Chunk_Content LIKE '%>ExecuteSQLe<%')
      -- SQL-Text-Eingabe von Execute SQL ist keine Formel (P4 überspringt sie)
      AND c.Calc_Role <> 'step_sql_text'
),
missing AS (
    SELECT s.* FROM sql_calcs s
    ANTI JOIN CalculationSqlRefs r ON r.Calculation_UUID = s.Calculation_UUID AND r.File_Name = s.File_Name
    WHERE regexp_matches(s.Display_Text, '(?i)\bfrom\b')
),
-- Owner-Kanten je Bezug (Quelle wie Block 30: Eigentümer, bei Schritten das Script)
ref_edges AS (
    SELECT DISTINCT
           CASE WHEN c.Owner_Type = 'ScriptStep' THEN s.Script_UUID ELSE c.Owner_UUID END AS Source_UUID,
           c.File_Name, r.Target_UUID, c.Edge_Subrole
    FROM CalculationSqlRefs r
    JOIN CalculationsCatalog c ON c.Calculation_UUID = r.Calculation_UUID AND c.File_Name = r.File_Name
    LEFT JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE r.Resolution = 'reference' AND r.Target_Type = 'Field' AND r.Parse_Source = 'ddr'
      AND COALESCE(c.Is_Enabled, TRUE) AND c.Owner_Type <> 'unresolved'
),
ref_no_edge AS (
    SELECT e.* FROM ref_edges e
    ANTI JOIN ObjectLinks ol
      ON ol.Source_UUID = e.Source_UUID AND ol.Source_File = e.File_Name
     AND ol.Target_UUID = e.Target_UUID AND ol.Link_Subrole IS NOT DISTINCT FROM e.Edge_Subrole
     AND ol.Link_Role IN ('reads_field', 'validates_by_calc')
),
name_edges AS (
    SELECT DISTINCT
           CASE WHEN c.Owner_Type = 'ScriptStep' THEN s.Script_UUID ELSE c.Owner_UUID END AS Source_UUID,
           c.File_Name, r.Target_UUID, c.Edge_Subrole
    FROM CalculationSqlRefs r
    JOIN CalculationsCatalog c ON c.Calculation_UUID = r.Calculation_UUID AND c.File_Name = r.File_Name
    LEFT JOIN StepsForScripts s ON s.Step_UUID = c.Owner_UUID AND s.File_Name = c.File_Name
    WHERE r.Resolution = 'name' AND r.Target_Type = 'Field'
),
-- Je Slot (Edge_Subrole) zählen: ein Script liest dasselbe Feld legitim aus
-- mehreren Schritt-Slots (z. B. Execute SQL „SQL“ und Set Variable „1“)
dup AS (
    SELECT n.Source_UUID, n.File_Name, n.Target_UUID, n.Edge_Subrole
    FROM name_edges n
    JOIN ObjectLinks ol
      ON ol.Source_UUID = n.Source_UUID AND ol.Source_File = n.File_Name
     AND ol.Target_UUID = n.Target_UUID AND ol.Link_Subrole IS NOT DISTINCT FROM n.Edge_Subrole
     AND ol.Link_Role IN ('reads_field', 'validates_by_calc')
    GROUP BY ALL
    HAVING COUNT(*) > 1
)
SELECT
    (SELECT COUNT(*) FROM CalculationSqlRefs)                                       AS rows_n,
    (SELECT COUNT(*) FROM sql_calcs)                                                AS sql_calcs_n,
    (SELECT COUNT(*) FROM missing)                                                  AS missing_n,
    (SELECT COUNT(*) FROM ref_no_edge)                                              AS ref_no_edge_n,
    (SELECT COUNT(*) FROM dup)                                                      AS dup_edge_n,
    (SELECT COUNT(*) FROM CalculationSqlRefs
      WHERE Resolution IN ('name', 'reference') AND Target_Type IS NULL
        AND NOT Low_Confidence AND Clause <> 'parameter')                           AS unresolved_n,
    (SELECT COUNT(*) FROM CalculationSqlRefs WHERE Resolution = 'name' AND Target_Type = 'Field') AS name_field_n;

-- --------------------------------------------
-- v_calc_anchors — Kanonische Calc-Anker-Registry (MATERIALIZED)
-- --------------------------------------------
-- Ordnet jede DDR-Berechnung ihrem besitzenden Objekt und ihrer Eigenschaft zu.
-- Die EINE Wahrheit für Detailansicht (AP-2) und Graph-Herkunft (AP-3).
--
-- Anker-Mechanik: DDR_Calculations.Calc_UUID folgt dem Muster _<36-Zeichen-UUID>_<calc_kind>
--   - Mitte = Anker-UUID (besitzendes Objekt / Step / Menü-Position)
--   - Suffix calc_kind = die Eigenschaft (Hide, Tooltip, Condition_N, Portal, PopoverPanel,
--     Install, Title, Name, NUMERIC=Step-Parameter, leer=CF-Body …)
-- Robuste Extraktion (deckt auch die CF-Body-Form _<uuid> OHNE Trailing-Underscore ab):
--   Anchor_UUID   = upper(regexp_extract(Calc_UUID,'_([0-9A-Fa-f-]{36})',1))
--   Calc_Kind_Raw = regexp_replace(Calc_UUID,'^_[0-9A-Fa-f-]{36}_?','')  ('' → CF-Body)
--
-- Is_Static: TRUE, wenn ALLE Chunks NoRef/Comment sind (reines Literal, keine Referenzen)
--   → statische Zuweisung (z. B. PopoverPanel-Titel "Passwort ändern"). Sonst = Formel.
--
-- Owner-Auflösung ausschließlich über ObjectCatalog (ScriptStep ist dort registriert,
-- Object_UUID = Step_UUID). Nicht auflösbare Anker → Owner_Type='unresolved' (D-3, nur
-- reporten). Seit AP-3 (CustomMenuItem im ObjectCatalog) lösen auch die Menü-Item-
-- Anker auf — unresolved ist im Normalbetrieb 0 (P6-Wächter wäre der Platz,
-- eine Regression zu melden).
-- Display_Text (lesbare, entity-DEKODIERTE Formel/Literal) wird HIER — gegen die
-- Master-DB, wo webbed geladen werden kann — vor-dekodiert. Der READ_ONLY-API-Server
-- kann webbed NICHT laden (siehe object_details_script_tokens.sql), darum muss die
-- Dekodierung in der Konvertierungs-Phase passieren, analog StepsForScripts.Inserted_Text.
LOAD webbed;

-- Seit Schema 1.22.0 ist die Anker-Auflösung in die Konvertierungs-Phase P4
-- gewandert (CalculationsCatalog, convert_xml_04_catalog.sql) — dort entsteht
-- eine Zeile pro Berechnungs-INSTANZ inkl. der strukturellen Slots ohne
-- DDR-Anker. v_calc_anchors bleibt als KOMPATIBILITÄTS-FASSADE bestehen:
-- dieselben Spalten, derselbe Zeilenbestand (nur DDR-verankerte Instanzen),
-- jetzt als billige materialisierte Projektion (bewusst TABLE, kein VIEW —
-- DuckDBs DROP … IF EXISTS scheitert am Typ-Wechsel Table↔View in beiden
-- Richtungen, eine In-Place-Umwandlung wäre nicht idempotent skriptbar).
-- Kind_Label bleibt hier die Single Source für Detail-Templates/Frontend.
DROP TABLE IF EXISTS v_calc_anchors;
CREATE TABLE v_calc_anchors AS
SELECT
    c.DDR_Calc_UUID                                                         AS Calc_UUID,
    c.Formula_Hash                                                          AS Calc_Hash,
    upper(regexp_extract(c.DDR_Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))        AS Anchor_UUID,
    -- Normalisierter Eigenschafts-Schlüssel:
    --   BARE    = CF-Body (leeres Suffix)
    --   NUMERIC = Script-Step-Parameter (Suffix = Calc-Position, evtl. mit Sub-Index 137_2)
    --   sonst   = die Eigenschaft (Hide, Condition_1, PopoverPanel, Install, Title, Name …)
    CASE
        WHEN c.Calc_Kind_Raw = ''                        THEN 'BARE'
        WHEN c.Calc_Kind_Raw ~ '^[0-9]+(_[0-9]+)*$'      THEN 'NUMERIC'
        ELSE c.Calc_Kind_Raw
    END                                                                     AS Calc_Kind,
    c.Calc_Kind_Raw,
    -- Kind_Label: menschenlesbare Eigenschaftsbezeichnung (Registry / Single Source).
    -- Von Detail-Templates (AP-2) und Frontend-Labels gelesen — hier zentral gepflegt.
    CASE
        WHEN c.Calc_Kind_Raw = ''                   THEN 'Function Body'
        WHEN c.Calc_Kind_Raw ~ '^[0-9]+(_[0-9]+)*$' THEN 'Step Parameter'
        -- Feld-Eingabeformel: FileMaker verwendet für sie denselben DDR-Suffix
        -- 'Hide' wie für die Ausblendungsformel (Schema 1.31.0) — die Rolle
        -- entscheidet, nicht der Rohschlüssel.
        WHEN c.Calc_Role = 'field_entry'            THEN 'Field Entry Condition'
        WHEN c.Calc_Kind_Raw = 'Hide'               THEN 'Hide Condition'
        WHEN c.Calc_Kind_Raw = 'Tooltip'            THEN 'Tooltip'
        WHEN c.Calc_Kind_Raw = 'Label'              THEN 'Calculated Label'
        WHEN c.Calc_Kind_Raw = 'action'             THEN 'Button Action'
        WHEN c.Calc_Kind_Raw = 'Portal'             THEN 'Portal Filter'
        WHEN c.Calc_Kind_Raw = 'WebViewer'          THEN 'Web Viewer URL'
        WHEN c.Calc_Kind_Raw = 'Placeholder'        THEN 'Placeholder Text'
        WHEN c.Calc_Kind_Raw = 'TabPanel'           THEN 'Tab Title'
        WHEN c.Calc_Kind_Raw = 'PopoverPanel'       THEN 'Popover Title'
        WHEN c.Calc_Kind_Raw = 'ButtonBar'          THEN 'Active Segment'
        WHEN c.Calc_Kind_Raw = 'Install'            THEN 'Install Condition'
        WHEN c.Calc_Kind_Raw = 'Title'              THEN 'Menu Title'
        WHEN c.Calc_Kind_Raw = 'Name'               THEN 'Calculated Name'
        WHEN c.Calc_Kind_Raw LIKE 'Condition\_%'      ESCAPE '\'
            THEN 'Conditional Formatting ' || regexp_extract(c.Calc_Kind_Raw, '_(\d+)$', 1)
        WHEN c.Calc_Kind_Raw LIKE 'ScriptTrigger\_%'  ESCAPE '\'
            THEN 'Script Trigger Parameter ' || regexp_extract(c.Calc_Kind_Raw, '_(\d+)$', 1)
        ELSE c.Calc_Kind_Raw
    END                                                                     AS Kind_Label,
    c.Owner_Type,
    -- Fassaden-Semantik wie zuvor: unaufgelöste Anker tragen Owner_UUID NULL
    -- (CalculationsCatalog speichert dort die Anker-UUID als Identitätsträger)
    CASE WHEN c.Owner_Type = 'unresolved' THEN NULL ELSE c.Owner_UUID END   AS Owner_UUID,
    c.Owner_Name,
    c.File_Name                                                             AS Owner_File,
    c.Is_Static,
    c.Chunk_Count,
    c.Ref_Count,
    c.Display_Text
FROM CalculationsCatalog c
WHERE c.DDR_Calc_UUID IS NOT NULL;

CREATE INDEX idx_calc_anchors_owner ON v_calc_anchors (Owner_UUID, Owner_File);
CREATE INDEX idx_calc_anchors_hash  ON v_calc_anchors (Calc_Hash);

-- --------------------------------------------
-- v_sql_field_usage — Felder, die eine SQL-Abfrage speisen
-- --------------------------------------------
-- Beantwortet „welche Felder speist eine ExecuteSQL-Abfrage (und in welchem Objekt)?".
-- Quelle ist CalculationSqlRefs (P4, Schema 1.42.0): Formel-Referenzen in
-- Namens-Wrappern (Resolution = reference) und Feldnamen im SQL-Text
-- (Resolution = name), mit Klausel. Wrapper werden dort über ihre Position im SQL
-- erkannt — keine lösungsspezifische Namensliste mehr (vorher sql_name_wrappers).
-- Calc_UUID = DDR-Anker der Berechnung (Kompatibilität zu v_calc_anchors),
-- Calculation_UUID = Berechnungs-Instanz.
DROP TABLE IF EXISTS sql_name_wrappers;
DROP VIEW IF EXISTS v_sql_field_usage;
CREATE VIEW v_sql_field_usage AS
SELECT DISTINCT
    c.Owner_Type, c.Owner_UUID, c.Owner_Name, c.File_Name AS Owner_File, va.Kind_Label,
    c.DDR_Calc_UUID AS Calc_UUID,
    f.Field_Name,
    r.Target_UUID AS Field_UUID,
    toc.TO_Name,
    c.Calculation_UUID,
    r.Clause,
    r.Resolution
FROM CalculationSqlRefs r
JOIN CalculationsCatalog c
  ON c.Calculation_UUID = r.Calculation_UUID AND c.File_Name = r.File_Name
JOIN FieldsForTables f
  ON f.Field_UUID = r.Target_UUID AND f.File_Name = r.Target_File
LEFT JOIN TableOccurrenceCatalog toc
  ON toc.TO_UUID = r.TO_UUID AND toc.File_Name = r.File_Name
LEFT JOIN v_calc_anchors va
  ON va.Calc_UUID = c.DDR_Calc_UUID AND va.Owner_File = c.File_Name
WHERE r.Target_Type = 'Field';

-- --------------------------------------------
-- v_table_occurrence_usage — Fundstellen je Table Occurrence (MATERIALIZED)
-- --------------------------------------------
-- Die EINE Definition von „TO wird genutzt" (Dashboard Table Occurrence Usage, Regel
-- unused_table_occurrence, Referenzen-Tab der TO). ObjectLinks allein reicht nicht:
-- eine Feldreferenz TO::Feld (Formel, Script-Schritt, Layout-Feld) erzeugt nur eine
-- Kante auf das FELD; die TO steht ausschließlich in den P2-Auszügen. Diese Tabelle
-- führt beides zusammen, eine Zeile je (TO, nutzendes Objekt, Kategorie, Rolle),
-- Ref_Count = Zahl der Einzelreferenzen.
--
-- TO-Auflösung immer datei-skopiert und — wo die Quelle einen ID-Begleiter trägt —
-- über (File_Name, TO_ID): heilungs- und klon-sicher (geheilte TO-Zwillinge teilen die
-- Original-UUID im XML). Kanten über (Target_UUID, Target_File).
-- Is_Edge = TRUE: die Fundstelle existiert auch als ObjectLinks-Kante (Referenzen-Tab
-- zeigt sie schon über den Standardpfad).
-- Kategorie relationship_cascade: beide Seiten einer Beziehung mit Löschweitergabe —
-- konservativ als Nutzung gezählt (das Löschen wirkt über die Beziehung, auch wenn
-- nichts die TO referenziert).
-- Kategorie sql: Tabelle einer ExecuteSQL-Anweisung (FROM/JOIN), auch wenn sie nur
-- als Name im SQL-Text steht (Rolle = Klausel:Resolution, z. B. from:name).
-- Kategorie calculation_text: nur in Dateien OHNE DDR-Info — dort fehlen die
-- aufgelösten Formel-Referenzen; ersatzweise zählt jedes TO::Feld im Formeltext
-- (CalculationsCatalog.Formula_Text liegt auch ohne DDR-Info vor). Treffer = TO-Name
-- der Datei direkt vor '::', links begrenzt durch Textanfang oder ein Zeichen, das
-- kein Namenszeichen ist (Buchstabe, Ziffer, '_', '.'). Abgeglichen an Dateien MIT
-- DDR-Info: rund 95 % der (Datei, TO)-Paare der DDR-Referenzen werden gefunden.
-- Fehltreffer (Kommentare, Strings, ein kürzerer TO-Name als Endstück eines längeren)
-- zählen als Nutzung — die sichere Richtung. Unsichtbar bleiben unqualifizierte
-- Feldnamen (sie meinen die Kontext-TO der Formel) und Auswertungskontexte.
-- Grenzen: Formel-Referenzen und Auswertungskontexte vollständig nur mit DDR-Info;
-- dynamische Referenzen (GetField, Evaluate, SQL-Text aus Variablen anderer Schritte)
-- sind unsichtbar.
DROP TABLE IF EXISTS v_table_occurrence_usage;
CREATE TABLE v_table_occurrence_usage AS
WITH tos AS (
    SELECT TO_UUID, TO_ID, TO_Name, File_Name FROM TableOccurrenceCatalog
),
-- Formeln der Dateien ohne DDR-Info, die überhaupt eine Feldreferenz TO::Feld tragen
-- können. Formeln in Script-Schritten zählen für das Script (wie script_step und die
-- DDR-Referenzen der Kategorie calculation).
calc_text AS (
    SELECT c.File_Name, c.Calc_Role, c.Formula_Text,
           CASE WHEN c.Owner_Type = 'ScriptStep' THEN COALESCE(st.Script_UUID, c.Owner_UUID) ELSE c.Owner_UUID END AS User_UUID,
           CASE WHEN c.Owner_Type = 'ScriptStep' AND st.Script_UUID IS NOT NULL THEN 'Script' ELSE c.Owner_Type END AS User_Type
    FROM CalculationsCatalog c
    JOIN FilesCatalog f ON f.File_Name = c.File_Name AND NOT COALESCE(f.Has_DDR_INFO, FALSE)
    LEFT JOIN (
        SELECT Step_UUID, File_Name, any_value(Script_UUID) AS Script_UUID
        FROM StepsForScripts GROUP BY ALL
    ) st ON c.Owner_Type = 'ScriptStep' AND st.Step_UUID = c.Owner_UUID AND st.File_Name = c.File_Name
    WHERE contains(c.Formula_Text, '::')
      AND COALESCE(c.Is_Enabled, TRUE)
),
calc_text_hits AS (
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, ct.Calc_Role, ct.User_UUID, ct.User_Type,
           len(regexp_extract_all(ct.Formula_Text,
               '(?:^|[^\p{L}\p{N}_.])' || regexp_escape(t.TO_Name) || '::')) AS n
    FROM calc_text ct
    JOIN tos t ON t.File_Name = ct.File_Name
              AND contains(ct.Formula_Text, t.TO_Name || '::')
),
refs AS (
    -- Kanten auf die TO (zählende Rollen der Registry)
    SELECT t.TO_UUID, t.TO_Name, t.File_Name,
           CASE ol.Link_Role
               WHEN 'context_table'       THEN 'layout_context'
               WHEN 'portal_context'      THEN 'portal'
               WHEN 'navigates_to_to'     THEN 'navigation'
               WHEN 'left_table'          THEN 'relationship'
               WHEN 'right_table'         THEN 'relationship'
               WHEN 'lookup_relationship' THEN 'lookup'
               WHEN 'lookup_context'      THEN 'lookup_context'
               WHEN 'source_table'        THEN 'value_list'
               WHEN 'related_values_from' THEN 'value_list_related'
               ELSE ol.Link_Role
           END AS Category,
           ol.Link_Role AS Role,
           ol.Source_UUID AS User_UUID, ol.Source_Type AS User_Type, ol.Source_File AS User_File,
           TRUE AS Is_Edge
    FROM ObjectLinks ol
    JOIN LinkRoleRegistry r ON r.Link_Role = ol.Link_Role AND r.Counts_For_Where_Used
    JOIN tos t ON t.TO_UUID = ol.Target_UUID AND t.File_Name = ol.Target_File
    WHERE ol.Target_Type = 'TableOccurrence'
      AND ol.Link_Type = 'operational'
    UNION ALL
    -- Löschweitergabe (beide Seiten der Beziehung, eine Zeile je Beziehung und Seite)
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'relationship_cascade',
           CASE WHEN rc.Side_Delete THEN 'cascade_delete_target' ELSE 'cascade_delete_source' END,
           rc.Rel_UUID, 'Relationship', rc.File_Name, FALSE
    FROM (
        SELECT DISTINCT r.Rel_UUID, r.File_Name, s.TO_ID, s.Side_Delete
        FROM RelationshipCatalog r
        CROSS JOIN LATERAL (VALUES (r.Left_TO_ID,  r.Left_Delete),
                                   (r.Right_TO_ID, r.Right_Delete)) s(TO_ID, Side_Delete)
        WHERE r.Left_Delete OR r.Right_Delete
    ) rc
    JOIN tos t ON t.File_Name = rc.File_Name AND t.TO_ID = rc.TO_ID
    UNION ALL
    -- Feldreferenzen in Formeln (Feld-, Script-, CF-, Layout-Formeln)
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'calculation',
           COALESCE(x.Subrole, lower(x.Source_Type)),
           x.Source_UUID, x.Source_Type, x.File_Name, FALSE
    FROM XMLCalcReferences x
    JOIN tos t ON t.File_Name = x.File_Name AND t.TO_ID = x.TO_Ref_ID
    WHERE x.Ref_Type = 'field'
    UNION ALL
    -- Feldreferenzen in Script-Schritten (Set Field, Go to Field, Sort, …)
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'script_step',
           'step ' || (TRY_CAST(s.Step_Index AS BIGINT) + 1)::VARCHAR,  -- Step_Index ist hier VARCHAR, 0-basiert
           s.Script_UUID, 'Script', s.File_Name, FALSE
    FROM XMLStepReferences s
    JOIN tos t ON t.File_Name = s.File_Name AND t.TO_ID = s.TO_Ref_ID
    WHERE s.Ref_Type = 'field'
    UNION ALL
    -- Layout-Felder (Feldobjekte, Merge-Felder, button-eingebettete Feld-Schritte)
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'layout_field',
           l.Ref_Type || COALESCE(':' || l.Ref_Source, ''),
           l.Object_UUID, 'LayoutObject', l.File_Name, FALSE
    FROM XMLLayoutReferences l
    JOIN tos t ON t.File_Name = l.File_Name AND t.TO_ID = l.TO_Ref_ID
    WHERE l.Ref_Type IN ('field', 'field_step')
    UNION ALL
    -- Spalten der Tabellenansicht (FileMaker 26)
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'table_view', 'column',
           c.L_UUID, 'Layout', c.File_Name, FALSE
    FROM LayoutTableViewColumns c
    JOIN tos t ON t.File_Name = c.File_Name AND t.TO_ID = c.TO_ID
    UNION ALL
    -- Break-Feld eines Layout-Teils (Zwischenergebnis nach Feld)
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'layout_part', 'break_field',
           lay.L_UUID, 'Layout', p.File_Name, FALSE
    FROM LayoutParts p
    JOIN tos t ON t.File_Name = p.File_Name AND t.TO_UUID = p.Break_TO_UUID
    LEFT JOIN Layouts lay ON lay.File_Name = p.File_Name AND lay.L_ID = p.Layout_ID
    UNION ALL
    -- Kontext beim Datensatzzugriff eines Berechtigungssatzes
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'security', 'record_access_' || lower(COALESCE(a.Operation, '')),
           a.PrivilegeSet_UUID, 'PrivilegeSet', a.File_Name, FALSE
    FROM PrivilegeSetRecordAccess a
    JOIN tos t ON t.File_Name = a.File_Name AND t.TO_UUID = a.Context_TO_UUID
    UNION ALL
    -- Zweites Feld einer Werteliste
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'value_list', 'secondary_field',
           o.VL_UUID, 'ValueList', o.File_Name, FALSE
    FROM OptionsForValueLists o
    JOIN tos t ON t.File_Name = o.File_Name AND t.TO_ID = o.Secondary_TO_ID
    UNION ALL
    -- Auswertungskontext einer Formel (Startpunkt der Pfade zu ihren TO::Feld-Zielen)
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'calc_context', COALESCE(c.Calc_Role, 'unresolved'),
           c.Owner_UUID, c.Owner_Type, d.File_Name, FALSE
    FROM DDR_ChunkListContexts d
    JOIN tos t ON t.File_Name = d.File_Name AND t.TO_ID = d.Context_TO_ID
    LEFT JOIN CalculationsCatalog c ON c.DDR_Calc_UUID = d.Calc_UUID AND c.File_Name = d.File_Name
    WHERE COALESCE(c.Is_Enabled, TRUE)
    UNION ALL
    -- Tabellen einer ExecuteSQL-Anweisung (FROM/JOIN), als Formel-Referenz oder als
    -- Name im SQL-Text (CalculationSqlRefs); Schritt-Formeln zählen für das Script
    SELECT t.TO_UUID, t.TO_Name, t.File_Name, 'sql', r.Clause || ':' || r.Resolution,
           CASE WHEN c.Owner_Type = 'ScriptStep' THEN COALESCE(st.Script_UUID, c.Owner_UUID) ELSE c.Owner_UUID END,
           CASE WHEN c.Owner_Type = 'ScriptStep' AND st.Script_UUID IS NOT NULL THEN 'Script' ELSE c.Owner_Type END,
           c.File_Name, FALSE
    FROM CalculationSqlRefs r
    JOIN CalculationsCatalog c ON c.Calculation_UUID = r.Calculation_UUID AND c.File_Name = r.File_Name
    JOIN tos t ON t.TO_UUID = r.Target_UUID AND t.File_Name = r.Target_File
    LEFT JOIN (
        SELECT Step_UUID, File_Name, any_value(Script_UUID) AS Script_UUID
        FROM StepsForScripts GROUP BY ALL
    ) st ON st.Step_UUID = c.Owner_UUID AND st.File_Name = c.File_Name
    WHERE r.Target_Type = 'TableOccurrence'
      AND COALESCE(c.Is_Enabled, TRUE)
    UNION ALL
    -- Datei ohne DDR-Info: TO::Feld im Formeltext, eine Zeile je Fundstelle
    SELECT h.TO_UUID, h.TO_Name, h.File_Name, 'calculation_text',
           COALESCE(h.Calc_Role, lower(h.User_Type)),
           h.User_UUID, h.User_Type, h.File_Name, FALSE
    FROM calc_text_hits h, range(h.n) r(i)
    WHERE h.n > 0
),
agg AS (
    SELECT TO_UUID, TO_Name, File_Name, Category, Role, User_UUID, User_Type, User_File,
           COUNT(*) AS Ref_Count, bool_or(Is_Edge) AS Is_Edge
    FROM refs
    GROUP BY ALL
),
names AS (
    SELECT Object_UUID, File_Name, Object_Type, any_value(Object_Name) AS Object_Name
    FROM ObjectCatalog
    GROUP BY ALL
),
containers AS (
    -- LayoutObject → Layout (Navigation im Referenzen-Tab und Dashboard)
    SELECT Source_UUID, Source_File, any_value(Target_UUID) AS Container_UUID
    FROM ObjectLinks
    WHERE Link_Role = 'parent_layout' AND Source_Type = 'LayoutObject' AND Target_Type = 'Layout'
    GROUP BY ALL
)
SELECT a.TO_UUID, a.TO_Name, a.File_Name,
       a.Category, a.Role,
       a.User_UUID, a.User_Type, n.Object_Name AS User_Name, a.User_File,
       cn.Container_UUID,
       CASE WHEN cn.Container_UUID IS NOT NULL THEN 'Layout' END AS Container_Type,
       cl.Object_Name AS Container_Name,
       a.Ref_Count, a.Is_Edge
FROM agg a
LEFT JOIN names n ON n.Object_UUID = a.User_UUID AND n.File_Name = a.User_File AND n.Object_Type = a.User_Type
LEFT JOIN containers cn ON a.User_Type = 'LayoutObject'
                       AND cn.Source_UUID = a.User_UUID AND cn.Source_File = a.User_File
LEFT JOIN names cl ON cl.Object_UUID = cn.Container_UUID AND cl.File_Name = a.User_File AND cl.Object_Type = 'Layout';

CREATE INDEX idx_to_usage_to   ON v_table_occurrence_usage (TO_UUID, File_Name);
CREATE INDEX idx_to_usage_user ON v_table_occurrence_usage (User_UUID, User_File);

-- --------------------------------------------
-- v_table_occurrence_class — Nutzungsklasse je Table Occurrence (MATERIALIZED)
-- --------------------------------------------
-- Eine Zeile je TO aus TableOccurrenceCatalog. Usage_Class:
--   unused              keine Fundstelle, keine Beziehung
--   used                mindestens eine Fundstelle außerhalb der Kategorie relationship
--   relationship_bridge nur Beziehungen, aber Zwischenglied (Reason 'path'): liegt auf
--                       dem Pfad zwischen zwei genutzten TOs — typisch die Zwischen-TO
--                       einer n:m-Beziehung —, oder nur über eine Löschweitergabe
--                       genutzt (Reason 'cascade_delete')
--   dead_branch         nur Beziehungen, genau ein Ast enthält eine genutzte TO: hängt
--                       am genutzten Teil, dahinter wird nichts genutzt
--   dead_island         nur Beziehungen, die ganze TO-Gruppe hat keine genutzte TO
-- Pfadanalyse: FileMaker erlaubt im Beziehungsgraphen keine Zyklen, jede TO-Gruppe ist
-- ein Baum → zwischen zwei TOs gibt es genau einen Pfad. Eine TO ohne eigene Nutzung
-- ist genau dann nötig, wenn ≥ 2 ihrer Äste (Teilbäume ohne die TO) eine genutzte TO
-- enthalten. Die Menge der genutzten TOs enthält jeden statisch bekannten Startpunkt
-- eines Pfads (Layout-/Portal-Kontext, Auswertungskontext calc_context, Lookup- und
-- Wertelisten-Start-TO); Script-Schritte laufen im Kontext eines Layouts, dessen TO
-- ebenfalls genutzt ist. Konservativ: ein Zwischenglied gilt als nötig, auch wenn
-- keine konkrete Referenz über diesen Pfad läuft.
-- dead_*: Dead_Group_ID/_Size = zusammenhängender toter Teilbaum (gemeinsam
-- aufräumbar), Anchor_TO_* = die nicht tote TO, an der er hängt (dead_island: NULL).
-- Text_Ref_Count: Fundstellen der Kategorie calculation_text (Formeltext, nur Dateien
-- ohne DDR-Info).
-- Low_Confidence: Datei ohne DDR-Info. Formel-Referenzen stammen dort nur aus dem
-- Formeltext, Auswertungskontexte fehlen → unused / dead_branch / dead_island sind
-- ungeprüft (eine Nutzung kann unsichtbar sein); used und relationship_bridge beruhen
-- auf gefundenen Fundstellen und gelten.
DROP TABLE IF EXISTS v_table_occurrence_class;
CREATE TABLE v_table_occurrence_class AS
WITH RECURSIVE
tos AS (
    SELECT TO_UUID, TO_Name, BT_Name, File_Name FROM TableOccurrenceCatalog
),
agg AS (
    SELECT TO_UUID, File_Name,
           SUM(Ref_Count)                                                       AS Ref_Count,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category <> 'relationship'), 0) AS Usage_Ref_Count,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category NOT IN ('relationship', 'relationship_cascade')), 0) AS Direct_Ref_Count,
           COUNT(DISTINCT User_UUID) FILTER (WHERE Category <> 'relationship')  AS User_Count,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category = 'relationship'), 0) AS Relationship_Count,
           COALESCE(SUM(Ref_Count) FILTER (WHERE Category = 'calculation_text'), 0) AS Text_Ref_Count
    FROM v_table_occurrence_usage
    GROUP BY ALL
),
used AS (
    SELECT TO_UUID, File_Name FROM agg WHERE Usage_Ref_Count > 0
),
rel AS (
    SELECT DISTINCT File_Name AS f, Left_TO_UUID AS a, Right_TO_UUID AS b
    FROM RelationshipCatalog
    WHERE Left_TO_UUID IS NOT NULL AND Right_TO_UUID IS NOT NULL AND Left_TO_UUID <> Right_TO_UUID
),
adj AS (
    SELECT f, a AS x, b AS y FROM rel
    UNION
    SELECT f, b, a FROM rel
),
cand AS (
    SELECT DISTINCT a.f, a.x FROM adj a
    WHERE NOT EXISTS (SELECT 1 FROM used u WHERE u.TO_UUID = a.x AND u.File_Name = a.f)
),
-- Lauf je Kandidat und Nachbar (Ast), ohne die TO selbst zu betreten; Baum →
-- „nicht zurück zum Vorgänger" genügt, die Tiefenschranke sichert gegen Zyklen.
walk(f, x, branch, prev, cur, depth) AS (
    SELECT c.f, c.x, a.y, c.x, a.y, 1
    FROM cand c JOIN adj a ON a.f = c.f AND a.x = c.x
    UNION ALL
    SELECT w.f, w.x, w.branch, w.cur, a.y, w.depth + 1
    FROM walk w JOIN adj a ON a.f = w.f AND a.x = w.cur AND a.y <> w.prev
    WHERE w.depth < 64
),
branches AS (
    SELECT w.f, w.x, w.branch, bool_or(u.TO_UUID IS NOT NULL) AS has_used
    FROM walk w
    LEFT JOIN used u ON u.TO_UUID = w.cur AND u.File_Name = w.f
    GROUP BY ALL
),
cand_cls AS (
    SELECT f, x, COUNT(*) FILTER (WHERE has_used) AS Used_Branches
    FROM branches GROUP BY ALL
),
dead AS (
    SELECT f, x FROM cand_cls WHERE Used_Branches < 2
),
-- Zusammenhängende tote Teilbäume: Lauf nur über tote TOs.
dwalk(f, x, prev, cur, depth) AS (
    SELECT f, x, x, x, 0 FROM dead
    UNION ALL
    SELECT w.f, w.x, w.cur, a.y, w.depth + 1
    FROM dwalk w
    JOIN adj a ON a.f = w.f AND a.x = w.cur AND a.y <> w.prev
    JOIN dead d ON d.f = a.f AND d.x = a.y
    WHERE w.depth < 64
),
dgroup AS (
    SELECT f, x, MIN(cur) AS Dead_Group_ID, COUNT(DISTINCT cur) AS Dead_Group_Size
    FROM dwalk GROUP BY ALL
),
danchor AS (
    -- Höchstens eine nicht tote Nachbar-TO je totem Teilbaum (sonst läge eine seiner
    -- TOs zwischen zwei genutzten → Zwischenglied).
    SELECT g.f, g.Dead_Group_ID, any_value(a.y) AS Anchor_TO_UUID
    FROM dgroup g
    JOIN adj a ON a.f = g.f AND a.x = g.x
    WHERE NOT EXISTS (SELECT 1 FROM dead d WHERE d.f = a.f AND d.x = a.y)
    GROUP BY ALL
)
SELECT t.TO_UUID, t.TO_Name, t.BT_Name, t.File_Name,
       CASE
           WHEN COALESCE(ag.Ref_Count, 0) = 0                           THEN 'unused'
           WHEN ag.Usage_Ref_Count > 0 AND ag.Direct_Ref_Count = 0      THEN 'relationship_bridge'
           WHEN ag.Usage_Ref_Count > 0                                  THEN 'used'
           WHEN cc.Used_Branches >= 2                                   THEN 'relationship_bridge'
           WHEN cc.Used_Branches = 1                                    THEN 'dead_branch'
           ELSE 'dead_island'
       END AS Usage_Class,
       CASE
           WHEN ag.Usage_Ref_Count > 0 AND ag.Direct_Ref_Count = 0      THEN 'cascade_delete'
           WHEN COALESCE(ag.Usage_Ref_Count, 0) = 0 AND cc.Used_Branches >= 2 THEN 'path'
       END AS Reason,
       COALESCE(ag.Ref_Count, 0)          AS Ref_Count,
       COALESCE(ag.Usage_Ref_Count, 0)    AS Usage_Ref_Count,
       COALESCE(ag.User_Count, 0)         AS User_Count,
       COALESCE(ag.Relationship_Count, 0) AS Relationship_Count,
       COALESCE(ag.Text_Ref_Count, 0)     AS Text_Ref_Count,
       cc.Used_Branches,
       g.Dead_Group_ID,
       g.Dead_Group_Size,
       an.Anchor_TO_UUID,
       ta.TO_Name                         AS Anchor_TO_Name,
       NOT COALESCE(fc.Has_DDR_INFO, FALSE) AS Low_Confidence
FROM tos t
LEFT JOIN agg ag      ON ag.TO_UUID = t.TO_UUID AND ag.File_Name = t.File_Name
LEFT JOIN cand_cls cc ON cc.x = t.TO_UUID AND cc.f = t.File_Name
LEFT JOIN dgroup g    ON g.x = t.TO_UUID AND g.f = t.File_Name
LEFT JOIN danchor an  ON an.f = g.f AND an.Dead_Group_ID = g.Dead_Group_ID
LEFT JOIN tos ta      ON ta.TO_UUID = an.Anchor_TO_UUID AND ta.File_Name = an.f
LEFT JOIN FilesCatalog fc ON fc.File_Name = t.File_Name;

CREATE INDEX idx_to_class_to ON v_table_occurrence_class (TO_UUID, File_Name);

-- --------------------------------------------
-- v_object_usage — Nutzung je Objekt, typübergreifend (MATERIALIZED)
-- --------------------------------------------
-- Die EINE Definition von „Objekt wird genutzt" für die Regeln unused_* (Test
-- unused-code), das Dashboard Object Usage und die Spalte „Nutzung" der Suche.
-- Eine Zeile je Objekt der Typen Field, Script, Layout, CustomFunction, ValueList,
-- BaseTable, ExternalDataSource, PrivilegeSet, TableOccurrence, Relationship.
--
-- Nutzung = eingehende ObjectLinks-Kante (Target_UUID + Target_File) mit einer Rolle,
-- die LinkRoleRegistry als Verwendung führt (Counts_For_Where_Used). Ausnahmen
-- stehen in usage_role_override: hat ein Typ dort Zeilen, zählen NUR diese Rollen.
--   BaseTable  nur base_table (TO → Basistabelle); parent_table (Feld → Basistabelle)
--              trägt das Registry-Flag, ist fachlich aber Containment — sonst wäre jede
--              Basistabelle mit Feldern „genutzt".
-- Restriction-Rollen (restricts_*) und Containment (parent_*, has_calculation) zählen
-- nie. trigger_script (ScriptTrigger → Script) trägt das Flag nicht; dieselbe
-- Auslösung kommt als triggers_script vom Trigger-Besitzer.
-- Sammelkante Layout → Feld (displays_field ohne Subrolle, P4 „aggregiert"): je
-- (Layout, Feld) eine Kante NEBEN den granularen Layout-Objekt-Kanten — sie existiert,
-- damit der Referenzen-Tab eines Layouts (ausgehend) seine Felder listet. Jede Sammelkante
-- hat ein Gegenstück auf Objekt-Ebene; mitgezählt würde sie jede Platzierung doppelt als
-- Referenz führen. Sie fehlt deshalb in edges — Usage_Owners und Usage_Class ändert das
-- nicht (das Layout ist über seine Objekte ohnehin Owner), nur Usage_Refs/Usage_Users.
-- Die Tabellenansicht-Spalte (Subrolle table_view_column) bleibt eine eigene Referenz.
-- TableOccurrence: Zählwerte und Klasse aus v_table_occurrence_usage /
-- v_table_occurrence_class (TO::Feld-Referenzen, Kontexte, Pfadanalyse).
-- Relationship: ohne eigene Nutzungskante und ohne Zählwerte; die Klasse folgt aus
-- den beiden TOs (eine Beziehung mit einer toten TO ist tot).
--
-- Zählwerte (nur Kanten der Nutzungsdefinition):
--   Usage_Owners  nutzende Container: ein Layout-Objekt oder Layout-Teil zählt als sein
--                 Layout (Script-Schritte sind schon Script-Kanten) — die Kennzahl
--                 „Nutzung" (an wie vielen Stellen eine Änderung nachzuziehen ist)
--   Usage_Users   verschiedene Quellobjekte
--   Usage_Refs    Kanten = Referenzen (Zeilen im Referenzen-Tab, eingehend, ×N summiert)
--   Usage_Roles   Liste der Rollen, Usage_Files = Zahl der Quelldateien,
--   Cross_File    mindestens eine Nutzung aus einer anderen Datei
-- Marker:
--   Entry_Point   Script im Scripts-Menü (ScriptCatalog.Is_Hidden = FALSE) bzw. Layout
--                 im Layout-Menü (Layouts.Is_Hidden = FALSE) — vom Anwender startbar,
--                 auch ohne Referenz
--   Key_Field     Feld ist Schlüssel einer Beziehung (left_field / right_field)
--   Low_Confidence  Datei ohne DDR-Info: Formelreferenzen fehlen, „unused" ist dort
--                 ungeprüft (die Regeln melden …_unverified). Nur für Typen, deren
--                 Nutzung (auch) aus Formeln kommt: Field, Script, Layout, CustomFunction,
--                 ValueList, dazu TableOccurrence (aus v_table_occurrence_class) und
--                 Relationship; BaseTable, ExternalDataSource, PrivilegeSet sind strukturell
--                 verknüpft (immer FALSE)
-- Usage_Class (ohne Schwellwert — „selten" rechnen Dashboard und Suche):
--   used         mindestens eine Nutzung
--   entry_point  keine Nutzung, aber Entry_Point
--   builtin      keine Nutzung, eingebaute Berechtigung (PrivilegeSet_ID 1–3, in jeder
--                Datei vorhanden und nicht löschbar)
--   unused       keine Nutzung
--   TableOccurrence: die Klassen aus v_table_occurrence_class (unused / used /
--                relationship_bridge / dead_branch / dead_island)
--   Relationship: dead_island bzw. dead_branch, wenn eine ihrer TOs so klassifiziert
--                ist (dead_island vor dead_branch), sonst used
-- Grenzen wie bei jeder statischen Analyse: dynamische Referenzen (Perform Script by
-- name, GetField, Evaluate, ExecuteSQL-Text), Server-Zeitpläne, Data API/OData und
-- nicht importierte Dateien sind unsichtbar.
DROP TABLE IF EXISTS v_object_usage;
CREATE TABLE v_object_usage AS
WITH
usage_role_override(Object_Type, Link_Role) AS (
    VALUES ('BaseTable', 'base_table')
),
objs AS (
    SELECT Object_UUID, Object_Type, Object_Name, File_Name
    FROM ObjectCatalog
    WHERE Object_Type IN ('Field', 'Script', 'Layout', 'CustomFunction', 'ValueList',
                          'BaseTable', 'ExternalDataSource', 'PrivilegeSet')
),
edges AS (
    SELECT o.Object_UUID, o.File_Name, ol.Link_Role, ol.Source_UUID, ol.Source_Type, ol.Source_File
    FROM ObjectLinks ol
    JOIN objs o ON o.Object_UUID = ol.Target_UUID AND o.File_Name = ol.Target_File
    LEFT JOIN LinkRoleRegistry r ON r.Link_Role = ol.Link_Role
    WHERE CASE WHEN o.Object_Type IN (SELECT Object_Type FROM usage_role_override)
               THEN EXISTS (SELECT 1 FROM usage_role_override x
                            WHERE x.Object_Type = o.Object_Type AND x.Link_Role = ol.Link_Role)
               ELSE COALESCE(r.Counts_For_Where_Used, FALSE)
          END
      -- Sammelkante Layout → Feld: Duplikat der Layout-Objekt-Kanten (s. Kopf)
      AND NOT (ol.Source_Type = 'Layout' AND ol.Link_Role = 'displays_field'
               AND ol.Link_Subrole IS NULL)
),
containers AS (
    -- Layout-Objekt / Layout-Teil → Layout
    SELECT Source_UUID, Source_File, any_value(Target_UUID) AS Container_UUID
    FROM ObjectLinks
    WHERE Link_Role = 'parent_layout' AND Source_Type IN ('LayoutObject', 'LayoutPart')
      AND Target_Type = 'Layout'
    GROUP BY ALL
),
agg AS (
    SELECT e.Object_UUID, e.File_Name,
           COUNT(DISTINCT (COALESCE(c.Container_UUID, e.Source_UUID), e.Source_File)) AS Usage_Owners,
           COUNT(DISTINCT (e.Source_UUID, e.Source_File))                             AS Usage_Users,
           COUNT(*)                                                                   AS Usage_Refs,
           list(DISTINCT e.Link_Role ORDER BY e.Link_Role)                            AS Usage_Roles,
           COUNT(DISTINCT e.Source_File)                                              AS Usage_Files,
           bool_or(e.Source_File IS DISTINCT FROM e.File_Name)                        AS Cross_File,
           bool_or(e.Link_Role IN ('left_field', 'right_field'))                      AS Key_Field
    FROM edges e
    LEFT JOIN containers c ON c.Source_UUID = e.Source_UUID AND c.Source_File = e.Source_File
                          AND e.Source_Type IN ('LayoutObject', 'LayoutPart')
    GROUP BY ALL
),
generic AS (
    SELECT o.Object_UUID, o.Object_Type, o.Object_Name, o.File_Name,
           COALESCE(a.Usage_Owners, 0) AS Usage_Owners,
           COALESCE(a.Usage_Users, 0)  AS Usage_Users,
           COALESCE(a.Usage_Refs, 0)   AS Usage_Refs,
           COALESCE(a.Usage_Roles, [])::VARCHAR[] AS Usage_Roles,
           COALESCE(a.Usage_Files, 0)  AS Usage_Files,
           COALESCE(a.Cross_File, FALSE) AS Cross_File,
           (o.Object_Type = 'Script' AND EXISTS (
                SELECT 1 FROM ScriptCatalog s
                WHERE s.Script_UUID = o.Object_UUID AND s.File_Name = o.File_Name AND s.Is_Hidden = FALSE))
        OR (o.Object_Type = 'Layout' AND EXISTS (
                SELECT 1 FROM Layouts l
                WHERE l.L_UUID = o.Object_UUID AND l.File_Name = o.File_Name AND l.Is_Hidden = FALSE))
                                       AS Entry_Point,
           o.Object_Type = 'PrivilegeSet' AND EXISTS (
                SELECT 1 FROM PrivilegeSetsCatalog p
                WHERE p.PrivilegeSet_UUID = o.Object_UUID AND p.File_Name = o.File_Name
                  AND p.PrivilegeSet_ID <= 3)  AS Is_Builtin,
           COALESCE(a.Key_Field, FALSE) AS Key_Field
    FROM objs o
    LEFT JOIN agg a ON a.Object_UUID = o.Object_UUID AND a.File_Name = o.File_Name
),
to_agg AS (
    SELECT TO_UUID, File_Name,
           COUNT(DISTINCT (COALESCE(Container_UUID, User_UUID), User_File)) AS Usage_Owners,
           list(DISTINCT Role ORDER BY Role)                                AS Usage_Roles,
           COUNT(DISTINCT User_File)                                        AS Usage_Files,
           bool_or(User_File IS DISTINCT FROM File_Name)                    AS Cross_File
    FROM v_table_occurrence_usage
    WHERE Category <> 'relationship'
    GROUP BY ALL
),
rel_tos AS (
    SELECT DISTINCT Rel_UUID, File_Name, Left_TO_UUID AS TO_UUID FROM RelationshipCatalog
    UNION
    SELECT DISTINCT Rel_UUID, File_Name, Right_TO_UUID FROM RelationshipCatalog
),
rel_class AS (
    SELECT r.Rel_UUID, r.File_Name,
           CASE WHEN bool_or(c.Usage_Class = 'dead_island') THEN 'dead_island'
                WHEN bool_or(c.Usage_Class = 'dead_branch') THEN 'dead_branch'
                ELSE 'used' END AS Usage_Class
    FROM rel_tos r
    LEFT JOIN v_table_occurrence_class c ON c.TO_UUID = r.TO_UUID AND c.File_Name = r.File_Name
    GROUP BY ALL
)
SELECT g.Object_UUID, g.Object_Type, g.Object_Name, g.File_Name,
       g.Usage_Owners, g.Usage_Users, g.Usage_Refs, g.Usage_Roles, g.Usage_Files, g.Cross_File,
       g.Entry_Point, g.Key_Field,
       -- Only types whose usage edges come (partly) from formulas: base tables, data
       -- sources and privilege sets are linked structurally, DDR info changes nothing.
       g.Object_Type IN ('Field', 'Script', 'Layout', 'CustomFunction', 'ValueList')
           AND NOT COALESCE(fc.Has_DDR_INFO, FALSE) AS Low_Confidence,
       CASE WHEN g.Usage_Refs > 0 THEN 'used'
            WHEN g.Is_Builtin     THEN 'builtin'
            WHEN g.Entry_Point    THEN 'entry_point'
            ELSE 'unused' END AS Usage_Class
FROM generic g
LEFT JOIN FilesCatalog fc ON fc.File_Name = g.File_Name
UNION ALL
SELECT o.Object_UUID, o.Object_Type, o.Object_Name, o.File_Name,
       COALESCE(t.Usage_Owners, 0), c.User_Count, c.Usage_Ref_Count::BIGINT,
       COALESCE(t.Usage_Roles, [])::VARCHAR[], COALESCE(t.Usage_Files, 0), COALESCE(t.Cross_File, FALSE),
       FALSE, FALSE,
       c.Low_Confidence,
       c.Usage_Class
FROM ObjectCatalog o
JOIN v_table_occurrence_class c ON c.TO_UUID = o.Object_UUID AND c.File_Name = o.File_Name
LEFT JOIN to_agg t ON t.TO_UUID = o.Object_UUID AND t.File_Name = o.File_Name
WHERE o.Object_Type = 'TableOccurrence'
UNION ALL
SELECT o.Object_UUID, o.Object_Type, o.Object_Name, o.File_Name,
       NULL, NULL, NULL, NULL, NULL, NULL,
       FALSE, FALSE,
       NOT COALESCE(fc.Has_DDR_INFO, FALSE),
       COALESCE(rc.Usage_Class, 'used')
FROM ObjectCatalog o
LEFT JOIN rel_class rc ON rc.Rel_UUID = o.Object_UUID AND rc.File_Name = o.File_Name
LEFT JOIN FilesCatalog fc ON fc.File_Name = o.File_Name
WHERE o.Object_Type = 'Relationship';

CREATE INDEX idx_object_usage_obj ON v_object_usage (Object_UUID, File_Name);


-- --------------------------------------------
-- v_layout_object_font — effektive Schrift je Layout-Objekt (MATERIALIZED, Schema 1.44.0)
-- --------------------------------------------
-- Eine Zeile je Layout-Objekt, das selbst Text zeigt (LayoutObjectCssType.Has_Text;
-- Segment-Tasten und Register-Panels über den Typ des Containers). Je Eigenschaft
-- (Familie, Größe, Gewicht, Schnitt) gilt der erste gesetzte Wert der Kaskade —
-- in FileMaker 22 und 26 geprüft:
--   local        eigene Regel self[.<stil>]:normal .self (LayoutObjectStyles.Local_Font_*)
--   style        Regel des angewandten Stils <token>.<stil>:normal .self; ein Stil hält
--                nur seine Abweichungen vom Typ-Standard. Fehlt die Regel unter
--                dem Token des Objekts, zählt eine Regel desselben Stils unter einem
--                anderen Token (ältere Dateien führen Stile mehrfach).
--   part_theme   Bereichs-Regel <bereich> <token>:normal .self (nur Abweichungen; Rang
--                vor dem Typ-Standard ist eine Annahme, daher Low_Confidence)
--   theme        Typ-Standard <token>:normal .self
--   group        Gruppen-Regel (field:normal .self) — nur wenn der Typ nichts setzt
--   default      nichts deklariert: Standard der Datei, steht nicht im Export
--                (Helvetica Neue, Helvetica, Arial je nach Datei) → Font_Family NULL
-- Container vererben nicht (ein Feld im Portal erbt nichts vom Portal).
-- Family_Source 'local_redundant': lokal gesetzt, aber dieselbe Familie wie geerbt —
-- typisch, wenn „fett" die Familie mit dem Schnitt-PostScript mitschreibt;
-- keine bewusste Schriftwahl.
-- Font_Family = erster Wert der Notation -fm-font-family(<familie>[,…],<postscript>[;
-- generisch]) bzw. der CSS-Liste, wie geschrieben; Font_Key = kleingeschrieben
-- (Gruppierschlüssel), Font_PostScript = PostScript-Name (kann einen Schnitt tragen).
-- Zusatz, nicht Teil der Kaskade: Rich_* = Teil-Läufe mit eigener Familie
-- (LayoutObjectFontRuns, rich_text), CF_Font_Families = Schrift aktiver CF-Regeln mit
-- Schrift-Bit (Options bit 3) — beides ändert die Grundschrift nicht.
-- Diagramme stehen nicht hier: ihre Schriften liegen fest je Textbereich in
-- LayoutObjectFontRuns (Source 'chart').
CREATE OR REPLACE TEMP MACRO _font_inner(v) AS
    CASE WHEN v LIKE '-fm-font-family(%' THEN regexp_extract(v, '^-fm-font-family\((.*)\)\s*$', 1) ELSE v END;
CREATE OR REPLACE TEMP MACRO _font_family(v) AS
    NULLIF(regexp_replace(trim(split_part(split_part(_font_inner(v), ';', 1), ',', 1)), '^["'']|["'']$', '', 'g'), '');
CREATE OR REPLACE TEMP MACRO _font_postscript(v) AS
    CASE WHEN v LIKE '-fm-font-family(%'
         THEN NULLIF(trim(list_last(string_split(split_part(_font_inner(v), ';', 1), ','))), '') END;

DROP TABLE IF EXISTS v_layout_object_font;
CREATE TABLE v_layout_object_font AS
WITH lo AS (
    SELECT Object_UUID, File_Name, Layout_ID, Object_ID, Object_Type, Object_Name,
           Part_Type, Parent_Object_ID, Nesting_Level,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
),
obj AS (
    SELECT lo.*, p.Object_Type AS Parent_Object_Type
    FROM lo
    LEFT JOIN LayoutObjects p
           ON p.File_Name = lo.File_Name AND p.Layout_ID = lo.Layout_ID
          AND p.Object_ID = lo.Parent_Object_ID
    WHERE lo.rn = 1
),
typed AS (
    -- Zeile mit passendem Container-Typ vor der allgemeinen Zeile
    SELECT o.*, ct.Type_Token, ct.Group_Token, ct.Has_Text
    FROM obj o
    JOIN LayoutObjectCssType ct
      ON ct.Object_Type = o.Object_Type
     AND (ct.Parent_Object_Type = o.Parent_Object_Type OR ct.Parent_Object_Type IS NULL)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY o.Object_UUID, o.File_Name
                               ORDER BY (ct.Parent_Object_Type IS NULL)) = 1
),
o AS (
    SELECT t.*,
           l.L_Name                AS Layout_Name,
           l.L_Theme_Resolved_UUID AS Theme_UUID,
           l.L_Theme_Resolved_Name AS Theme_Name,
           CASE t.Part_Type
               WHEN 'Title Header'           THEN 'title_header'
               WHEN 'Header'                 THEN 'header'
               WHEN 'Leading Grand Summary'  THEN 'leading_grand_summary'
               WHEN 'Leading Sub-summary'    THEN 'leading_sub_summary'
               WHEN 'Body'                   THEN 'body'
               WHEN 'Trailing Sub-summary'   THEN 'trailing_sub_summary'
               WHEN 'Trailing Grand Summary' THEN 'trailing_grand_summary'
               WHEN 'Footer'                 THEN 'footer'
               WHEN 'Title Footer'           THEN 'title_footer'
               WHEN 'Top Navigation'         THEN 'top_nav_part'
               WHEN 'Bottom Navigation'      THEN 'bottom_nav_part'
           END                     AS Part_Token,
           s.Style_Name, s.Style_Display,
           s.Local_Font_Family, s.Local_Font_Size, s.Local_Font_Weight, s.Local_Font_Style
    FROM typed t
    JOIN Layouts l ON l.L_ID = t.Layout_ID AND l.File_Name = t.File_Name
    LEFT JOIN LayoutObjectStyles s ON s.Object_UUID = t.Object_UUID AND s.File_Name = t.File_Name
    WHERE t.Has_Text
),
tp AS (
    -- normal .self-Werte je Regelschlüssel; bei Mehrfachregel gewinnt die spätere
    SELECT File_Name, Theme_UUID, Part_Token, Type_Token, Style_Class,
           arg_max(Value, Rule_Seq) FILTER (WHERE Property = 'font-family') AS fam,
           arg_max(Value, Rule_Seq) FILTER (WHERE Property = 'font-size')   AS sz,
           arg_max(Value, Rule_Seq) FILTER (WHERE Property = 'font-weight') AS wt,
           arg_max(Value, Rule_Seq) FILTER (WHERE Property = 'font-style')  AS st,
           TRUE                                                             AS present
    FROM ThemeStyleRules
    WHERE State = 'normal' AND Element = 'self'
    GROUP BY ALL
),
sk AS (
    -- Stil existiert im Theme, wenn irgendeine Regel (jeder Zustand, jedes Element,
    -- jedes Token) die Klasse führt — gleiche Definition wie v_check_layout_styles
    SELECT DISTINCT File_Name, Theme_UUID, Style_Class
    FROM ThemeStyleRules
    WHERE Style_Class IS NOT NULL
),
c AS (
    SELECT o.*,
           (o.Style_Name IS NULL OR sk.Style_Class IS NOT NULL)             AS style_rule_found,
           coalesce(sx.fam, sa.fam) AS s_fam, coalesce(sx.sz, sa.sz) AS s_sz,
           coalesce(sx.wt, sa.wt)   AS s_wt,  coalesce(sx.st, sa.st) AS s_st,
           pt.fam AS p_fam, pt.sz AS p_sz, pt.wt AS p_wt, pt.st AS p_st,
           ty.fam AS t_fam, ty.sz AS t_sz, ty.wt AS t_wt, ty.st AS t_st,
           gr.fam AS g_fam, gr.sz AS g_sz, gr.wt AS g_wt, gr.st AS g_st
    FROM o
    LEFT JOIN tp sx ON sx.File_Name = o.File_Name AND sx.Theme_UUID = o.Theme_UUID
                   AND sx.Part_Token IS NULL AND sx.Type_Token = o.Type_Token AND sx.Style_Class = o.Style_Name
    LEFT JOIN (SELECT File_Name, Theme_UUID, Style_Class,
                      any_value(fam ORDER BY Type_Token) FILTER (WHERE fam IS NOT NULL) AS fam,
                      any_value(sz  ORDER BY Type_Token) FILTER (WHERE sz  IS NOT NULL) AS sz,
                      any_value(wt  ORDER BY Type_Token) FILTER (WHERE wt  IS NOT NULL) AS wt,
                      any_value(st  ORDER BY Type_Token) FILTER (WHERE st  IS NOT NULL) AS st,
                      TRUE AS present
               FROM tp WHERE Part_Token IS NULL AND Style_Class IS NOT NULL
               GROUP BY ALL) sa
           ON sa.File_Name = o.File_Name AND sa.Theme_UUID = o.Theme_UUID
          AND sa.Style_Class = o.Style_Name AND sx.present IS NULL
    LEFT JOIN sk ON sk.File_Name = o.File_Name AND sk.Theme_UUID = o.Theme_UUID
                AND sk.Style_Class = o.Style_Name
    LEFT JOIN tp pt ON pt.File_Name = o.File_Name AND pt.Theme_UUID = o.Theme_UUID
                   AND pt.Part_Token = o.Part_Token AND pt.Type_Token = o.Type_Token AND pt.Style_Class IS NULL
    LEFT JOIN tp ty ON ty.File_Name = o.File_Name AND ty.Theme_UUID = o.Theme_UUID
                   AND ty.Part_Token IS NULL AND ty.Type_Token = o.Type_Token AND ty.Style_Class IS NULL
    LEFT JOIN tp gr ON gr.File_Name = o.File_Name AND gr.Theme_UUID = o.Theme_UUID
                   AND gr.Part_Token IS NULL AND gr.Type_Token = o.Group_Token AND gr.Style_Class IS NULL
),
k AS (
    SELECT c.*,
           coalesce(Local_Font_Family, s_fam, p_fam, t_fam, g_fam) AS fam_raw,
           coalesce(s_fam, p_fam, t_fam, g_fam)                    AS fam_inherited,
           CASE WHEN Local_Font_Family IS NOT NULL THEN 'local' WHEN s_fam IS NOT NULL THEN 'style'
                WHEN p_fam IS NOT NULL THEN 'part_theme' WHEN t_fam IS NOT NULL THEN 'theme'
                WHEN g_fam IS NOT NULL THEN 'group' ELSE 'default' END AS fam_src,
           coalesce(Local_Font_Size, s_sz, p_sz, t_sz, g_sz)       AS Font_Size,
           CASE WHEN Local_Font_Size IS NOT NULL THEN 'local' WHEN s_sz IS NOT NULL THEN 'style'
                WHEN p_sz IS NOT NULL THEN 'part_theme' WHEN t_sz IS NOT NULL THEN 'theme'
                WHEN g_sz IS NOT NULL THEN 'group' ELSE 'default' END  AS Size_Source,
           coalesce(Local_Font_Weight, s_wt, p_wt, t_wt, g_wt)     AS Font_Weight,
           CASE WHEN Local_Font_Weight IS NOT NULL THEN 'local' WHEN s_wt IS NOT NULL THEN 'style'
                WHEN p_wt IS NOT NULL THEN 'part_theme' WHEN t_wt IS NOT NULL THEN 'theme'
                WHEN g_wt IS NOT NULL THEN 'group' ELSE 'default' END  AS Weight_Source,
           coalesce(Local_Font_Style, s_st, p_st, t_st, g_st)      AS Font_Style,
           CASE WHEN Local_Font_Style IS NOT NULL THEN 'local' WHEN s_st IS NOT NULL THEN 'style'
                WHEN p_st IS NOT NULL THEN 'part_theme' WHEN t_st IS NOT NULL THEN 'theme'
                WHEN g_st IS NOT NULL THEN 'group' ELSE 'default' END  AS Style_Source
    FROM c
),
rich AS (
    SELECT Object_UUID, File_Name,
           count(*)                                                          AS Rich_Run_Count,
           string_agg(DISTINCT Font_Family, ', ' ORDER BY Font_Family)       AS Rich_Font_Families
    FROM LayoutObjectFontRuns
    WHERE Source = 'rich_text'
    GROUP BY ALL
),
cf AS (
    SELECT Object_UUID, File_Name,
           string_agg(DISTINCT _font_family(regexp_extract(Local_CSS,
               'font-family\s*:\s*((?:[^;()]|\([^)]*\))*);', 1)), ', ')     AS CF_Font_Families
    FROM LayoutObjectConditions
    WHERE (Options_Raw & 1) = 1 AND (Options_Raw & 8) = 8 AND Local_CSS LIKE '%font-family%'
    GROUP BY ALL
)
SELECT
    k.Object_UUID, k.File_Name, k.Layout_ID, k.Layout_Name, k.Object_Type, k.Object_Name,
    k.Part_Type, k.Theme_UUID, k.Theme_Name, k.Type_Token, k.Group_Token, k.Part_Token,
    k.Style_Name, k.Style_Display,
    k.fam_raw                                                     AS Font_Family_Raw,
    _font_family(k.fam_raw)                                       AS Font_Family,
    lower(_font_family(k.fam_raw))                                AS Font_Key,
    _font_postscript(k.fam_raw)                                   AS Font_PostScript,
    CASE WHEN k.fam_src = 'local' AND k.fam_inherited IS NOT NULL
              AND lower(_font_family(k.Local_Font_Family)) = lower(_font_family(k.fam_inherited))
         THEN 'local_redundant' ELSE k.fam_src END                AS Family_Source,
    k.Font_Size, k.Size_Source, k.Font_Weight, k.Weight_Source, k.Font_Style, k.Style_Source,
    coalesce(r.Rich_Run_Count, 0)                                 AS Rich_Run_Count,
    r.Rich_Font_Families,
    cf.CF_Font_Families,
    NOT k.style_rule_found                                        AS Style_Rule_Missing,
    (k.fam_src = 'part_theme' OR k.Size_Source = 'part_theme'
     OR NOT k.style_rule_found OR k.Theme_UUID IS NULL)           AS Low_Confidence
FROM k
LEFT JOIN rich r ON r.Object_UUID = k.Object_UUID AND r.File_Name = k.File_Name
LEFT JOIN cf     ON cf.Object_UUID = k.Object_UUID AND cf.File_Name = k.File_Name;

CREATE INDEX idx_layout_object_font_obj    ON v_layout_object_font (Object_UUID, File_Name);
CREATE INDEX idx_layout_object_font_layout ON v_layout_object_font (File_Name, Layout_ID);


-- --------------------------------------------
-- v_layout_object_style — angewandter Stil je Layout-Objekt (VIEW, Schema 1.45.0)
-- --------------------------------------------
-- Eine Zeile je Layout-Objekt (erste Zeile je UUID + Datei, wie v_layout_object_font),
-- ALLE Objekttypen — auch ohne Text (Rechteck, Linie, Grafik, Gruppe) und auch ohne
-- Stil (Style_Name NULL), damit „Objekte ohne Stil" zählbar bleiben. Aufgelöst bis zum
-- Design des Layouts (Theme_* NULL = Layout ohne Design).
-- Style_Name = Stilklasse aus LocalCSS (LayoutObjectStyles), Style_Display = Name im
-- Inspector zum Exportzeitpunkt (Sprache des Designs), Style_Is_Custom = eigener Stil
-- (Klasse FM-<UUID>; NULL ohne Stil). Style_Rule_Missing = Stilname ohne Regel im Design des Layouts —
-- dieselbe Definition wie v_check_layout_styles und v_layout_object_font (eine Regel der
-- Klasse unter beliebigem Typ-Token genügt).
-- Nutzung eines Stils = Gruppierung dieser View (Design × Stil, Stile eines Layouts);
-- die vollständige Stilliste eines Designs (<namedstyles>) ist nicht importiert.
-- Bewusst eine einfache View: über die größte Lösung (163 469 Objekte) 0,15 s.
CREATE OR REPLACE VIEW v_layout_object_style AS
WITH lo AS (
    SELECT Object_UUID, File_Name, Layout_ID, Object_Type
    FROM LayoutObjects
    QUALIFY ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) = 1
),
sk AS (   -- Stil existiert im Design: irgendeine Regel der Klasse
    SELECT DISTINCT File_Name, Theme_UUID, Style_Class
    FROM ThemeStyleRules
    WHERE Style_Class IS NOT NULL
)
SELECT lo.Object_UUID, lo.File_Name, lo.Layout_ID, lo.Object_Type,
       l.L_UUID                  AS Layout_UUID,
       l.L_Name                  AS Layout_Name,
       l.L_Theme_Resolved_UUID   AS Theme_UUID,
       l.L_Theme_Resolved_Name   AS Theme_Name,
       tc.Theme_Display,
       s.Style_Name,
       s.Style_Display,
       s.Style_Name LIKE 'FM-%'                               AS Style_Is_Custom,
       (s.Style_Name IS NOT NULL AND sk.Style_Class IS NULL)  AS Style_Rule_Missing
FROM lo
JOIN Layouts l
  ON l.L_ID = lo.Layout_ID AND l.File_Name = lo.File_Name
LEFT JOIN ThemeCatalog tc
  ON tc.File_Name = l.File_Name AND tc.Theme_UUID = l.L_Theme_Resolved_UUID
LEFT JOIN LayoutObjectStyles s
  ON s.Object_UUID = lo.Object_UUID AND s.File_Name = lo.File_Name
LEFT JOIN sk
  ON sk.File_Name = l.File_Name AND sk.Theme_UUID = l.L_Theme_Resolved_UUID
 AND sk.Style_Class = s.Style_Name;
