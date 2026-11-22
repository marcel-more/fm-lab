-- ============================================
-- create_dataflow_views.sql
-- ============================================
-- Datenfluss-Kantensicht für den Daten-Trace (Schema 1.43.0, Konverter 2.51.3).
--
-- Eigene, BATCH-WEITE, TABLE-ONLY Phase direkt NACH create_analysis_views.sql
-- (braucht v_script_step_links mit Variablen-Zeilen, v_script_block_tree,
-- CalculationsCatalog, StepCalculations, CalculationSqlRefs). Wird bei jedem
-- convert-xml-Lauf vollständig neu gebaut und nicht abschaltbar: ab Schema 1.43.0
-- sind die Tabellen garantiert (Daten-Trace, Ablauf-Trace, Tests). Scheitert die
-- Phase, entfernt convert_fm_xml.sh die Tabellen und meldet einen Fehler-Befund
-- (nicht fatal); die REST-API antwortet dann DATAFLOW_NOT_BUILT.
--
-- Erzeugt:
--   - v_step_guards        MATERIALIZED: je Schritt mit Datenkanten und je aktivem
--                          Ablaufschritt (Script-Aufruf, Go to Layout, Go to Related
--                          Record) der eigene Zweig jeder umschließenden If-Kette und
--                          jede umschließende Schleife
--   - v_dataflow_edges     MATERIALIZED: eine Zeile je Datenfluss-, Kontroll-,
--                          Einstiegs- oder Senken-Beziehung zwischen typisierten Knoten
--   - v_check_dataflow_edges  VIEW: Vollständigkeit gegenüber v_script_step_links
--
-- Richtung: From → To heißt „der Wert fließt von From nach To“ (data) bzw. „From
-- löst To aus“ (control, entry) bzw. „Feld/Variable wird von To verwendet“ (sink).
-- Knoten-Identität ist immer (Kind, UUID, Datei); Pseudoknoten (ScriptParam,
-- ScriptResult, DynamicTarget, Uninitialized, ImportSource, AutoEnter) tragen eine
-- abgeleitete UUID mit '#'-Suffix.
--
-- Hilfstabellen tragen das Präfix _df_ und werden am Ende entfernt.

-- --------------------------------------------
-- 0. Schritte, Formel-Slots, Variablen
-- --------------------------------------------
DROP TABLE IF EXISTS _df_steps;
CREATE TEMP TABLE _df_steps AS
SELECT File_Name, Script_ID, Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled
FROM v_script_block_tree;

-- Formel → Slot des Schritts (StepCalculations: Slot je Calc_Position). Steuer-Slots
-- tragen keinen Wert in das, was der Schritt schreibt: Wiederholungsindex, Titel/
-- Meldung/Buttons/Labels eines Dialogs. Der Slot List ist mehrdeutig: Steuerung nur
-- bei Script-Name (Perform Script 1, 164, 210), Datensatz-/Zeilennummer (Go to
-- Record 16, Go to Portal Row 99) und URL (Set Web Viewer 146); bei Replace Field
-- Contents (91) und allen übrigen Schritten trägt er den geschriebenen Wert.
DROP TABLE IF EXISTS _df_slot;
CREATE TEMP TABLE _df_slot AS
SELECT c.Calculation_UUID, c.File_Name, c.Owner_UUID AS Step_UUID, sc.Slot,
       (sc.Slot = 'repetition'
        OR sc.Slot IN ('Parameter:Title', 'Parameter:Message')
        OR (sc.Slot = 'List' AND st.Step_ID IN (1, 16, 99, 146, 164, 210))
        OR sc.Slot LIKE 'Parameter:Button%' OR sc.Slot LIKE 'Parameter:Label%') AS Slot_Ctl,
       c.Formula_Text
FROM CalculationsCatalog c
LEFT JOIN StepCalculations sc
       ON sc.Step_UUID = c.Owner_UUID AND sc.File_Name = c.File_Name
      AND sc.Calc_Position = TRY_CAST(c.Calc_Kind_Raw AS INTEGER)
LEFT JOIN _df_steps st ON st.Step_UUID = c.Owner_UUID AND st.File_Name = c.File_Name
WHERE c.Owner_Type = 'ScriptStep'
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.Calculation_UUID, c.File_Name ORDER BY sc.Slot_Seq NULLS LAST) = 1;

-- Variablen-UUID → Name und Bereich
DROP TABLE IF EXISTS _df_var;
CREATE TEMP TABLE _df_var AS
SELECT DISTINCT md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) AS Var_UUID,
       Variable_Name, Variable_Scope
FROM VariablesCatalog;

-- SQL-Rolle je (Formel, Ziel): Auswahl (Wert) bzw. Filter (Steuerung); Variablen als
-- SQL-Argument (Raw_Name = Variablenname) sind Filter
DROP TABLE IF EXISTS _df_sql;
CREATE TEMP TABLE _df_sql AS
SELECT Calculation_UUID, File_Name,
       CASE WHEN Target_Type = 'Field' THEN Target_UUID ELSE Raw_Name END AS Ref_Key,
       bool_or(Clause = 'select') AS Is_Select,
       bool_or(Clause IN ('where', 'on', 'having', 'group', 'order', 'parameter')) AS Is_Filter,
       min(Column_Pos) FILTER (WHERE Clause = 'select') AS Column_Pos,
       min(Arg_Pos) AS Arg_Pos,
       any_value(Resolution) AS Resolution
FROM CalculationSqlRefs
WHERE Target_Type = 'Field' OR (Raw_Name LIKE '$%' AND Resolution = 'dynamic')
GROUP BY ALL;

-- --------------------------------------------
-- 1. Blockstruktur (nur aktive Schritte): If-Ketten-Zweige und Schleifen
-- --------------------------------------------
DROP TABLE IF EXISTS _df_ctl;
CREATE TEMP TABLE _df_ctl AS
SELECT File_Name, Script_ID, Script_UUID, Step_UUID, Step_Index, Step_ID,
       COALESCE(SUM(CASE Step_ID WHEN 68 THEN 1 WHEN 70 THEN -1 ELSE 0 END) OVER w, 0) AS If_Lvl,
       COALESCE(SUM(CASE Step_ID WHEN 71 THEN 1 WHEN 73 THEN -1 ELSE 0 END) OVER w, 0) AS Loop_Lvl
FROM _df_steps
WHERE Is_Enabled
WINDOW w AS (PARTITION BY File_Name, Script_ID ORDER BY Step_Index
             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING);

-- If-Ketten: Ende = erstes End If dahinter auf der Ebene der Kette
DROP TABLE IF EXISTS _df_if;
CREATE TEMP TABLE _df_if AS
SELECT o.File_Name, o.Script_ID, o.Step_Index AS Open_Idx, o.If_Lvl AS Lvl,
       COALESCE((SELECT min(c.Step_Index) FROM _df_ctl c
                 WHERE c.File_Name = o.File_Name AND c.Script_ID = o.Script_ID AND c.Step_ID = 70
                   AND c.If_Lvl = o.If_Lvl + 1 AND c.Step_Index > o.Step_Index), 2147483647) AS End_Idx
FROM _df_ctl o WHERE o.Step_ID = 68;

