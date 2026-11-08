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
--   - v_table_occurrence_usage  MATERIALIZED: jede Fundstelle einer Table Occurrence
--                          (TO × nutzendes Objekt × Kategorie × Rolle), Schema 1.38.0
--   - v_table_occurrence_class  MATERIALIZED: eine Zeile je TO — Nutzungsklasse aus
--                          Zählung + Pfadanalyse im Beziehungsgraphen, Schema 1.38.0
--   - v_object_usage       MATERIALIZED: eine Zeile je Objekt (Field, Script, Layout,
--                          CustomFunction, ValueList, BaseTable, ExternalDataSource,
--                          PrivilegeSet, TableOccurrence, Relationship) — Nutzungszahlen,
--                          Marker und Nutzungsklasse, Schema 1.40.0

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
-- sql_name_wrappers — Registry der SQL-Namensauflösungs-CFs (AP-4 / D-5)
-- --------------------------------------------
-- FileMakers ExecuteSQL nimmt die Abfrage als STRING; Feld-/Tabellennamen darin sind
-- normal reiner Text (im Where-Used unsichtbar). Disziplinierte Lösungen kapseln die
-- Bezeichner in CFs, die das Feld als echtes Argument übergeben (→ es erscheint als
-- FieldRef → reads_field). Diese Wrapper-Namen sind NICHT standardisiert — jede Lösung
-- darf eigene verwenden. Darum eine konfigurierbare Liste (Single Source of Truth,
-- zunächst im Code; später auf externe Config erweiterbar). Wrapper_Role:
--   field_name = liefert den SQL-Feldnamen aus einer FieldReference
--   table_name = liefert den SQL-TO-/Tabellennamen
--   quote/cast = neutral, nur Signal „ist SQL-Kontext"
DROP TABLE IF EXISTS sql_name_wrappers;
CREATE TABLE sql_name_wrappers (Wrapper_CF VARCHAR, Wrapper_Role VARCHAR);
INSERT INTO sql_name_wrappers VALUES
    ('__GetNameField', 'field_name'),
    ('__GetNameTable', 'table_name'),
    ('__SQLQuote',     'quote'),
    ('_SQL_Decimal',   'cast');

-- --------------------------------------------
-- v_sql_field_usage — Felder, die eine SQL-Abfrage speisen
-- --------------------------------------------
-- Beantwortet „welche Felder speist eine ExecuteSQL-Abfrage (und in welchem Objekt)?".
-- Eine Berechnung gilt als SQL-Kontext, wenn sie die Built-in-Funktion ExecuteSQL ODER
-- einen registrierten Wrapper-CF aufruft. Die Feldbezüge sind (im gekapselten Fall)
-- bereits als reads_field im Graphen — diese View liefert den fehlenden Herkunfts-
-- Marker „SQL". (Literal-SQL-Heuristik: in dieser Lösung 0 Fälle, da SQL
-- durchgängig CF-gekapselt gebaut wird — kein literales FROM/JOIN im Chunk-Text.)
DROP VIEW IF EXISTS v_sql_field_usage;
CREATE VIEW v_sql_field_usage AS
WITH sql_calcs AS (
    SELECT DISTINCT d.Calc_UUID, d.File_Name
    FROM DDR_Calculations d
    WHERE (d.Chunk_Type = 'FunctionRef'
           AND regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) = 'ExecuteSQL')
       OR (d.Chunk_Type = 'CustomFunctionRef'
           AND regexp_extract(d.Chunk_Content, '>([^<]+)</Chunk>', 1) IN (SELECT Wrapper_CF FROM sql_name_wrappers))
),
field_refs AS (
    SELECT
        va.Owner_Type, va.Owner_UUID, va.Owner_Name, va.Owner_File, va.Kind_Label,
        sc.Calc_UUID,
        regexp_extract(d.Chunk_Content, 'FieldReference[^>]*name="([^"]+)"', 1)                    AS Field_Name,
        regexp_extract(d.Chunk_Content, 'FieldReference[^>]*UUID="([^"]+)"', 1)                    AS Raw_Field_UUID,
        TRY_CAST(regexp_extract(d.Chunk_Content, 'FieldReference[^>]*id="([0-9]+)"', 1) AS BIGINT) AS Field_Ref_ID,
        NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*name="([^"]+)"', 1), '') AS TO_Name,
        NULLIF(regexp_extract(d.Chunk_Content, 'TableOccurrenceReference[^>]*UUID="([^"]+)"', 1), '') AS TO_Ref_UUID
    FROM sql_calcs sc
    JOIN DDR_Calculations d
          ON d.Calc_UUID = sc.Calc_UUID AND d.File_Name = sc.File_Name AND d.Chunk_Type = 'FieldRef'
    LEFT JOIN v_calc_anchors va
           ON va.Calc_UUID = sc.Calc_UUID AND va.Owner_File = sc.File_Name
)
-- Field_UUID: FileMakers rohe FieldReference/@UUID im DDR-Chunk ist kontext-spezifisch
-- (pro Feld×TableOccurrence) und stimmt nur bei der Home-TO (TO-Name = Basistabelle) mit
-- der Katalog-UUID überein. Über related TOs ist sie synthetisch und in keinem Katalog →
-- der Detail-Klick im Frontend lief sonst auf „Object not found". Deshalb über die TO-
-- Referenz (→ Basistabelle + Home_File, via TableOccurrenceResolution) + Feld-ID auf die
-- echte Katalog-UUID auflösen (Feld-ID ist entity-frei, fängt auch webbed-kodierte Namen).
-- Fallback = rohe UUID (Home-TO-Fall bzw. nicht auflösbar).
SELECT DISTINCT
    fr.Owner_Type, fr.Owner_UUID, fr.Owner_Name, fr.Owner_File, fr.Kind_Label,
    fr.Calc_UUID,
    fr.Field_Name,
    COALESCE(f_canon.Field_UUID, fr.Raw_Field_UUID) AS Field_UUID,
    fr.TO_Name
FROM field_refs fr
LEFT JOIN TableOccurrenceResolution tor
       ON tor.TO_UUID = fr.TO_Ref_UUID AND tor.File_Name = fr.Owner_File
LEFT JOIN FieldsForTables f_canon
       ON f_canon.Table_Name = tor.Canonical_BT_Name
      AND f_canon.File_Name = tor.Home_File
      AND f_canon.Field_ID = fr.Field_Ref_ID;

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
-- dynamische Referenzen (GetField, Evaluate, Namen in SQL-Strings) sind unsichtbar.
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
