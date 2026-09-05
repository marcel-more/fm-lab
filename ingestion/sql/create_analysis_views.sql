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
    -- ohne offenes If. Die unbalanced-if-Rule braucht dieses negative Signal,
    -- das if_depth_after (geclampt) bewusst verschluckt.
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
        WHEN c.Calc_Kind_Raw = 'Hide'               THEN 'Hide Condition'
        WHEN c.Calc_Kind_Raw = 'Tooltip'            THEN 'Tooltip'
        WHEN c.Calc_Kind_Raw = 'Label'              THEN 'Calculated Label'
        WHEN c.Calc_Kind_Raw = 'action'             THEN 'Button Action'
        WHEN c.Calc_Kind_Raw = 'Portal'             THEN 'Portal Filter'
        WHEN c.Calc_Kind_Raw = 'WebViewer'          THEN 'Web Viewer URL'
        WHEN c.Calc_Kind_Raw = 'Placeholder'        THEN 'Placeholder Text'
        WHEN c.Calc_Kind_Raw = 'TabPanel'           THEN 'Tab Title'
        WHEN c.Calc_Kind_Raw = 'PopoverPanel'       THEN 'Popover Title'
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
-- v_sql_field_usage — Felder, die eine SQL-Abfrage speisen (AP-4A)
-- --------------------------------------------
-- Beantwortet „welche Felder speist eine ExecuteSQL-Abfrage (und in welchem Objekt)?".
-- Eine Berechnung gilt als SQL-Kontext, wenn sie die Built-in-Funktion ExecuteSQL ODER
-- einen registrierten Wrapper-CF aufruft. Die Feldbezüge sind (im gekapselten Fall)
-- bereits als reads_field im Graphen — diese View liefert den fehlenden Herkunfts-
-- Marker „SQL". (Literal-SQL-Heuristik, Plan AP-4b: in dieser Lösung 0 Fälle, da SQL
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