-- Zweige einer Kette: [If|Else If|Else] … nächster Kettenschritt
DROP TABLE IF EXISTS _df_blocks;
CREATE TEMP TABLE _df_blocks AS
WITH pos AS (
    SELECT File_Name, Script_ID, Open_Idx, End_Idx, Lvl, Open_Idx AS P_Idx, 68 AS P_Step FROM _df_if
    UNION ALL
    SELECT i.File_Name, i.Script_ID, i.Open_Idx, i.End_Idx, i.Lvl, c.Step_Index, c.Step_ID
    FROM _df_if i
    JOIN _df_ctl c ON c.File_Name = i.File_Name AND c.Script_ID = i.Script_ID
                  AND c.Step_ID IN (125, 69) AND c.If_Lvl = i.Lvl + 1
                  AND c.Step_Index > i.Open_Idx AND c.Step_Index < i.End_Idx
)
SELECT File_Name, Script_ID, 'branch' AS Block_Kind,
       'b:' || Script_ID || ':' || P_Idx AS Block_ID,
       Open_Idx AS Chain_Open, P_Idx AS B_Start, P_Step AS Opener_Step_ID,
       COALESCE(lead(P_Idx) OVER (PARTITION BY File_Name, Script_ID, Open_Idx ORDER BY P_Idx), End_Idx) AS B_End
FROM pos
UNION ALL
SELECT o.File_Name, o.Script_ID, 'loop', 'l:' || o.Script_ID || ':' || o.Step_Index,
       o.Step_Index, o.Step_Index, 71,
       COALESCE((SELECT min(c.Step_Index) FROM _df_ctl c
                 WHERE c.File_Name = o.File_Name AND c.Script_ID = o.Script_ID AND c.Step_ID = 73
                   AND c.Loop_Lvl = o.Loop_Lvl + 1 AND c.Step_Index > o.Step_Index), 2147483647)
FROM _df_ctl o WHERE o.Step_ID = 71;

-- Pfad je aktivem Schritt: umschließende Blöcke außen → innen; innerster Block
DROP TABLE IF EXISTS _df_path;
CREATE TEMP TABLE _df_path AS
SELECT s.File_Name, s.Script_ID, s.Script_UUID, s.Step_UUID, s.Step_Index, s.Step_ID,
       COALESCE(list(b.Block_ID ORDER BY b.B_Start) FILTER (WHERE b.Block_ID IS NOT NULL), []) AS Path,
       arg_max(b.Block_ID, b.B_Start) AS Inner_Block
FROM _df_ctl s
LEFT JOIN _df_blocks b
       ON b.File_Name = s.File_Name AND b.Script_ID = s.Script_ID
      AND s.Step_Index > b.B_Start AND s.Step_Index < b.B_End
GROUP BY ALL;

-- --------------------------------------------
-- 2. Custom Functions transitiv
-- --------------------------------------------
-- cf → alle (auch indirekt) aufgerufenen CFs inkl. sich selbst — je Datei: Klon-Dateien
-- tragen dieselben CF-UUIDs, Bezüge eines Klons gehören nicht zur CF einer anderen Datei
DROP TABLE IF EXISTS _df_cfclose;
CREATE TEMP TABLE _df_cfclose AS
WITH RECURSIVE cl(Cf, File_Name, Callee) AS (
    SELECT DISTINCT Object_UUID, File_Name, Object_UUID FROM ObjectCatalog WHERE Object_Type = 'CustomFunction'
    UNION
    SELECT cl.Cf, cl.File_Name, l.Target_UUID
    FROM cl JOIN ObjectLinks l ON l.Source_UUID = cl.Callee AND l.Source_File = cl.File_Name
                               AND l.Source_Type = 'CustomFunction'
                               AND l.Link_Role = 'calls_customfunction' AND l.Target_Type = 'CustomFunction'
                               AND COALESCE(l.Target_File, l.Source_File) = cl.File_Name
)
SELECT DISTINCT Cf, File_Name, Callee FROM cl;

-- was eine CF (transitiv) liest bzw. setzt, je (CF, Datei)
DROP TABLE IF EXISTS _df_cfuse;
CREATE TEMP TABLE _df_cfuse AS
SELECT DISTINCT c.Cf, c.File_Name, 'field' AS Use_Kind, l.Target_UUID AS Ref_UUID, l.Target_File AS Ref_File, 'read' AS Usage
FROM _df_cfclose c JOIN ObjectLinks l ON l.Source_UUID = c.Callee AND l.Source_File = c.File_Name
                                     AND l.Source_Type = 'CustomFunction'
                                     AND l.Link_Role = 'reads_field' AND l.Target_Type = 'Field'
UNION
SELECT DISTINCT c.Cf, c.File_Name, CASE b.Object_Name WHEN 'Get(ScriptParameter)' THEN 'param' ELSE 'result' END, NULL, NULL, 'read'
FROM _df_cfclose c
JOIN ObjectLinks l ON l.Source_UUID = c.Callee AND l.Source_File = c.File_Name
                  AND l.Source_Type = 'CustomFunction' AND l.Link_Role = 'calls_function'
JOIN ObjectCatalog b ON b.Object_UUID = l.Target_UUID AND b.Object_Type = 'BuiltinFunction'
WHERE b.Object_Name IN ('Get(ScriptParameter)', 'Get(ScriptResult)')
UNION
SELECT DISTINCT c.Cf, c.File_Name, 'variable', l.Target_UUID, l.Target_File,
       CASE l.Link_Role WHEN 'sets_variable' THEN 'set' ELSE 'read' END
FROM _df_cfclose c
JOIN ObjectLinks l ON l.Source_UUID = c.Callee AND l.Source_File = c.File_Name
                  AND l.Source_Type = 'CustomFunction'
                  AND l.Link_Role IN ('reads_variable', 'sets_variable') AND l.Target_Type = 'Variable';

-- --------------------------------------------
-- 3. Bezüge je Schritt, klassifiziert (Wert / Steuerung / Bedingung)
-- --------------------------------------------
-- Ref_Kind: field · variable · param · result; Usage: read · set
-- Klasse: guard (Bedingung von If/Else If/Exit Loop If), ctl (Steuer-Slot, SQL-Filter),
-- data (Wert); SQL-Auswahl zusätzlich als data/approx.
DROP TABLE IF EXISTS _df_ref;
CREATE TEMP TABLE _df_ref AS
WITH base AS (
    -- direkt in der Schritt-Formel
    SELECT l.Script_UUID, l.File_Name, l.Step_UUID, l.Step_Index, l.Step_ID, l.Is_Enabled,
           l.Via, l.Calculation_UUID, l.Link_Role, l.Link_Subrole,
           CASE WHEN l.Target_Type = 'Field' THEN 'field' ELSE 'variable' END AS Ref_Kind,
           l.Target_UUID AS Ref_UUID, l.Target_File AS Ref_File,
           CASE WHEN l.Link_Role = 'sets_variable' THEN 'set' ELSE 'read' END AS Usage,
           FALSE AS Via_CF
    FROM v_script_step_links l
    WHERE (l.Link_Role = 'reads_field' AND l.Via = 'calculation' AND l.Target_Type = 'Field')
       OR (l.Link_Role IN ('reads_variable', 'sets_variable') AND l.Target_Type = 'Variable')
    UNION ALL
    -- Get(ScriptParameter) / Get(ScriptResult) direkt
    SELECT l.Script_UUID, l.File_Name, l.Step_UUID, l.Step_Index, l.Step_ID, l.Is_Enabled,
           l.Via, l.Calculation_UUID, l.Link_Role, l.Link_Subrole,
           CASE b.Object_Name WHEN 'Get(ScriptParameter)' THEN 'param' ELSE 'result' END,
           NULL, NULL, 'read', FALSE
    FROM v_script_step_links l
    JOIN ObjectCatalog b ON b.Object_UUID = l.Target_UUID AND b.Object_Type = 'BuiltinFunction'
    WHERE l.Link_Role = 'calls_function' AND b.Object_Name IN ('Get(ScriptParameter)', 'Get(ScriptResult)')
    UNION ALL
    -- über aufgerufene Custom Functions
    SELECT l.Script_UUID, l.File_Name, l.Step_UUID, l.Step_Index, l.Step_ID, l.Is_Enabled,
           l.Via, l.Calculation_UUID, l.Link_Role, 'via_custom_function',
           u.Use_Kind, u.Ref_UUID, u.Ref_File, u.Usage, TRUE
    FROM v_script_step_links l
    JOIN _df_cfuse u ON u.Cf = l.Target_UUID AND u.File_Name = COALESCE(l.Target_File, l.File_Name)
    WHERE l.Link_Role = 'calls_customfunction' AND l.Target_Type = 'CustomFunction'
)
SELECT b.*,
       v.Variable_Scope, v.Variable_Name,
       s.Slot, COALESCE(s.Slot_Ctl, FALSE) AS Slot_Ctl,
       q.Is_Select, q.Is_Filter, q.Column_Pos, q.Arg_Pos, q.Resolution,
       CASE WHEN b.Usage = 'set' THEN 'data'
            WHEN b.Step_ID IN (68, 125, 72) THEN 'guard'
            WHEN COALESCE(s.Slot_Ctl, FALSE) THEN 'ctl'
            WHEN q.Is_Select THEN 'data'
            WHEN q.Is_Filter THEN 'ctl'
            ELSE 'data' END AS Ref_Class
FROM base b
LEFT JOIN _df_var v ON b.Ref_Kind = 'variable' AND v.Var_UUID = b.Ref_UUID
LEFT JOIN _df_slot s ON s.Calculation_UUID = b.Calculation_UUID AND s.File_Name = b.File_Name
LEFT JOIN _df_sql q ON q.Calculation_UUID = b.Calculation_UUID AND q.File_Name = b.File_Name
                   AND q.Ref_Key = CASE WHEN b.Ref_Kind = 'field' THEN b.Ref_UUID ELSE v.Variable_Name END
WHERE b.Ref_Kind IN ('field', 'param', 'result') OR v.Variable_Scope IN ('local', 'global', 'superglobal');

-- --------------------------------------------
-- 4. Setzer-Erreichbarkeit lokaler Variablen
-- --------------------------------------------
-- Setzer und Wert-Leser (aktive Schritte) mit Blockpfad
DROP TABLE IF EXISTS _df_lset;
-- Let_Set: per Let im Kopf einer Formel gesetzt — die Zuweisung geht dem Lesen im
-- selben Schritt voraus (anders als Set Variable [ $x ; $x + 1 ], dessen Lesen die
-- vorherigen Setzer erreichen).
CREATE TEMP TABLE _df_lset AS
SELECT p.File_Name, p.Script_ID, r.Ref_UUID AS Var_UUID, p.Step_Index, p.Step_UUID, p.Inner_Block,
       bool_or(r.Link_Subrole = 'let_assign') AS Let_Set
FROM _df_ref r JOIN _df_path p ON p.Step_UUID = r.Step_UUID AND p.File_Name = r.File_Name
WHERE r.Ref_Kind = 'variable' AND r.Variable_Scope = 'local' AND r.Usage = 'set'
GROUP BY ALL;

DROP TABLE IF EXISTS _df_lread;
CREATE TEMP TABLE _df_lread AS
SELECT p.File_Name, p.Script_ID, r.Ref_UUID AS Var_UUID, p.Step_Index, p.Step_UUID, p.Path,
       any_value(r.Calculation_UUID) AS Calculation_UUID, count(DISTINCT r.Calculation_UUID) AS N_Sources
FROM _df_ref r JOIN _df_path p ON p.Step_UUID = r.Step_UUID AND p.File_Name = r.File_Name
WHERE r.Ref_Kind = 'variable' AND r.Variable_Scope = 'local' AND r.Usage = 'read' AND r.Ref_Class = 'data'
GROUP BY ALL;

-- K(R): letzter Setzer vor R, dessen innerster Block R umschließt (überschreibt sicher);
-- ein Let-Setzer im Schritt R selbst gilt als „vor R“
DROP TABLE IF EXISTS _df_kill;
CREATE TEMP TABLE _df_kill AS
SELECT r.File_Name, r.Script_ID, r.Var_UUID, r.Step_Index,
       max(t.Step_Index) AS K_Idx
FROM _df_lread r
JOIN _df_lset t ON t.File_Name = r.File_Name AND t.Script_ID = r.Script_ID AND t.Var_UUID = r.Var_UUID
               AND (t.Step_Index < r.Step_Index OR (t.Step_Index = r.Step_Index AND t.Let_Set))
               AND (t.Inner_Block IS NULL OR list_contains(r.Path, t.Inner_Block)
                    OR t.Step_Index = r.Step_Index)
GROUP BY ALL;

DROP TABLE IF EXISTS _df_reach;
CREATE TEMP TABLE _df_reach AS
-- vorwärts: K(R) ≤ S < R (bzw. S = R bei Let-Setzer im selben Schritt)
SELECT r.File_Name, r.Script_ID, r.Var_UUID, s.Step_UUID AS Set_Step, r.Step_UUID AS Read_Step,
       r.Calculation_UUID, r.N_Sources, 'forward' AS Reach
FROM _df_lread r
LEFT JOIN _df_kill k USING (File_Name, Script_ID, Var_UUID, Step_Index)
JOIN _df_lset s ON s.File_Name = r.File_Name AND s.Script_ID = r.Script_ID AND s.Var_UUID = r.Var_UUID
               AND (s.Step_Index < r.Step_Index OR (s.Step_Index = r.Step_Index AND s.Let_Set))
               AND s.Step_Index >= COALESCE(k.K_Idx, -1)
UNION
-- Schleife: S ≥ R in einer R umschließenden Schleife, sofern kein sicherer Setzer
-- zwischen Schleifenbeginn und R liegt
SELECT r.File_Name, r.Script_ID, r.Var_UUID, s.Step_UUID, r.Step_UUID,
       r.Calculation_UUID, r.N_Sources, 'loop'
FROM _df_lread r
LEFT JOIN _df_kill k USING (File_Name, Script_ID, Var_UUID, Step_Index)
JOIN _df_blocks b ON b.File_Name = r.File_Name AND b.Script_ID = r.Script_ID AND b.Block_Kind = 'loop'
                 AND list_contains(r.Path, b.Block_ID)
JOIN _df_lset s ON s.File_Name = r.File_Name AND s.Script_ID = r.Script_ID AND s.Var_UUID = r.Var_UUID
               AND s.Step_Index >= r.Step_Index AND s.Step_Index > b.B_Start AND s.Step_Index < b.B_End
WHERE k.K_Idx IS NULL OR k.K_Idx <= b.B_Start;

-- --------------------------------------------
-- 5. v_dataflow_edges
-- --------------------------------------------
DROP TABLE IF EXISTS v_dataflow_edges;
CREATE TABLE v_dataflow_edges (
    Flow_Class        VARCHAR,   -- data · control · entry · sink
    Flow_Kind         VARCHAR,
    From_Kind         VARCHAR, From_UUID VARCHAR, From_File VARCHAR,
    To_Kind           VARCHAR, To_UUID   VARCHAR, To_File   VARCHAR,
    Script_UUID       VARCHAR, Step_UUID VARCHAR, Step_Index INTEGER, Step_ID INTEGER,
    File_Name         VARCHAR,   -- Datei des Schritts (Script-Datei), NULL ohne Schritt
    Is_Enabled        BOOLEAN,
    Via               VARCHAR,
    Calculation_UUID  VARCHAR,
    Link_Role         VARCHAR, Link_Subrole VARCHAR,
    Sql_Clause        VARCHAR, Sql_Column_Pos INTEGER, Sql_Arg_Pos INTEGER, Sql_Resolution VARCHAR,
    Guard_Step_Index  INTEGER,
    Pair_Step_UUID    VARCHAR,   -- result_to_step: gepaarter Aufrufschritt
    Variable_UUID     VARCHAR,   -- local_def_use / local_uninitialized
    No_Data_Source    BOOLEAN,
    Writer_Kind       VARCHAR,   -- step_writes_field: value · constant · reset · input · import
    Precision         VARCHAR,   -- exact · approx · dynamic
    Is_Cross_File     BOOLEAN,
    N_Sources         INTEGER,
    Origin            VARCHAR
);

-- 5.1 Schritt schreibt Feld
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Link_Role, Link_Subrole, Writer_Kind, Precision, Origin)
SELECT DISTINCT 'data', 'step_writes_field', 'ScriptStep', l.Step_UUID, l.File_Name, 'Field', l.Target_UUID, l.Target_File,
       l.Script_UUID, l.Step_UUID, l.Step_Index, l.Step_ID, l.Is_Enabled, l.Via, l.Link_Role, l.Link_Subrole,
       CASE l.Link_Role WHEN 'imports_to_field' THEN 'import' WHEN 'inputs_to_field' THEN 'input' END,
       'exact', 'v_script_step_links'
FROM v_script_step_links l
WHERE l.Via = 'parameter' AND l.Target_Type = 'Field'
  AND l.Link_Role IN ('sets_field', 'imports_to_field', 'inputs_to_field');

-- 5.2 Schreibschritt ohne bestimmbares Zielfeld (aktives Feld, Set Field By Name)
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Precision, Origin)
SELECT 'data', 'step_writes_dynamic', 'ScriptStep', s.Step_UUID, s.File_Name, 'DynamicTarget', s.Step_UUID || '#target', s.File_Name,
       s.Script_UUID, s.Step_UUID, s.Step_Index, s.Step_ID, s.Is_Enabled, 'dynamic', 'StepsForScripts'
FROM _df_steps s
WHERE (s.Step_ID IN (SELECT Step_ID FROM ScriptStepRoleMap WHERE Link_Role = 'sets_field') OR s.Step_ID = 147)
  AND NOT EXISTS (SELECT 1 FROM v_script_step_links l
                  WHERE l.Step_UUID = s.Step_UUID AND l.File_Name = s.File_Name AND l.Via = 'parameter'
                    AND (l.Target_Type = 'Field' OR l.Link_Role = 'sets_variable'));

-- 5.3 Feld → lesender Schritt (Wert, SQL-Auswahl, SQL-Filter, Steuer-Slot)
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Calculation_UUID, Link_Role, Link_Subrole,
    Sql_Clause, Sql_Column_Pos, Sql_Arg_Pos, Sql_Resolution, Precision, Origin)
SELECT DISTINCT
       CASE WHEN k.Kind = 'select' THEN 'data' WHEN k.Kind = 'value' THEN 'data' ELSE 'control' END,
       CASE k.Kind WHEN 'select' THEN 'field_sql_select_to_step' WHEN 'filter' THEN 'field_sql_filter_to_step'
                   WHEN 'slot' THEN 'field_slot_to_step' ELSE 'field_value_to_step' END,
       'Field', r.Ref_UUID, r.Ref_File, 'ScriptStep', r.Step_UUID, r.File_Name,
       r.Script_UUID, r.Step_UUID, r.Step_Index, r.Step_ID, r.Is_Enabled, r.Via, r.Calculation_UUID,
       r.Link_Role, COALESCE(r.Link_Subrole, CASE WHEN k.Kind = 'slot' THEN r.Slot END),
       CASE k.Kind WHEN 'select' THEN 'select' WHEN 'filter' THEN 'filter' END,
       CASE WHEN k.Kind = 'select' THEN r.Column_Pos END, r.Arg_Pos, r.Resolution,
       CASE WHEN k.Kind = 'select' OR r.Via_CF THEN 'approx' ELSE 'exact' END,
       'v_script_step_links'
FROM _df_ref r,
     LATERAL (SELECT unnest(CASE
         WHEN r.Ref_Class = 'guard' THEN []
         WHEN r.Slot_Ctl THEN ['slot']
         WHEN r.Is_Select AND r.Is_Filter THEN ['select', 'filter']
         WHEN r.Is_Select THEN ['select']
         WHEN r.Is_Filter THEN ['filter']
         ELSE ['value'] END) AS Kind) k
WHERE r.Ref_Kind = 'field' AND r.Usage = 'read';

-- 5.4 Variablen: Setzen (alle Bereiche; bei lokalen nur Anker), globales Lesen
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Calculation_UUID, Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'data', 'step_sets_variable', 'ScriptStep', r.Step_UUID, r.File_Name, 'Variable', r.Ref_UUID, r.Ref_File,
       r.Script_UUID, r.Step_UUID, r.Step_Index, r.Step_ID, r.Is_Enabled, r.Via, r.Calculation_UUID,
       r.Link_Role, r.Link_Subrole, CASE WHEN r.Via_CF THEN 'approx' ELSE 'exact' END, 'v_script_step_links'
FROM _df_ref r
WHERE r.Ref_Kind = 'variable' AND r.Usage = 'set';

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Calculation_UUID, Link_Role, Link_Subrole,
    Sql_Clause, Precision, Origin)
SELECT DISTINCT CASE WHEN r.Ref_Class = 'data' THEN 'data' ELSE 'control' END,
       CASE WHEN r.Ref_Class = 'data' THEN 'variable_to_step' ELSE 'variable_ctl_to_step' END,
       'Variable', r.Ref_UUID, r.Ref_File, 'ScriptStep', r.Step_UUID, r.File_Name,
       r.Script_UUID, r.Step_UUID, r.Step_Index, r.Step_ID, r.Is_Enabled, r.Via, r.Calculation_UUID,
       r.Link_Role, COALESCE(r.Link_Subrole, CASE WHEN r.Slot_Ctl THEN r.Slot END),
       CASE WHEN r.Is_Filter THEN 'filter' END,
       'approx', 'v_script_step_links'
FROM _df_ref r
WHERE r.Ref_Kind = 'variable' AND r.Usage = 'read' AND r.Ref_Class IN ('data', 'ctl')
  AND (r.Variable_Scope IN ('global', 'superglobal') OR r.Ref_Class = 'ctl');

-- 5.5 lokale Variablen: Setzer → Leser und Leser ohne erreichenden Setzer
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Calculation_UUID, Link_Role, Link_Subrole,
    Variable_UUID, Precision, N_Sources, Origin)
SELECT 'data', 'local_def_use', 'ScriptStep', x.Set_Step, x.File_Name, 'ScriptStep', x.Read_Step, x.File_Name,
       rd.Script_UUID, rd.Step_UUID, rd.Step_Index, rd.Step_ID, TRUE, x.Calculation_UUID, 'reads_variable', x.Reach,
       x.Var_UUID,
       CASE WHEN count(*) OVER (PARTITION BY x.File_Name, x.Read_Step, x.Var_UUID) = 1 THEN 'exact' ELSE 'approx' END,
       x.N_Sources, 'v_script_step_links'
FROM (SELECT File_Name, Script_ID, Var_UUID, Set_Step, Read_Step, any_value(Calculation_UUID) AS Calculation_UUID,
             max(N_Sources) AS N_Sources, min(Reach) AS Reach
      FROM _df_reach GROUP BY ALL) x
JOIN _df_steps rd ON rd.Step_UUID = x.Read_Step AND rd.File_Name = x.File_Name
-- keine Kante eines Schritts auf sich selbst (Let im selben Schritt, Zähler in einer
-- Schleife): sie trägt keine Herkunft, verhindert aber „nicht initialisiert“
WHERE x.Set_Step <> x.Read_Step;

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Calculation_UUID, Link_Role, Variable_UUID, Precision, Origin)
SELECT 'data', 'local_uninitialized', 'Uninitialized', r.Var_UUID || '#uninit', r.File_Name, 'ScriptStep', r.Step_UUID, r.File_Name,
       p.Script_UUID, r.Step_UUID, r.Step_Index, p.Step_ID, TRUE, r.Calculation_UUID, 'reads_variable', r.Var_UUID, 'dynamic',
       'v_script_step_links'
FROM _df_lread r
JOIN _df_path p ON p.Step_UUID = r.Step_UUID AND p.File_Name = r.File_Name
-- erreicht nur der Schritt selbst über die Schleife den Leser (Set Variable [ $x ; $x & … ]
-- ohne Setzer davor), ist die Variable im ersten Durchlauf leer → ebenfalls „nicht
-- initialisiert“; ein Let-Setzer im selben Schritt (Reach forward) initialisiert dagegen
WHERE NOT EXISTS (SELECT 1 FROM _df_reach x WHERE x.File_Name = r.File_Name AND x.Read_Step = r.Step_UUID
                    AND x.Var_UUID = r.Var_UUID
                    AND NOT (x.Set_Step = x.Read_Step AND x.Reach = 'loop'));

-- 5.6 Scriptparameter und -ergebnis
-- Aufrufschritt → Parameter des aufgerufenen Scripts (nur mit Parameter-Formel)
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'data', 'step_passes_param', 'ScriptStep', l.Step_UUID, l.File_Name,
       'ScriptParam', l.Target_UUID || '#param', l.Target_File,
       l.Script_UUID, l.Step_UUID, l.Step_Index, l.Step_ID, l.Is_Enabled, l.Via, l.Link_Role, l.Link_Subrole,
       'exact', 'v_script_step_links'
FROM v_script_step_links l
WHERE l.Link_Role = 'calls_script' AND l.Target_Type = 'Script' AND l.Target_UUID IS NOT NULL
  AND EXISTS (SELECT 1 FROM _df_slot s WHERE s.Step_UUID = l.Step_UUID AND s.File_Name = l.File_Name AND NOT s.Slot_Ctl);

-- Parameter → lesender Schritt im eigenen Script
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Calculation_UUID, Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT CASE WHEN r.Ref_Class = 'data' THEN 'data' ELSE 'control' END,
       CASE WHEN r.Ref_Class = 'data' THEN 'param_to_step' ELSE 'param_ctl_to_step' END,
       'ScriptParam', r.Script_UUID || '#param', r.File_Name, 'ScriptStep', r.Step_UUID, r.File_Name,
       r.Script_UUID, r.Step_UUID, r.Step_Index, r.Step_ID, r.Is_Enabled, r.Via, r.Calculation_UUID,
       r.Link_Role, r.Link_Subrole, CASE WHEN r.Via_CF THEN 'approx' ELSE 'exact' END, 'v_script_step_links'
FROM _df_ref r WHERE r.Ref_Kind = 'param';

-- Exit Script → Ergebnis des Scripts
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Precision, Origin)
SELECT DISTINCT 'data', 'step_returns_result', 'ScriptStep', s.Step_UUID, s.File_Name,
       'ScriptResult', s.Script_UUID || '#result', s.File_Name,
       s.Script_UUID, s.Step_UUID, s.Step_Index, s.Step_ID, s.Is_Enabled, 'exact', 'StepsForScripts'
FROM _df_steps s
WHERE s.Step_ID = 103
  AND EXISTS (SELECT 1 FROM _df_slot c WHERE c.Step_UUID = s.Step_UUID AND c.File_Name = s.File_Name);

-- Ergebnis → lesender Schritt; Paarung: letzter aktiver Aufrufschritt davor
DROP TABLE IF EXISTS _df_calls;
CREATE TEMP TABLE _df_calls AS
SELECT DISTINCT l.File_Name, l.Script_UUID, l.Step_UUID, l.Step_Index, l.Target_UUID, l.Target_File
FROM v_script_step_links l
WHERE l.Link_Role = 'calls_script' AND l.Target_Type = 'Script' AND l.Target_UUID IS NOT NULL AND l.Is_Enabled;

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Calculation_UUID, Link_Role, Link_Subrole,
    Pair_Step_UUID, Precision, Origin)
WITH rd AS (
    SELECT DISTINCT r.*, (SELECT max(c.Step_Index) FROM _df_calls c
                          WHERE c.File_Name = r.File_Name AND c.Script_UUID = r.Script_UUID
                            AND c.Step_Index < r.Step_Index) AS Call_Idx
    FROM _df_ref r WHERE r.Ref_Kind = 'result'
)
SELECT DISTINCT CASE WHEN rd.Ref_Class = 'data' THEN 'data' ELSE 'control' END,
       CASE WHEN rd.Ref_Class = 'data' THEN 'result_to_step' ELSE 'result_ctl_to_step' END,
       'ScriptResult', c.Target_UUID || '#result', c.Target_File, 'ScriptStep', rd.Step_UUID, rd.File_Name,
       rd.Script_UUID, rd.Step_UUID, rd.Step_Index, rd.Step_ID, rd.Is_Enabled, rd.Via, rd.Calculation_UUID,
       rd.Link_Role, rd.Link_Subrole,
       CASE WHEN rd.Call_Idx IS NOT NULL THEN c.Step_UUID END,
       CASE WHEN rd.Call_Idx IS NULL OR rd.Via_CF THEN 'approx' ELSE 'exact' END, 'v_script_step_links'
FROM rd
JOIN _df_calls c ON c.File_Name = rd.File_Name AND c.Script_UUID = rd.Script_UUID
                AND (c.Step_Index = rd.Call_Idx OR (rd.Call_Idx IS NULL AND c.Step_Index > rd.Step_Index));

-- 5.7 Feldformeln, Lookup, Statistik
DROP TABLE IF EXISTS _df_fcalc;
CREATE TEMP TABLE _df_fcalc AS
SELECT Calculation_UUID, File_Name, Owner_UUID, Calc_Role
FROM CalculationsCatalog
WHERE Owner_Type = 'Field' AND Calc_Role IN ('field_calculation', 'auto_enter') AND COALESCE(Is_Enabled, TRUE);

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Calculation_UUID, Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'data', 'field_to_calc', 'Field', vl.Target_UUID, vl.Target_File, 'Calculation', f.Calculation_UUID, f.File_Name,
       f.Calculation_UUID, 'reads_field', NULL, 'exact', 'v_calculation_links'
FROM _df_fcalc f JOIN v_calculation_links vl ON vl.Calculation_UUID = f.Calculation_UUID
WHERE vl.Link_Role = 'reads_field' AND vl.Target_Type = 'Field'
UNION
SELECT DISTINCT 'data', 'field_to_calc', 'Field', u.Ref_UUID, u.Ref_File, 'Calculation', f.Calculation_UUID, f.File_Name,
       f.Calculation_UUID, 'reads_field', 'via_custom_function', 'approx', 'v_calculation_links'
FROM _df_fcalc f
JOIN v_calculation_links vl ON vl.Calculation_UUID = f.Calculation_UUID AND vl.Link_Role = 'calls_customfunction'
JOIN _df_cfuse u ON u.Cf = vl.Target_UUID AND u.File_Name = COALESCE(vl.Target_File, f.File_Name)
                AND u.Use_Kind = 'field';

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Calculation_UUID, Link_Subrole, Precision, Origin)
SELECT 'data', 'calc_to_field', 'Calculation', Calculation_UUID, File_Name, 'Field', Owner_UUID, File_Name,
       Calculation_UUID, CASE Calc_Role WHEN 'auto_enter' THEN 'auto_enter' ELSE 'calc' END, 'exact', 'CalculationsCatalog'
FROM _df_fcalc;

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Link_Role, Precision, Origin)
SELECT DISTINCT 'data', CASE Link_Role WHEN 'lookup_source' THEN 'field_lookup' ELSE 'field_summary' END,
       'Field', Target_UUID, Target_File, 'Field', Source_UUID, Source_File, Link_Role, 'exact', 'ObjectLinks'
FROM ObjectLinks
WHERE Link_Role IN ('lookup_source', 'summarizes_field') AND Source_Type = 'Field' AND Target_Type = 'Field';

-- 5.8 Einstiege
-- Eingabe von Hand: editierbares Feldobjekt, Feld weder Berechnung noch Statistik,
-- Auto-Eingabe ohne Änderungssperre
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Link_Role, Precision, Origin)
SELECT DISTINCT 'entry', 'entry_input', 'LayoutObject', ol.Source_UUID, ol.Source_File, 'Field', ol.Target_UUID, ol.Target_File,
       'displays_field', 'exact', 'ObjectLinks'
FROM ObjectLinks ol
JOIN LayoutObjects lo ON lo.Object_UUID = ol.Source_UUID AND lo.File_Name = ol.Source_File
JOIN FieldsForTables f ON f.Field_UUID = ol.Target_UUID AND f.File_Name = ol.Target_File
WHERE ol.Link_Role = 'displays_field' AND ol.Source_Type = 'LayoutObject'
  AND lo.Entry_Browse = 'allow' AND f.Field_Type = 'Normal' AND NOT COALESCE(f.AutoEnter_ProhibitMod, FALSE);

-- Tastenleiste / Button mit Einzelschritt „Feldwert setzen“
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'entry', 'entry_buttonbar', 'LayoutObject', Source_UUID, Source_File, 'Field', Target_UUID, Target_File,
       Link_Role, Link_Subrole, 'exact', 'ObjectLinks'
FROM ObjectLinks
WHERE Link_Role = 'sets_field' AND Source_Type = 'LayoutObject' AND Target_Type = 'Field';

-- Auto-Eingabe ohne Formel (Seriennummer, Erstellungs-/Änderungswert, feste Daten …):
-- Pseudoknoten AutoEnter je Feld, Art in Link_Subrole. Berechnete Auto-Eingabe läuft
-- über calc_to_field, Nachschlagen über field_lookup.
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Link_Subrole, Precision, Origin)
SELECT DISTINCT 'entry', 'entry_auto_enter', 'AutoEnter', Field_UUID || '#autoenter', File_Name, 'Field', Field_UUID, File_Name,
       AutoEnter_Type, 'exact', 'FieldsForTables'
FROM FieldsForTables
WHERE AutoEnter_Type IS NOT NULL AND AutoEnter_Type NOT IN ('Calculated', 'Looked_up');

-- Import: Quelle als Pseudoknoten, Art und Pfad in Link_Subrole
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'entry', 'entry_import', 'ImportSource', i.Step_UUID || '#import', i.File_Name, 'ScriptStep', i.Step_UUID, i.File_Name,
       s.Script_UUID, s.Step_UUID, s.Step_Index, s.Step_ID, s.Is_Enabled, i.Source_Kind, 'exact', 'ImportStepSources'
FROM ImportStepSources i
JOIN _df_steps s ON s.Step_UUID = i.Step_UUID AND s.File_Name = i.File_Name;

-- Trigger, Buttons, Menüs, Datei-Ereignisse → Script
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'entry', 'triggers_script', Source_Type, Source_UUID, Source_File, 'Script', Target_UUID, Target_File,
       Link_Role, Link_Subrole, 'exact', 'ObjectLinks'
FROM ObjectLinks
WHERE Link_Role = 'triggers_script' AND Target_Type = 'Script';

-- 5.9 Kontrolle: Aufrufe; Script → Schritt nur für Schritte mit Datenkanten
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'control', 'step_calls_script', 'ScriptStep', l.Step_UUID, l.File_Name, 'Script', l.Target_UUID, l.Target_File,
       l.Script_UUID, l.Step_UUID, l.Step_Index, l.Step_ID, l.Is_Enabled, l.Via, l.Link_Role, l.Link_Subrole,
       'exact', 'v_script_step_links'
FROM v_script_step_links l
WHERE l.Link_Role = 'calls_script' AND l.Target_Type = 'Script' AND l.Target_UUID IS NOT NULL;

UPDATE v_dataflow_edges
SET File_Name = CASE WHEN From_Kind = 'ScriptStep' AND From_UUID = Step_UUID THEN From_File
                     WHEN To_Kind = 'ScriptStep' AND To_UUID = Step_UUID THEN To_File END
WHERE Step_UUID IS NOT NULL AND File_Name IS NULL;

DROP TABLE IF EXISTS _df_datasteps;
CREATE TEMP TABLE _df_datasteps AS
SELECT DISTINCT Step_UUID, File_Name FROM v_dataflow_edges
WHERE Step_UUID IS NOT NULL AND Flow_Class IN ('data', 'control', 'entry');

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Precision, Origin)
SELECT 'control', 'script_runs_step', 'Script', s.Script_UUID, s.File_Name, 'ScriptStep', s.Step_UUID, s.File_Name,
       s.Script_UUID, s.Step_UUID, s.Step_Index, s.Step_ID, s.Is_Enabled, 'exact', 'StepsForScripts'
FROM _df_steps s JOIN _df_datasteps d ON d.Step_UUID = s.Step_UUID AND d.File_Name = s.File_Name;

-- 5.10 Bedingungen: v_step_guards + Steuerkanten der Bedingungsbezüge
-- Umfang der Bedingungs-Sicht: Schritte mit Datenkanten (_df_datasteps) UND aktive
-- Ablaufschritte — Script-Aufrufe und Navigation (calls_script, navigates_to_layout,
-- navigates_to_to aus v_script_step_links). Den Ablauf-Trace interessiert, unter welcher
-- Bedingung ein Aufruf oder ein Go to Layout (Kaskaden-Auslöser) steht; ein Go to Layout
-- ohne Formel hat keine Datenkante. Die Kanten script_runs_step (oben) und die
-- Bedingungs-Steuerkanten (unten) bleiben bewusst auf _df_datasteps — sonst änderte der
-- größere Umfang den Datenfluss-Trace.
DROP TABLE IF EXISTS _df_guardsteps;
CREATE TEMP TABLE _df_guardsteps AS
SELECT Step_UUID, File_Name FROM _df_datasteps
UNION
SELECT DISTINCT Step_UUID, File_Name FROM v_script_step_links
WHERE Is_Enabled AND Link_Role IN ('calls_script', 'navigates_to_layout', 'navigates_to_to');

DROP TABLE IF EXISTS v_step_guards;
-- Je Schritt aus _df_guardsteps: der eigene Zweig jeder umschließenden If-Kette (If, Else If
-- oder Else) und jede umschließende Schleife. Vorherige Zweige derselben Kette (deren
-- Bedingung falsch sein muss) und Exit Loop If einer Schleife werden NICHT je Schritt
-- materialisiert — lange Else-If-Ketten machten daraus quadratisch viele Zeilen
-- (in einer großen Lösung 791 138); sie ergeben sich aus Chain_Open_Index bzw. Block_End_Index
-- (alle Kettenschritte bzw. Exit-Loop-If-Schritte zwischen Öffner und Schritt).
CREATE TABLE v_step_guards AS
WITH g AS (
    SELECT p.File_Name, p.Script_ID, p.Script_UUID, p.Step_UUID, p.Step_Index,
           b.B_Start AS Guard_Step_Index, b.Opener_Step_ID AS Guard_Step_ID,
           CASE b.Opener_Step_ID WHEN 68 THEN 'if' WHEN 125 THEN 'elseif' WHEN 69 THEN 'else' ELSE 'loop' END AS Guard_Kind,
           CASE WHEN b.Block_Kind = 'branch' THEN b.Chain_Open END AS Chain_Open_Index,
           b.B_End AS Block_End_Index
    FROM _df_path p
    JOIN _df_guardsteps d ON d.Step_UUID = p.Step_UUID AND d.File_Name = p.File_Name
    JOIN _df_blocks b ON b.File_Name = p.File_Name AND b.Script_ID = p.Script_ID
                     AND list_contains(p.Path, b.Block_ID)
)
SELECT g.File_Name, g.Script_ID, g.Script_UUID, g.Step_UUID, g.Step_Index,
       g.Guard_Step_Index, g.Guard_Step_ID, gs.Step_UUID AS Guard_Step_UUID, g.Guard_Kind,
       g.Chain_Open_Index, NULLIF(g.Block_End_Index, 2147483647) AS Block_End_Index,
       ROW_NUMBER() OVER (PARTITION BY g.File_Name, g.Step_UUID ORDER BY g.Guard_Step_Index) AS Guard_Level,
       (SELECT min(c.Calculation_UUID) FROM CalculationsCatalog c
        WHERE c.Owner_UUID = gs.Step_UUID AND c.File_Name = gs.File_Name AND c.Owner_Type = 'ScriptStep') AS Guard_Calculation_UUID
FROM g
JOIN _df_ctl gs ON gs.File_Name = g.File_Name AND gs.Script_ID = g.Script_ID AND gs.Step_Index = g.Guard_Step_Index;

CREATE INDEX idx_step_guards_step ON v_step_guards (Step_UUID, File_Name);

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Calculation_UUID, Link_Role, Link_Subrole,
    Guard_Step_Index, Precision, Origin)
SELECT DISTINCT 'control',
       CASE r.Ref_Kind WHEN 'field' THEN 'field_guards_step' WHEN 'variable' THEN 'variable_guards_step'
                       WHEN 'param' THEN 'param_guards_step' ELSE 'result_guards_step' END,
       CASE r.Ref_Kind WHEN 'field' THEN 'Field' WHEN 'variable' THEN 'Variable'
                       WHEN 'param' THEN 'ScriptParam' ELSE 'ScriptResult' END,
       CASE r.Ref_Kind WHEN 'param' THEN r.Script_UUID || '#param' WHEN 'result' THEN NULL ELSE r.Ref_UUID END,
       CASE WHEN r.Ref_Kind IN ('param', 'result') THEN r.File_Name ELSE r.Ref_File END,
       'ScriptStep', g.Step_UUID, g.File_Name,
       g.Script_UUID, g.Step_UUID, g.Step_Index, s.Step_ID, TRUE, r.Calculation_UUID, r.Link_Role,
       g.Guard_Kind,
       g.Guard_Step_Index, CASE WHEN r.Via_CF THEN 'approx' ELSE 'exact' END, 'v_step_guards'
FROM v_step_guards g
-- nur Schritte mit Datenkanten: die Ablaufschritte im Umfang von v_step_guards erzeugen
-- keine Bedingungs-Steuerkanten (Datenfluss-Trace unverändert)
JOIN _df_datasteps d ON d.Step_UUID = g.Step_UUID AND d.File_Name = g.File_Name
JOIN _df_ref r ON r.Step_UUID = g.Guard_Step_UUID AND r.File_Name = g.File_Name AND r.Ref_Class = 'guard'
JOIN _df_steps s ON s.Step_UUID = g.Step_UUID AND s.File_Name = g.File_Name
WHERE r.Ref_Kind <> 'result'
  -- nur die Bedingung des eigenen Zweigs (If, Else If); vorherige Zweige und Exit Loop
  -- If (Bedingung muss falsch sein) ergeben sich aus v_step_guards zum Nachladen
  AND g.Guard_Kind IN ('if', 'elseif');

-- 5.11 Senken (nur Verwendungsrichtung, immer Blatt)
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'sink',
       CASE WHEN Link_Role IN ('displays_field', 'reads_field') THEN 'sink_display'
            WHEN Link_Role IN ('left_field', 'right_field') THEN 'sink_relationship'
            WHEN Link_Role = 'source_field' THEN 'sink_valuelist'
            WHEN Link_Role = 'sorts_by_field' THEN 'sink_sort'
            WHEN Link_Role = 'exports_from_field' THEN 'sink_export'
            ELSE 'sink_privilege' END,
       'Field', Target_UUID, Target_File, Source_Type, Source_UUID, Source_File, Link_Role, Link_Subrole, 'exact', 'ObjectLinks'
FROM ObjectLinks
WHERE Target_Type = 'Field'
  AND ((Source_Type IN ('Layout', 'LayoutObject') AND Link_Role IN ('displays_field', 'reads_field', 'sorts_by_field', 'exports_from_field'))
    OR (Source_Type = 'Relationship' AND Link_Role IN ('left_field', 'right_field'))
    OR (Source_Type = 'ValueList' AND Link_Role = 'source_field')
    OR (Source_Type = 'PrivilegeSet' AND Link_Role = 'reads_field'));

INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Script_UUID, Step_UUID, Step_Index, Step_ID, Is_Enabled, Via, Link_Role, Link_Subrole, Precision, Origin)
SELECT DISTINCT 'sink',
       CASE l.Link_Role WHEN 'exports_from_field' THEN 'sink_export' WHEN 'sorts_by_field' THEN 'sink_sort'
                        WHEN 'finds_in_field' THEN 'sink_find' ELSE 'sink_navigate' END,
       'Field', l.Target_UUID, l.Target_File, 'ScriptStep', l.Step_UUID, l.File_Name,
       l.Script_UUID, l.Step_UUID, l.Step_Index, l.Step_ID, l.Is_Enabled, l.Via, l.Link_Role, l.Link_Subrole,
       'exact', 'v_script_step_links'
FROM v_script_step_links l
WHERE l.Target_Type = 'Field' AND l.Via = 'parameter'
  AND l.Link_Role IN ('exports_from_field', 'sorts_by_field', 'finds_in_field', 'navigates_to_field');

-- Variable in Layout-Objekten (Ausblenden, Formatierung, Beschriftung …): Anzeige
INSERT INTO v_dataflow_edges (Flow_Class, Flow_Kind, From_Kind, From_UUID, From_File, To_Kind, To_UUID, To_File,
    Link_Role, Precision, Origin)
SELECT DISTINCT 'sink', 'sink_display', 'Variable', Target_UUID, Target_File, Source_Type, Source_UUID, Source_File,
       Link_Role, 'exact', 'ObjectLinks'
FROM ObjectLinks
WHERE Target_Type = 'Variable' AND Source_Type IN ('LayoutObject', 'Layout')
  AND Link_Role IN ('reads_variable', 'displays_variable');

-- 5.12 Schreibart und Datenquelle der Schreibschritte
-- No_Data_Source: keine Daten- oder Einstiegskante in den Schritt (Konstante, leerer
-- Text, Formel ohne Feld/Variable/Parameter/Ergebnis). Writer_Kind: input/import aus
-- der Rolle, sonst value (mit Quelle), reset (alle Wert-Formeln sind ""), constant.
UPDATE v_dataflow_edges
SET File_Name = CASE WHEN From_Kind = 'ScriptStep' AND From_UUID = Step_UUID THEN From_File
                     WHEN To_Kind = 'ScriptStep' AND To_UUID = Step_UUID THEN To_File END
WHERE Step_UUID IS NOT NULL AND File_Name IS NULL;

DROP TABLE IF EXISTS _df_fed;
CREATE TEMP TABLE _df_fed AS
SELECT DISTINCT To_UUID AS Step_UUID, To_File AS File_Name
FROM v_dataflow_edges
WHERE Flow_Class IN ('data', 'entry') AND To_Kind = 'ScriptStep';

DROP TABLE IF EXISTS _df_reset;
CREATE TEMP TABLE _df_reset AS
SELECT Step_UUID, File_Name, bool_and(regexp_matches(COALESCE(Formula_Text, ''), '^\s*""\s*$')) AS All_Empty
FROM _df_slot WHERE NOT Slot_Ctl
GROUP BY ALL;

UPDATE v_dataflow_edges e
SET No_Data_Source = NOT EXISTS (SELECT 1 FROM _df_fed f WHERE f.Step_UUID = e.Step_UUID AND f.File_Name = e.File_Name)
WHERE e.Flow_Kind IN ('step_writes_field', 'step_writes_dynamic');

UPDATE v_dataflow_edges e
SET Writer_Kind = CASE
        WHEN NOT e.No_Data_Source THEN 'value'
        WHEN COALESCE((SELECT r.All_Empty FROM _df_reset r
                       WHERE r.Step_UUID = e.Step_UUID AND r.File_Name = e.File_Name), FALSE) THEN 'reset'
        ELSE 'constant' END
WHERE e.Flow_Kind IN ('step_writes_field', 'step_writes_dynamic') AND e.Writer_Kind IS NULL;

UPDATE v_dataflow_edges SET Is_Cross_File = (From_File IS DISTINCT FROM To_File);

CREATE INDEX idx_dataflow_to   ON v_dataflow_edges (To_UUID, To_File);
CREATE INDEX idx_dataflow_from ON v_dataflow_edges (From_UUID, From_File);
CREATE INDEX idx_dataflow_step ON v_dataflow_edges (Step_UUID, File_Name);

-- --------------------------------------------
-- 6. v_check_dataflow_edges — Vollständigkeit (eine Zeile)
-- --------------------------------------------
-- writes_missing_n  schreibende Schritt-Zeile aus v_script_step_links ohne step_writes_field
-- var_missing_n     Variablen-Zeile aus v_script_step_links (ohne Bedingungsschritte und
--                   ohne Lesen in deaktivierten Schritten) ohne
--                   passende Kante (Setzen, globales/Steuer-Lesen, lokales Lesen über
--                   local_def_use oder local_uninitialized)
-- unknown_node_n    Kanten-Ende eines Katalog-Typs (Field, ScriptStep, Script, Variable,
--                   LayoutObject, Calculation) ohne Katalogobjekt in der Datei; offene
--                   Enden (Datei NULL) zählen nicht
-- dup_n             vollständig doppelte Zeilen
-- foreign_var_n     Kante zwischen einem Schritt und einer globalen Variable einer anderen
--                   Datei (globale Variablen gelten je Datei; Hinweis auf vermischte
--                   Klon-Dateien, z. B. CF-Auflösung ohne Datei)
CREATE OR REPLACE VIEW v_check_dataflow_edges AS
WITH w AS (
    SELECT DISTINCT l.Step_UUID, l.File_Name, l.Target_UUID, l.Target_File
    FROM v_script_step_links l
    WHERE l.Via = 'parameter' AND l.Target_Type = 'Field'
      AND l.Link_Role IN ('sets_field', 'imports_to_field', 'inputs_to_field')
),
wm AS (
    SELECT w.* FROM w ANTI JOIN v_dataflow_edges e
      ON e.Flow_Kind = 'step_writes_field' AND e.Step_UUID = w.Step_UUID AND e.File_Name = w.File_Name
     AND e.To_UUID = w.Target_UUID AND e.To_File IS NOT DISTINCT FROM w.Target_File
),
v AS (
    SELECT DISTINCT l.Step_UUID, l.File_Name, l.Target_UUID, l.Link_Role
    FROM v_script_step_links l
    WHERE l.Target_Type = 'Variable' AND l.Step_ID NOT IN (68, 125, 72)
      -- deaktivierte Schritte: kein Walk, keine Setzer-Erreichbarkeit
      AND (l.Is_Enabled OR l.Link_Role = 'sets_variable')
),
vm AS (
    SELECT v.* FROM v ANTI JOIN v_dataflow_edges e
      ON e.Step_UUID = v.Step_UUID AND e.File_Name = v.File_Name
     AND ((v.Link_Role = 'sets_variable' AND e.Flow_Kind = 'step_sets_variable' AND e.To_UUID = v.Target_UUID)
       OR (v.Link_Role = 'reads_variable' AND e.Flow_Kind IN ('variable_to_step', 'variable_ctl_to_step') AND e.From_UUID = v.Target_UUID)
       OR (v.Link_Role = 'reads_variable' AND e.Flow_Kind IN ('local_def_use', 'local_uninitialized') AND e.Variable_UUID = v.Target_UUID)
       -- Lesen nach einer Let-Zuweisung im selben Schritt (keine Kante auf sich selbst)
       OR (v.Link_Role = 'reads_variable' AND e.Flow_Kind = 'step_sets_variable' AND e.To_UUID = v.Target_UUID
           AND e.Link_Subrole = 'let_assign'))
),
ends AS (
    SELECT From_Kind AS K, From_UUID AS U, From_File AS F FROM v_dataflow_edges
    UNION
    SELECT To_Kind, To_UUID, To_File FROM v_dataflow_edges
),
unk AS (
    SELECT e.* FROM ends e
    WHERE e.K IN ('Field', 'ScriptStep', 'Script', 'Variable', 'LayoutObject', 'Calculation') AND e.F IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM ObjectCatalog o WHERE o.Object_UUID = e.U AND o.File_Name = e.F)
),
fv AS (
    SELECT e.* FROM v_dataflow_edges e
    JOIN (SELECT DISTINCT md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) AS U
          FROM VariablesCatalog WHERE Variable_Scope = 'global') g
      ON g.U = CASE WHEN e.From_Kind = 'Variable' THEN e.From_UUID WHEN e.To_Kind = 'Variable' THEN e.To_UUID END
    WHERE e.File_Name IS NOT NULL
      AND e.File_Name IS DISTINCT FROM CASE WHEN e.From_Kind = 'Variable' THEN e.From_File ELSE e.To_File END
),
dup AS (
    SELECT (SELECT COUNT(*) FROM v_dataflow_edges)
         - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM v_dataflow_edges)) AS n
)
SELECT
    (SELECT COUNT(*) FROM v_dataflow_edges)  AS edges_n,
    (SELECT COUNT(*) FROM wm)                AS writes_missing_n,
    (SELECT COUNT(*) FROM vm)                AS var_missing_n,
    (SELECT COUNT(*) FROM unk)               AS unknown_node_n,
    (SELECT n FROM dup)                      AS dup_n,
    (SELECT COUNT(*) FROM fv)                AS foreign_var_n,
    (SELECT string_agg(K || '×' || n, ', ' ORDER BY n DESC)
     FROM (SELECT K, COUNT(*) AS n FROM unk GROUP BY K)) AS unknown_detail;

-- --------------------------------------------
-- 7. Aufräumen
-- --------------------------------------------
DROP TABLE IF EXISTS _df_steps;
DROP TABLE IF EXISTS _df_slot;
DROP TABLE IF EXISTS _df_var;
DROP TABLE IF EXISTS _df_sql;
DROP TABLE IF EXISTS _df_ctl;
DROP TABLE IF EXISTS _df_if;
DROP TABLE IF EXISTS _df_blocks;
DROP TABLE IF EXISTS _df_path;
DROP TABLE IF EXISTS _df_cfclose;
DROP TABLE IF EXISTS _df_cfuse;
DROP TABLE IF EXISTS _df_ref;
DROP TABLE IF EXISTS _df_lset;
DROP TABLE IF EXISTS _df_lread;
DROP TABLE IF EXISTS _df_kill;
DROP TABLE IF EXISTS _df_reach;
DROP TABLE IF EXISTS _df_calls;
DROP TABLE IF EXISTS _df_fcalc;
DROP TABLE IF EXISTS _df_datasteps;
DROP TABLE IF EXISTS _df_guardsteps;
DROP TABLE IF EXISTS _df_fed;
DROP TABLE IF EXISTS _df_reset;
