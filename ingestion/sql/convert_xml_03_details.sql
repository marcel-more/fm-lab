/*
-- convert_xml_03_details.sql — Phase 3 der XML-Konvertierungs-Pipeline.
-- Spezial-Parser: Variablen-Analyse + strukturelle Detail-Tabellen.
-- Erzeugt VariableUsages + VariablesCatalog aus DDR-Chunks, Set-Variable-Steps,
-- MBS-Superglobalen, Merge-Variablen, Trigger-Parametern und Regex-Fallback;
-- außerdem StepCalculations (A.9), abgeleitete Step-/Layout-Spalten (A.10/A.11)
-- und LayoutObjectConditions (A.12, Conditional-Formatting-Regeln).
-- TABLE-ONLY (liest nur P1/P2-Tabellen, kein read_xml). Läuft nach Phase 2 und
-- VOR Phase 4 (ObjectCatalog registriert die Variablen-Objekte; P4 füllt den
-- Calculation_UUID-FK von LayoutObjectConditions).
-- Ausgekoppelt aus create_universal_catalogs.sql (Phase A, Logik unverändert).
*/

-- ############################################################
-- webbed wird für html_unescape() benötigt (Decode der XML-Entities in
-- DDR-Chunk-abgeleiteten Variablennamen, z.B. `$$__Kontoausz&#xFC;ge` → `…üge`).
INSTALL webbed FROM community;
LOAD webbed;

-- Workaround-Disable-Flag (Version-Check-Registry ingestion/version_check.json,
-- Capability fragment_utf8/#108 → wa_entity_decode, Default ON). Gatet den html_unescape-
-- Decode der Variable_Name-Extraktion unten. Idempotent → identitaets-neutral solange ON.
SET VARIABLE wa_entity_decode = true;

-- Workaround-Disable-Flag (Registry-Capability sax_attr_entities → wa_attr_unescape,
-- Default ON). Gatet den zweiten html_unescape-Pass der Inserted_Text-Ableitung unten:
-- der webbed-SAX-Serializer doppel-escaped numerische Char-Refs im Attribut-@value
-- (Quelle `&#38;` → Roh-Step_XML `&amp;#38;`), sodass xml_extract_text nur EINMAL
-- dekodiert und `&#38;` stehen bleibt. DOM schreibt `&amp;` → bereits `&` → der
-- zweite Pass ist dort No-op (idempotent, identitaets-neutral solange ON). OFF, sobald
-- webbed SAX-Attribut-Entities selbst DOM-treu serialisiert.
SET VARIABLE wa_attr_unescape = true;

-- Phase 0: XML-Referenzen (erstellt von convert_xml.sql)
-- ############################################################
-- XMLLayoutReferences und XMLStepReferences werden direkt in
-- convert_xml.sql per xml_extract_text() erzeugt.
-- Kein Python-Script oder CSV-Import mehr nötig.


-- ############################################################
-- Phase A: Variablen-Parser
-- ############################################################
-- Erstellt VariableUsages + VariablesCatalog aus:
-- 1. DDR_Calculations VariableReference Chunks (primär)
-- 2. StepsForScripts Set Variable Schritte
-- 3. MBS Superglobale (Regex auf Calculation_Text)
-- 4. Merge-Variables aus LayoutObjects
-- 5. Regex-Fallback für Dateien ohne DDR
-- ############################################################


-- ========================================
-- A.1: VariableUsages Tabelle
-- ========================================

DROP TABLE IF EXISTS VariableUsages;

CREATE TABLE VariableUsages (
    Variable_Name VARCHAR NOT NULL,
    Variable_Scope VARCHAR NOT NULL,       -- global, local, superglobal, let_local
    Usage_Type VARCHAR NOT NULL,           -- set, read
    Context_Type VARCHAR NOT NULL,         -- script_step, calculation, auto_enter_calc, custom_function, layout_object
    Context_UUID VARCHAR,
    Context_Name VARCHAR,
    Script_Name VARCHAR,
    Script_UUID VARCHAR,
    Step_Index BIGINT,
    Table_Name VARCHAR,
    Field_Name VARCHAR,
    Calc_Hash VARCHAR,
    Source VARCHAR NOT NULL,               -- set_variable_step, ddr_chunk, mbs_variable_call, merge_variable, regex_fallback
    File_Name VARCHAR NOT NULL
);


-- ========================================
-- A.2: Chunk_Type in DDR_Calculations materialisieren
-- ========================================

UPDATE DDR_Calculations
SET Chunk_Type = regexp_extract(Chunk_Content, '<Chunk type="([^"]+)"', 1)
WHERE Chunk_Type IS NULL
  AND Chunk_Content IS NOT NULL;


-- ========================================
-- A.3: DDR VariableReference Chunks → VariableUsages
-- ========================================
-- Vorab-Aggregation: pro (Calc_Hash, File_Name, Variable_Name) genau eine Zeile.
-- Verhindert Inflation durch (a) mehrfache Verwendung derselben Variable in einer
-- Formel (mehrere Chunk-Rows) und (b) shared Calc_Hashes über mehrere Calc_UUIDs
-- (z.B. wenn viele Felder dieselbe Formel haben → identischer Hash).

-- DisplayCalculations-Anker-Hashes (Schema 1.27.0): Ausschluss-Menge für die
-- %X:-Fehlchunks (s. u.). Konservativ über den Anker-Suffix bestimmt — nur
-- Hashes, die (auch) an einem DisplayCalculations-Anker hängen.
DROP TABLE IF EXISTS _display_calc_hashes;
CREATE TEMP TABLE _display_calc_hashes AS
SELECT DISTINCT File_Name, Calc_Hash
FROM DDR_Calculations
WHERE Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\';

DROP TABLE IF EXISTS _DDR_VarRefs_Distinct;
CREATE TEMP TABLE _DDR_VarRefs_Distinct AS
SELECT DISTINCT
    Calc_Hash,
    File_Name,
    -- html_unescape: Roh-Chunks tragen un-dekodierte XML-Entities (`Datens&#xE4;tze`);
    -- ohne Decode landen sie in VariableUsages/VariablesCatalog und den md5-UUIDs (P4).
    -- wa_entity_decode-gegatet (Default ON): OFF → Roh-Wert ohne Decode.
    -- %X:-Präfix-Strip (2.20.0): eine typisierte Layoutformel mit einzelner
    -- VARIABLEN-Referenz (<<ƒ:%N:$$var>>) chunked FileMaker als
    -- VariableReference '%N:$$var' — hinter dem Präfix steht eine ECHTE
    -- Variable (FileMaker selbst klassifiziert sie so, nur der Ergebnistyp
    -- klebt davor). Display-Kontext-gegated wie der Ausschluss unten;
    -- fixture-verifiziert (Merge Fields, Layout Fixtures).
    CASE WHEN regexp_matches(regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:\$')
              AND (File_Name, Calc_Hash) IN (SELECT (File_Name, Calc_Hash) FROM _display_calc_hashes)
         THEN regexp_replace(
                  CASE WHEN getvariable('wa_entity_decode')
                       THEN html_unescape(regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1))
                       ELSE regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1) END,
                  '^%[A-Z]+:', '')
         ELSE CASE WHEN getvariable('wa_entity_decode')
                   THEN html_unescape(regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1))
                   ELSE regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1) END
    END as Variable_Name
FROM DDR_Calculations
WHERE Chunk_Type = 'VariableReference'
  AND regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1) IS NOT NULL
  -- FileMaker schreibt bei beim Export FEHLENDER Plugin-Funktion den Platzhalter
  -- <Chunk type="VariableReference">Function Missing</Chunk> — das ist KEINE Variable.
  -- Ohne Ausschluss landet 'Function Missing' als let_local in VariableUsages/
  -- VariablesCatalog/ObjectCatalog und maskiert die eigentliche Info (Plugin fehlte).
  -- Literal (englisch, kein Präfix/keine Entities) → Roh-Extract-Vergleich ist locale-
  -- robust; kein reales Variablenobjekt heißt exakt so (korpus-verifiziert). Die Zahl
  -- der so verworfenen Chunks meldet P6 als Info-Finding (v_check_function_missing).
  AND regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1) <> 'Function Missing'
  -- %X:-Fehlchunks aus DisplayCalculations (Schema 1.27.0): FileMaker chunked
  -- typisierte Layoutformeln mit einzelner Feldreferenz (<<ƒ:%N:Zahl>>) als
  -- VariableReference '%N:Zahl' — Ergebnistyp-Präfix + Feldname, KEINE Variable.
  -- Ohne Ausschluss entstehen Phantom-Variablen (let_local) in VariableUsages/
  -- VariablesCatalog/ObjectCatalog. Konservativ auf den DisplayCalculations-
  -- Kontext beschränkt (Hash-Menge der Anker); die Feldreferenz rettet P2
  -- A.5.1b, die Zahl der verworfenen Chunks meldet P6 als Info-Finding
  -- (v_check_display_prefix_chunks). Präfix + '$' bleibt DRIN (echte Variable
  -- hinter dem Ergebnistyp — Präfix-Strip oben, 2.20.0).
  AND NOT (regexp_matches(regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:')
           AND NOT regexp_matches(regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:\$')
           AND (File_Name, Calc_Hash) IN (SELECT (File_Name, Calc_Hash) FROM _display_calc_hashes));

-- 3a: Variablen in Calculated Fields (FieldsForTables.DDR_Hash)
INSERT INTO VariableUsages
SELECT
    vr.Variable_Name,
    CASE
        WHEN vr.Variable_Name LIKE '$$$%' THEN 'superglobal'  -- wie P2, sonst Identitäts-Split
        WHEN vr.Variable_Name LIKE '$$%' THEN 'global'
        WHEN vr.Variable_Name LIKE '$%' THEN 'local'
        ELSE 'let_local'
    END as Variable_Scope,
    'read' as Usage_Type,
    'calculation' as Context_Type,
    f.Field_UUID as Context_UUID,
    f.Table_Name || '::' || f.Field_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    f.Table_Name,
    f.Field_Name,
    vr.Calc_Hash,
    'ddr_chunk' as Source,
    vr.File_Name
FROM _DDR_VarRefs_Distinct vr
JOIN FieldsForTables f ON vr.Calc_Hash = f.DDR_Hash AND vr.File_Name = f.File_Name;

-- 3b: Variablen in AutoEnter Calculated Fields (FieldsForTables.AE_Calc_Hash)
INSERT INTO VariableUsages
SELECT
    vr.Variable_Name,
    CASE
        WHEN vr.Variable_Name LIKE '$$$%' THEN 'superglobal'  -- wie P2, sonst Identitäts-Split
        WHEN vr.Variable_Name LIKE '$$%' THEN 'global'
        WHEN vr.Variable_Name LIKE '$%' THEN 'local'
        ELSE 'let_local'
    END as Variable_Scope,
    'read' as Usage_Type,
    'auto_enter_calc' as Context_Type,
    f.Field_UUID as Context_UUID,
    f.Table_Name || '::' || f.Field_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    f.Table_Name,
    f.Field_Name,
    vr.Calc_Hash,
    'ddr_chunk' as Source,
    vr.File_Name
FROM _DDR_VarRefs_Distinct vr
JOIN FieldsForTables f ON vr.Calc_Hash = f.AE_Calc_Hash AND vr.File_Name = f.File_Name
WHERE f.AE_Calc_Hash IS NOT NULL;

-- 3c: Variablen in CustomFunctions (CustomFunctionsCatalog.DDR_Hash)
INSERT INTO VariableUsages
SELECT
    vr.Variable_Name,
    CASE
        WHEN vr.Variable_Name LIKE '$$$%' THEN 'superglobal'  -- wie P2, sonst Identitäts-Split
        WHEN vr.Variable_Name LIKE '$$%' THEN 'global'
        WHEN vr.Variable_Name LIKE '$%' THEN 'local'
        ELSE 'let_local'
    END as Variable_Scope,
    'read' as Usage_Type,
    'custom_function' as Context_Type,
    cf.CF_UUID as Context_UUID,
    cf.CF_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    vr.Calc_Hash,
    'ddr_chunk' as Source,
    vr.File_Name
FROM _DDR_VarRefs_Distinct vr
JOIN CustomFunctionsCatalog cf ON vr.Calc_Hash = cf.DDR_Hash AND vr.File_Name = cf.File_Name
WHERE cf.DDR_Hash IS NOT NULL;

-- 3d: Variablen in Script-Schritt-Formeln
-- StepsForScripts.Parameters_XML enthält ChunkList-Hashes → DDR_Calculations.Calc_Hash
INSERT INTO VariableUsages
WITH step_hashes AS (
    SELECT
        Script_Name, Script_UUID, Step_Index, File_Name,
        unnest(regexp_extract_all(CAST(Parameters_XML AS VARCHAR),
            'kind="ChunkList" hash="([A-F0-9]+)"', 1)) as calc_hash
    FROM StepsForScripts
    WHERE Parameters_XML IS NOT NULL
      AND CAST(Parameters_XML AS VARCHAR) LIKE '%ChunkList%'
)
SELECT
    vr.Variable_Name,
    CASE
        WHEN vr.Variable_Name LIKE '$$$%' THEN 'superglobal'  -- wie P2, sonst Identitäts-Split
        WHEN vr.Variable_Name LIKE '$$%' THEN 'global'
        WHEN vr.Variable_Name LIKE '$%' THEN 'local'
        ELSE 'let_local'
    END as Variable_Scope,
    'read' as Usage_Type,
    'script_step' as Context_Type,
    s.Script_UUID as Context_UUID,
    s.Script_Name as Context_Name,
    s.Script_Name,
    s.Script_UUID,
    s.Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    vr.Calc_Hash,
    'ddr_chunk' as Source,
    vr.File_Name
FROM _DDR_VarRefs_Distinct vr
JOIN step_hashes s ON vr.Calc_Hash = s.calc_hash AND vr.File_Name = s.File_Name;

-- 3e: DDR-Variablen ohne zuordenbaren Kontext
-- Performance (P3): Die frühere Version prüfte
-- "Calc_Hash kommt in KEINEM Step/LayoutObject vor" über zwei korrelierte
-- NOT EXISTS mit `CAST(... AS VARCHAR) LIKE '%'||vr.Calc_Hash||'%'` — ein
-- Substring-Scan jedes Parameters_XML/Object_XML-Blobs PRO vr-Zeile
-- (O(vr × Steps × LayoutObjects × Blob-Länge) → ~152 s). Stattdessen werden alle
-- hash="…"-Attribute EINMAL pro File extrahiert (_context_hashes) und 3e nutzt
-- einen Anti-Join. Bit-identisch verifiziert (gleiche Zeilen + Content-Hash).
DROP TABLE IF EXISTS _context_hashes;
CREATE TEMP TABLE _context_hashes AS
SELECT DISTINCT File_Name, hash FROM (
    SELECT File_Name,
        unnest(regexp_extract_all(CAST(Parameters_XML AS VARCHAR), 'hash="([A-F0-9]+)"', 1)) AS hash
    FROM StepsForScripts WHERE Parameters_XML IS NOT NULL
    UNION ALL
    SELECT File_Name,
        unnest(regexp_extract_all(CAST(Object_XML AS VARCHAR), 'hash="([A-F0-9]+)"', 1)) AS hash
    FROM LayoutObjects WHERE Object_XML IS NOT NULL
);

INSERT INTO VariableUsages
SELECT
    vr.Variable_Name,
    CASE
        WHEN vr.Variable_Name LIKE '$$$%' THEN 'superglobal'  -- wie P2, sonst Identitäts-Split
        WHEN vr.Variable_Name LIKE '$$%' THEN 'global'
        WHEN vr.Variable_Name LIKE '$%' THEN 'local'
        ELSE 'let_local'
    END as Variable_Scope,
    'read' as Usage_Type,
    'calculation' as Context_Type,
    NULL as Context_UUID,
    NULL as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    vr.Calc_Hash,
    'ddr_chunk' as Source,
    vr.File_Name
FROM _DDR_VarRefs_Distinct vr
WHERE NOT EXISTS (
      SELECT 1 FROM FieldsForTables f
      WHERE (vr.Calc_Hash = f.DDR_Hash OR vr.Calc_Hash = f.AE_Calc_Hash)
        AND vr.File_Name = f.File_Name
  )
  AND NOT EXISTS (
      SELECT 1 FROM CustomFunctionsCatalog cf
      WHERE vr.Calc_Hash = cf.DDR_Hash AND vr.File_Name = cf.File_Name
  )
  AND NOT EXISTS (
      SELECT 1 FROM _context_hashes ch
      WHERE ch.File_Name = vr.File_Name AND ch.hash = vr.Calc_Hash
  );

-- ========================================
-- A.3f: Variablen in LayoutObject-Formeln (Object_XML ChunkList-Hashes)
-- ========================================
-- Erfasst Variablen-Referenzen in:
-- Conditional Formatting, Hide Conditions, Tooltips, Platzhalter,
-- berechnete Labels, Portal-Filter, Web-Viewer-URLs, Tab-Panel-Titel,
-- Script-Parameter, Display Calculations, Popover-Titel
--
-- Alle diese Kontexte verwenden DDRREF kind="ChunkList" hash="..." in Object_XML.
-- Der Hash wird gegen DDR_Calculations aufgelöst um VariableReference-Chunks zu finden.

INSERT INTO VariableUsages
WITH lo_hashes AS (
    SELECT
        Object_UUID, Object_Type, Layout_ID, File_Name,
        unnest(regexp_extract_all(CAST(Object_XML AS VARCHAR),
            'kind="ChunkList" hash="([A-F0-9]+)"', 1)) as calc_hash
    FROM LayoutObjects
    WHERE Object_XML IS NOT NULL
      AND CAST(Object_XML AS VARCHAR) LIKE '%ChunkList%'
)
SELECT
    vr.Variable_Name,
    CASE
        WHEN vr.Variable_Name LIKE '$$$%' THEN 'superglobal'  -- wie P2, sonst Identitäts-Split
        WHEN vr.Variable_Name LIKE '$$%' THEN 'global'
        WHEN vr.Variable_Name LIKE '$%' THEN 'local'
        ELSE 'let_local'
    END as Variable_Scope,
    'read' as Usage_Type,
    'layout_object' as Context_Type,
    lo.Object_UUID as Context_UUID,
    l.L_Name || ' → ' || lo.Object_Type as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    vr.Calc_Hash,
    'ddr_chunk' as Source,
    vr.File_Name
FROM _DDR_VarRefs_Distinct vr
JOIN lo_hashes lo ON vr.Calc_Hash = lo.calc_hash AND vr.File_Name = lo.File_Name
JOIN Layouts l ON lo.Layout_ID = l.L_ID AND l.File_Name = lo.File_Name;


-- ========================================
-- A.3g: Variablen in Custom Record Privileges (PrivilegeSetRecordAccess.DDR_Hash)
-- ========================================
-- Record-Access-Calcs
-- (@access="Calculation") referenzieren Variablen wie $$__Rechte_Bearbeiten.
-- Neuer Context_Type 'record_access_calc' macht diese Nutzung im Variablen-
-- Where-Used sichtbar (vorher unsichtbar: kein generischer XMLCalcReferences→
-- VariableUsages-Pfad existiert, jeder Quelltyp braucht einen eigenen Block).
--
-- Greift auf die Parser-Grundlage zurück (KEIN Neuparsen): _DDR_VarRefs_Distinct
-- trägt pro (Hash, File, Variable) genau EINE Zeile; die 43×-Hash-Kollision
-- ist damit bereits kollabiert. Der JOIN auf die N
-- PrivilegeSetRecordAccess-Zeilen mit diesem Hash erzeugt exakt eine Usage je
-- Set×Operation×Tabelle (nicht 43×).
INSERT INTO VariableUsages
SELECT
    vr.Variable_Name,
    CASE
        WHEN vr.Variable_Name LIKE '$$$%' THEN 'superglobal'  -- wie P2, sonst Identitäts-Split
        WHEN vr.Variable_Name LIKE '$$%' THEN 'global'
        WHEN vr.Variable_Name LIKE '$%' THEN 'local'
        ELSE 'let_local'
    END as Variable_Scope,
    'read' as Usage_Type,
    'record_access_calc' as Context_Type,
    ra.PrivilegeSet_UUID as Context_UUID,
    ra.PrivilegeSet_Name || ' › ' || ra.Operation || ':' || COALESCE(ra.BaseTable_Name, '<New>') as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    ra.BaseTable_Name as Table_Name,
    NULL as Field_Name,
    vr.Calc_Hash,
    'ddr_chunk' as Source,
    vr.File_Name
FROM _DDR_VarRefs_Distinct vr
JOIN PrivilegeSetRecordAccess ra
  ON vr.Calc_Hash = ra.DDR_Hash AND vr.File_Name = ra.File_Name
WHERE ra.DDR_Hash IS NOT NULL;


-- ========================================
-- A.3h: Variablen in Custom-Menü-Formeln (AP-3C)
-- ========================================
-- Install-/Title-/Name-Calcs von Menüs bzw. Menü-Items können Variablen lesen
-- (z. B. $$Modul in einer Install-Bedingung). Analog A.3g (record_access_calc):
-- kein generischer XMLCalcReferences→VariableUsages-Pfad existiert. Context_Type
-- 'custom_menu_calc' macht die Nutzung im Variablen-Where-Used sichtbar.
-- Owner (Menü/Item) + Subrole (Install|Title|Name) aus dem Calc-Anker; Hash-Join
-- gegen die bereits kollabierten _DDR_VarRefs_Distinct.
INSERT INTO VariableUsages
SELECT
    vr.Variable_Name,
    CASE
        WHEN vr.Variable_Name LIKE '$$$%' THEN 'superglobal'  -- wie P2, sonst Identitäts-Split
        WHEN vr.Variable_Name LIKE '$$%' THEN 'global'
        WHEN vr.Variable_Name LIKE '$%' THEN 'local'
        ELSE 'let_local'
    END as Variable_Scope,
    'read' as Usage_Type,
    'custom_menu_calc' as Context_Type,
    mo.Src_UUID as Context_UUID,
    mo.Context_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    vr.Calc_Hash,
    'ddr_chunk' as Source,
    vr.File_Name
FROM _DDR_VarRefs_Distinct vr
JOIN (
    SELECT DISTINCT
        d.Calc_Hash, d.File_Name, o.Src_UUID,
        o.Menu_Name || ' › ' || regexp_replace(d.Calc_UUID, '^_[0-9A-Fa-f-]{36}_?', '') AS Context_Name
    FROM DDR_Calculations d
    JOIN (
        SELECT upper(Menu_UUID) AS Anchor_UUID, File_Name, Menu_UUID AS Src_UUID, Menu_Name FROM CustomMenuCatalog
        UNION ALL
        SELECT upper(Item_UUID), File_Name, Item_UUID,
               Menu_Name || ' › ' || COALESCE(NULLIF(Command_Name, ''), '(Item)') FROM CustomMenuItemCatalog
    ) o ON o.Anchor_UUID = upper(regexp_extract(d.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
       AND o.File_Name = d.File_Name
) mo ON vr.Calc_Hash = mo.Calc_Hash AND vr.File_Name = mo.File_Name;


-- ========================================
-- A.4: Set Variable Schritte → VariableUsages
-- ========================================

INSERT INTO VariableUsages
SELECT
    Variable_Name,
    CASE WHEN Variable_Name LIKE '$$$%' THEN 'superglobal' WHEN Variable_Name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'set' as Usage_Type,
    'script_step' as Context_Type,
    Script_UUID as Context_UUID,
    Script_Name as Context_Name,
    Script_Name,
    Script_UUID,
    Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'set_variable_step' as Source,
    File_Name
FROM StepsForScripts
WHERE Step_ID = 141  -- 'Set Variable' (Step-ID statt lokalisiertem Namen)
  AND Variable_Name IS NOT NULL;


-- ========================================
-- A.4b: Target=Variable Script-Steps → VariableUsages
-- ========================================
-- Script-Steps die ihr Ergebnis in eine Variable schreiben:
-- Insert Text, Show Custom Dialog, Insert from URL, Insert Calculated Result,
-- Execute FileMaker Data API, Open/Read Data File, etc.
-- Generische Erkennung über <Variable value="$var">
-- LATERAL UNNEST für Multi-Target (z.B. Show Custom Dialog mit 3 Eingabefeldern)

INSERT INTO VariableUsages
SELECT
    var_name as Variable_Name,
    CASE WHEN var_name LIKE '$$$%' THEN 'superglobal' WHEN var_name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'set' as Usage_Type,
    'script_step' as Context_Type,
    Script_UUID as Context_UUID,
    Script_Name as Context_Name,
    Script_Name,
    Script_UUID,
    Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'target_variable_step' as Source,
    File_Name
FROM StepsForScripts
CROSS JOIN LATERAL unnest(
    regexp_extract_all(CAST(Parameters_XML AS VARCHAR),
        '<Variable value="([^"]+)"', 1)
) as t(var_name)
WHERE Step_ID != 141  -- 'Set Variable'
  AND CAST(Parameters_XML AS VARCHAR) LIKE '%<Variable value="%';


-- ========================================
-- A.5: MBS Superglobale → VariableUsages
-- ========================================

-- 5a: Variable.Set / FM.VariableSet in Script-Schritten
INSERT INTO VariableUsages
SELECT
    regexp_extract(Calculation_Text,
        '(?:FM\.VariableSet|Variable\.Set)\s*"\s*;\s*"([^"]+)"', 1) as Variable_Name,
    'superglobal' as Variable_Scope,
    'set' as Usage_Type,
    'script_step' as Context_Type,
    Script_UUID as Context_UUID,
    Script_Name as Context_Name,
    Script_Name,
    Script_UUID,
    Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'mbs_variable_call' as Source,
    File_Name
FROM StepsForScripts
-- OR-Zweige geklammert — vorher band AND stärker, der Guard galt nur
-- für den zweiten LIKE-Zweig (latent, 0 Treffer im Korpus).
WHERE (Calculation_Text LIKE '%Variable.Set%' OR Calculation_Text LIKE '%FM.VariableSet%')
  AND NULLIF(regexp_extract(Calculation_Text,
        '(?:FM\.VariableSet|Variable\.Set)\s*"\s*;\s*"([^"]+)"', 1), '') IS NOT NULL;

-- 5b: Variable.Get / FM.VariableGet / Variable.Exists / Variable.Lookup in Script-Schritten
INSERT INTO VariableUsages
SELECT
    regexp_extract(Calculation_Text,
        '(?:FM\.VariableGet|Variable\.Get|Variable\.Exists|Variable\.Lookup)\s*"\s*;\s*"([^"]+)"', 1) as Variable_Name,
    'superglobal' as Variable_Scope,
    'read' as Usage_Type,
    'script_step' as Context_Type,
    Script_UUID as Context_UUID,
    Script_Name as Context_Name,
    Script_Name,
    Script_UUID,
    Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'mbs_variable_call' as Source,
    File_Name
FROM StepsForScripts
WHERE (Calculation_Text LIKE '%Variable.Get%'
    OR Calculation_Text LIKE '%FM.VariableGet%'
    OR Calculation_Text LIKE '%Variable.Exists%'
    OR Calculation_Text LIKE '%Variable.Lookup%')
  AND NULLIF(regexp_extract(Calculation_Text,
        '(?:FM\.VariableGet|Variable\.Get|Variable\.Exists|Variable\.Lookup)\s*"\s*;\s*"([^"]+)"', 1), '') IS NOT NULL;

-- 5c: Variable.Append / Variable.AppendValue / Variable.AppendJSON / Variable.Add in Script-Schritten
INSERT INTO VariableUsages
SELECT
    regexp_extract(Calculation_Text,
        '(?:Variable\.Append|Variable\.AppendValue|Variable\.AppendJSON|Variable\.Add)\s*"\s*;\s*"([^"]+)"', 1) as Variable_Name,
    'superglobal' as Variable_Scope,
    'set' as Usage_Type,
    'script_step' as Context_Type,
    Script_UUID as Context_UUID,
    Script_Name as Context_Name,
    Script_Name,
    Script_UUID,
    Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'mbs_variable_call' as Source,
    File_Name
FROM StepsForScripts
WHERE (Calculation_Text LIKE '%Variable.Append%'
    OR Calculation_Text LIKE '%Variable.AppendValue%'
    OR Calculation_Text LIKE '%Variable.AppendJSON%'
    OR Calculation_Text LIKE '%Variable.Add%')
  AND NULLIF(regexp_extract(Calculation_Text,
        '(?:Variable\.Append|Variable\.AppendValue|Variable\.AppendJSON|Variable\.Add)\s*"\s*;\s*"([^"]+)"', 1), '') IS NOT NULL;

-- 5d: Variable.Clear in Script-Schritten
INSERT INTO VariableUsages
SELECT
    regexp_extract(Calculation_Text,
        '(?:Variable\.Clear)\s*"\s*;\s*"([^"]+)"', 1) as Variable_Name,
    'superglobal' as Variable_Scope,
    'set' as Usage_Type,
    'script_step' as Context_Type,
    Script_UUID as Context_UUID,
    Script_Name as Context_Name,
    Script_Name,
    Script_UUID,
    Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'mbs_variable_call' as Source,
    File_Name
FROM StepsForScripts
-- Kein NOT-LIKE-ClearAll-Ausschluss mehr — er verwarf MISCH-Steps
-- (Clear("x") + ClearAll im selben Step). Die Regex matcht ClearAll ohnehin
-- nicht (nach 'Variable.Clear' folgt dort 'A', kein '"').
WHERE Calculation_Text LIKE '%Variable.Clear%'
  AND NULLIF(regexp_extract(Calculation_Text,
        '(?:Variable\.Clear)\s*"\s*;\s*"([^"]+)"', 1), '') IS NOT NULL;

-- 5e: MBS Superglobale in Calculated Fields (FieldsForTables.Calculation_Text)
INSERT INTO VariableUsages
SELECT
    regexp_extract(Calculation_Text,
        '(?:FM\.VariableGet|Variable\.Get|Variable\.Exists|Variable\.Lookup)\s*"\s*;\s*"([^"]+)"', 1) as Variable_Name,
    'superglobal' as Variable_Scope,
    'read' as Usage_Type,
    'calculation' as Context_Type,
    Field_UUID as Context_UUID,
    Table_Name || '::' || Field_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    Table_Name,
    Field_Name,
    NULL as Calc_Hash,
    'mbs_variable_call' as Source,
    File_Name
FROM FieldsForTables
WHERE Calculation_Text IS NOT NULL
  AND (Calculation_Text LIKE '%Variable.Get%'
    OR Calculation_Text LIKE '%FM.VariableGet%'
    OR Calculation_Text LIKE '%Variable.Exists%'
    OR Calculation_Text LIKE '%Variable.Lookup%')
  AND NULLIF(regexp_extract(Calculation_Text,
        '(?:FM\.VariableGet|Variable\.Get|Variable\.Exists|Variable\.Lookup)\s*"\s*;\s*"([^"]+)"', 1), '') IS NOT NULL;

-- 5f: MBS Superglobale in AutoEnter Calculated Fields (FieldsForTables.AE_Calc_Text)
INSERT INTO VariableUsages
SELECT
    regexp_extract(AE_Calc_Text,
        '(?:FM\.VariableGet|Variable\.Get|Variable\.Exists|Variable\.Lookup)\s*"\s*;\s*"([^"]+)"', 1) as Variable_Name,
    'superglobal' as Variable_Scope,
    'read' as Usage_Type,
    'auto_enter_calc' as Context_Type,
    Field_UUID as Context_UUID,
    Table_Name || '::' || Field_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    Table_Name,
    Field_Name,
    NULL as Calc_Hash,
    'mbs_variable_call' as Source,
    File_Name
FROM FieldsForTables
WHERE AE_Calc_Text IS NOT NULL
  AND (AE_Calc_Text LIKE '%Variable.Get%'
    OR AE_Calc_Text LIKE '%FM.VariableGet%'
    OR AE_Calc_Text LIKE '%Variable.Exists%'
    OR AE_Calc_Text LIKE '%Variable.Lookup%')
  AND NULLIF(regexp_extract(AE_Calc_Text,
        '(?:FM\.VariableGet|Variable\.Get|Variable\.Exists|Variable\.Lookup)\s*"\s*;\s*"([^"]+)"', 1), '') IS NOT NULL;

-- 5g: MBS Superglobale in CustomFunctions (CalcsForCustomFunctions.Calculation_Code)
INSERT INTO VariableUsages
SELECT
    regexp_extract(Calculation_Code,
        '(?:FM\.VariableGet|Variable\.Get|FM\.VariableSet|Variable\.Set|Variable\.Exists|Variable\.Lookup)\s*"\s*;\s*"([^"]+)"', 1) as Variable_Name,
    'superglobal' as Variable_Scope,
    CASE
        WHEN Calculation_Code LIKE '%Variable.Set%' OR Calculation_Code LIKE '%FM.VariableSet%' THEN 'set'
        ELSE 'read'
    END as Usage_Type,
    'custom_function' as Context_Type,
    CF_UUID as Context_UUID,
    CF_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'mbs_variable_call' as Source,
    File_Name
FROM CalcsForCustomFunctions
WHERE Calculation_Code IS NOT NULL
  AND (Calculation_Code LIKE '%Variable.Get%'
    OR Calculation_Code LIKE '%FM.VariableGet%'
    OR Calculation_Code LIKE '%Variable.Set%'
    OR Calculation_Code LIKE '%FM.VariableSet%'
    OR Calculation_Code LIKE '%Variable.Exists%'
    OR Calculation_Code LIKE '%Variable.Lookup%')
  AND NULLIF(regexp_extract(Calculation_Code,
        '(?:FM\.VariableGet|Variable\.Get|FM\.VariableSet|Variable\.Set|Variable\.Exists|Variable\.Lookup)\s*"\s*;\s*"([^"]+)"', 1), '') IS NOT NULL;


-- MBS-Superglobale (Variable.Set/Get/…) tragen den vom Script übergebenen
-- LITERALNAMEN. Beginnt der mit '$$' (FM-Global-Schreibweise), kollidiert er im
-- Explorer/ObjectCatalog namensgleich mit einer ECHTEN FM-Global gleichen Namens —
-- zwei Objekte, gleicher Object_Name, unterschiedlicher Scope (global vs superglobal)
-- → Identitäts-Verwirrung. MBS-Variablen sind aber ein SEPARATER Speicher (Plugin-
-- Memory), nicht die FM-Global; die Objekt-Trennung ist korrekt, nur namentlich
-- unsichtbar. Konvention (CLAUDE.md; Display_Name-Logik in VariablesCatalog unten):
-- superglobal ⇒ '$$$'-Präfix. Hier den GESPEICHERTEN Namen auf dieselbe Normalform
-- bringen (identische Formel wie Display_Name → Variable_Name == Display_Name,
-- idempotent: '$$$x' bleibt '$$$x'). Scope bleibt superglobal. Muss VOR dem
-- VariablesCatalog-Build (Z.~864) und vor P4 laufen — hier korrekt platziert.
UPDATE VariableUsages
SET Variable_Name = '$$$' || regexp_replace(Variable_Name, '^\$+', '')
WHERE Source = 'mbs_variable_call';


-- ========================================
-- A.6: Merge-Variables aus LayoutObjects → VariableUsages
-- ========================================

INSERT INTO VariableUsages
SELECT
    var_name as Variable_Name,
    CASE WHEN var_name LIKE '$$$%' THEN 'superglobal' WHEN var_name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'read' as Usage_Type,
    'layout_object' as Context_Type,
    lo.Object_UUID as Context_UUID,
    l.L_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'merge_variable' as Source,
    lo.File_Name
FROM LayoutObjects lo
JOIN Layouts l ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
CROSS JOIN LATERAL unnest(
    regexp_extract_all(lo.Text_Content, '<<(\$\$?[^>]+)>>', 1)
) as t(var_name)
WHERE lo.Object_Type = 'Text'
  AND lo.Text_Content LIKE '%<<%$%>>%';


-- ========================================
-- A.6b: Script-Trigger-Parameter → VariableUsages
-- ========================================
-- Layout-Objekte mit Script-Triggern, deren Parameter Variablen referenzieren

INSERT INTO VariableUsages
SELECT
    var_name as Variable_Name,
    CASE WHEN var_name LIKE '$$$%' THEN 'superglobal' WHEN var_name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'read' as Usage_Type,
    'layout_object' as Context_Type,
    lo.Object_UUID as Context_UUID,
    l.L_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'script_trigger_param' as Source,
    lo.File_Name
FROM LayoutObjects lo
JOIN Layouts l ON lo.Layout_ID = l.L_ID AND lo.File_Name = l.File_Name
CROSS JOIN LATERAL unnest(
    -- Ohne Space in der Klasse (war greedy über Wortgrenzen) + Unicode
    regexp_extract_all(lo.ScriptTrigger_Parameter_Text,
        '\$\$?\$?[\p{L}_][\p{L}\p{N}_]*')
) as t(var_name)
WHERE lo.ScriptTrigger_Parameter_Text IS NOT NULL
  AND lo.ScriptTrigger_Parameter_Text LIKE '%$%';


-- ========================================
-- A.6c: Variablen aus geretteten Display-Formeln (leere ChunkList, 2.20.0)
-- ========================================
-- Bei %X:-typisierten Layoutformeln mit Ausdruck ist die DDR-ChunkList LEER —
-- Variablen-Referenzen (<<ƒ:%N:Abs( $$var + 1 )>>) fehlen komplett. Anders als
-- Builtin-Funktionsnamen sind Variablen SYNTAKTISCH eindeutig ($-Präfix) und
-- werden aus der Text_Content-Formel geborgen (Anker + Index aus
-- DDR_ChunkListContexts — nie über den dateiweit geteilten Leerhash).
-- Doppelt-gequotete String-Literale werden vor dem Match entfernt ("$$x" zählt
-- nicht); ${…}-gequotete FELD-Namen matcht die Klasse nicht ('{' nach '$').
-- Kanten entstehen generisch aus VariableUsages (P4 Block 28, reads_variable).
-- Slot-skopiertes Spiegelbild: P2 A.6.10b schreibt dieselben Funde als
-- XMLCalcReferences-Zeilen (Subrole je Slot) für Ref-Tokens + synthetische
-- D2-Tokenisierung der API — Extraktionslogik hier und dort identisch halten.
INSERT INTO VariableUsages
WITH empty_disp AS (
    SELECT
        ctx.File_Name,
        upper(regexp_extract(ctx.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1)) AS Anchor_UUID,
        TRY_CAST(regexp_extract(ctx.Calc_UUID, '_([0-9]+)$', 1) AS BIGINT) AS Disp_Index
    FROM DDR_ChunkListContexts ctx
    WHERE ctx.Chunk_Count = 0
      AND ctx.Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
),
lo1 AS (
    SELECT Object_UUID, Layout_ID, File_Name, Text_Content,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    WHERE Text_Content LIKE '%<<%'
),
formulas AS (
    SELECT
        lo.Object_UUID, lo.Layout_ID, e.File_Name,
        regexp_replace(
            regexp_replace(
                regexp_extract_all(lo.Text_Content, '(?s)<<ƒ:(.*?)>>', 1)[e.Disp_Index + 1],
                '^%[A-Z]+:', ''),
            '"[^"]*"', '', 'g') AS formula_noliterals
    FROM empty_disp e
    JOIN lo1 lo
      ON upper(lo.Object_UUID) = e.Anchor_UUID
     AND lo.File_Name = e.File_Name
     AND lo.rn = 1
)
SELECT DISTINCT
    v.var_name as Variable_Name,
    CASE WHEN v.var_name LIKE '$$$%' THEN 'superglobal' WHEN v.var_name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'read' as Usage_Type,
    'layout_object' as Context_Type,
    f.Object_UUID as Context_UUID,
    l.L_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'display_calc_recovery' as Source,
    f.File_Name
FROM formulas f
JOIN Layouts l ON f.Layout_ID = l.L_ID AND l.File_Name = f.File_Name
CROSS JOIN LATERAL unnest(
    regexp_extract_all(f.formula_noliterals, '\$\$?\$?[\p{L}_][\p{L}\p{N}_]*')
) as v(var_name)
WHERE f.formula_noliterals IS NOT NULL;


-- ========================================
-- A.7: Regex-Fallback für Dateien ohne DDR
-- ========================================

-- 7a: Regex-Variablen aus Script-Schritt-Formeln (nur Dateien ohne DDR)
INSERT INTO VariableUsages
SELECT
    var_name as Variable_Name,
    CASE WHEN var_name LIKE '$$$%' THEN 'superglobal' WHEN var_name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'read' as Usage_Type,
    'script_step' as Context_Type,
    s.Script_UUID as Context_UUID,
    s.Script_Name as Context_Name,
    s.Script_Name,
    s.Script_UUID,
    s.Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'regex_fallback' as Source,
    s.File_Name
FROM StepsForScripts s
JOIN XMLMetadata m ON s.File_Name = m.Filename
CROSS JOIN LATERAL unnest(
    regexp_extract_all(s.Calculation_Text, '\$\$?\$?[\p{L}_][\p{L}\p{N}_]*')
) as t(var_name)
WHERE m.Has_DDR_INFO = 'False'
  AND s.Calculation_Text IS NOT NULL
  AND s.Step_ID != 141;  -- 'Set Variable'

-- 7b: Regex-Variablen aus Calculated Fields (nur Dateien ohne DDR)
INSERT INTO VariableUsages
SELECT
    var_name as Variable_Name,
    CASE WHEN var_name LIKE '$$$%' THEN 'superglobal' WHEN var_name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'read' as Usage_Type,
    'calculation' as Context_Type,
    f.Field_UUID as Context_UUID,
    f.Table_Name || '::' || f.Field_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    f.Table_Name,
    f.Field_Name,
    NULL as Calc_Hash,
    'regex_fallback' as Source,
    f.File_Name
FROM FieldsForTables f
JOIN XMLMetadata m ON f.File_Name = m.Filename
CROSS JOIN LATERAL unnest(
    regexp_extract_all(f.Calculation_Text, '\$\$?\$?[\p{L}_][\p{L}\p{N}_]*')
) as t(var_name)
WHERE m.Has_DDR_INFO = 'False'
  AND f.Calculation_Text IS NOT NULL;

-- 7c: Regex-Variablen aus AutoEnter Calculated Fields (nur Dateien ohne DDR)
INSERT INTO VariableUsages
SELECT
    var_name as Variable_Name,
    CASE WHEN var_name LIKE '$$$%' THEN 'superglobal' WHEN var_name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'read' as Usage_Type,
    'auto_enter_calc' as Context_Type,
    f.Field_UUID as Context_UUID,
    f.Table_Name || '::' || f.Field_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    f.Table_Name,
    f.Field_Name,
    NULL as Calc_Hash,
    'regex_fallback' as Source,
    f.File_Name
FROM FieldsForTables f
JOIN XMLMetadata m ON f.File_Name = m.Filename
CROSS JOIN LATERAL unnest(
    regexp_extract_all(f.AE_Calc_Text, '\$\$?\$?[\p{L}_][\p{L}\p{N}_]*')
) as t(var_name)
WHERE m.Has_DDR_INFO = 'False'
  AND f.AE_Calc_Text IS NOT NULL;

-- 7d: Regex-Variablen aus CustomFunction-Formeln (nur Dateien ohne DDR)
INSERT INTO VariableUsages
SELECT
    var_name as Variable_Name,
    CASE WHEN var_name LIKE '$$$%' THEN 'superglobal' WHEN var_name LIKE '$$%' THEN 'global' ELSE 'local' END as Variable_Scope,
    'read' as Usage_Type,
    'custom_function' as Context_Type,
    ccf.CF_UUID as Context_UUID,
    ccf.CF_Name as Context_Name,
    NULL as Script_Name,
    NULL as Script_UUID,
    NULL as Step_Index,
    NULL as Table_Name,
    NULL as Field_Name,
    NULL as Calc_Hash,
    'regex_fallback' as Source,
    ccf.File_Name
FROM CalcsForCustomFunctions ccf
JOIN XMLMetadata m ON ccf.File_Name = m.Filename
CROSS JOIN LATERAL unnest(
    regexp_extract_all(ccf.Calculation_Code, '\$\$?\$?[\p{L}_][\p{L}\p{N}_]*')
) as t(var_name)
WHERE m.Has_DDR_INFO = 'False'
  AND ccf.Calculation_Code IS NOT NULL;


-- ========================================
-- A.7e: Scope_Anchor in VariableUsages materialisieren
-- ========================================
-- Bindet die Variablen-Identität an den FileMaker-Scope-Träger:
--   superglobal → '__global'           (prozessweit)
--   global      → File_Name            (datei-lokal)
--   local       → Script_UUID          (script-lokal, sofern vorhanden)
--                 '__file::'||File_Name (Fallback bei Calc/CF/Layout-Kontext ohne Script)
--   let_local   → Context_UUID || '__file::'||File_Name
ALTER TABLE VariableUsages ADD COLUMN IF NOT EXISTS Scope_Anchor VARCHAR;

UPDATE VariableUsages
SET Scope_Anchor = CASE
    WHEN Variable_Scope = 'superglobal' THEN '__global'
    WHEN Variable_Scope = 'global'      THEN File_Name
    WHEN Variable_Scope = 'local' AND Script_UUID IS NOT NULL THEN Script_UUID
    WHEN Variable_Scope = 'local' AND Script_UUID IS NULL     THEN '__file::' || File_Name
    WHEN Variable_Scope = 'let_local'   THEN COALESCE(Context_UUID, '__file::' || File_Name)
    ELSE File_Name
END;


-- ========================================
-- A.8: VariablesCatalog (Aggregation)
-- ========================================

DROP TABLE IF EXISTS VariablesCatalog;

CREATE TABLE VariablesCatalog AS
SELECT
    Variable_Name,
    Variable_Scope,
    Scope_Anchor,
    CASE Variable_Scope
        WHEN 'local' THEN Variable_Name
        WHEN 'global' THEN Variable_Name
        WHEN 'superglobal' THEN '$$$' || regexp_replace(Variable_Name, '^\$+', '')
        ELSE Variable_Name
    END as Display_Name,
    regexp_replace(Variable_Name, '^\$+', '') as Normalized_Name,
    -- Script_UUID nur bei script-lokalen Variablen (Anker = Script_UUID, kein '__file::'-Fallback)
    CASE WHEN Variable_Scope = 'local' AND Scope_Anchor NOT LIKE '__file::%'
         THEN Scope_Anchor
         ELSE NULL
    END as Script_UUID,
    COUNT(*) FILTER (WHERE Usage_Type = 'set') as Set_Count,
    COUNT(*) FILTER (WHERE Usage_Type = 'read') as Read_Count,
    COUNT(DISTINCT Script_Name) as Script_Count,
    COUNT(DISTINCT File_Name) as File_Count,
    array_agg(DISTINCT File_Name ORDER BY File_Name) as Files,
    -- Deterministisch (A-1): ohne ORDER BY ist first() reihenfolge-abhängig und
    -- damit nicht reproduzierbar — bei mehreren DuckDB-Threads bzw. parallelem
    -- Import (--jobs) verschiebt sich die physische Zeilenreihenfolge von
    -- VariableUsages. Stabile Sortierung über (File, Script, Step, Context).
    first(Context_Name ORDER BY File_Name, Script_Name, Step_Index, Context_Name) as First_Seen_Context,
    Variable_Name LIKE '% %' as Has_Spaces,
    CASE WHEN bool_or(Source = 'ddr_chunk') THEN 'ddr'
         WHEN bool_or(Source IN ('set_variable_step', 'target_variable_step')) THEN 'step'
         WHEN bool_or(Source = 'mbs_variable_call') THEN 'mbs'
         WHEN bool_or(Source = 'merge_variable') THEN 'merge'
         WHEN bool_or(Source = 'script_trigger_param') THEN 'trigger'
         ELSE 'regex'
    END as Source_Reliability,
    -- File_Name = Datei, in der diese Scope-Instanz wohnt:
    --   global: Anker = File_Name (datei-lokal)
    --   local mit Script-Anker: einzige Datei dieses Scripts (durch mode garantiert)
    --   local ohne Script (Fallback '__file::X'): X
    --   superglobal: häufigste Datei (informativ)
    CASE
        WHEN Variable_Scope = 'global' THEN Scope_Anchor
        WHEN Variable_Scope = 'local' AND Scope_Anchor LIKE '__file::%'
            THEN substr(Scope_Anchor, 9)
        -- Deterministisch (A-1): mode() bricht Häufigkeits-Gleichstände
        -- reihenfolge-abhängig (nicht reproduzierbar bei parallelem Import).
        -- Stattdessen: häufigste Datei, Gleichstand alphabetisch (nur für
        -- superglobale Variablen relevant — sonst greift Scope_Anchor oben).
        ELSE (SELECT fn FROM (
                  SELECT File_Name fn, COUNT(*) c
                  FROM VariableUsages vc_inner
                  WHERE vc_inner.Variable_Name = vc_src.Variable_Name
                    AND vc_inner.Variable_Scope = vc_src.Variable_Scope
                    AND vc_inner.Scope_Anchor IS NOT DISTINCT FROM vc_src.Scope_Anchor
                  GROUP BY File_Name
                  ORDER BY c DESC, File_Name ASC
                  LIMIT 1))
    END as File_Name
FROM VariableUsages vc_src
GROUP BY Variable_Name, Variable_Scope, Scope_Anchor;

-- Indizes für VariableUsages/VariablesCatalog
CREATE INDEX IF NOT EXISTS idx_varusages_name ON VariableUsages(Variable_Name);
CREATE INDEX IF NOT EXISTS idx_varusages_scope ON VariableUsages(Variable_Scope);
CREATE INDEX IF NOT EXISTS idx_varusages_context ON VariableUsages(Context_UUID);
CREATE INDEX IF NOT EXISTS idx_varusages_file ON VariableUsages(File_Name);
CREATE INDEX IF NOT EXISTS idx_varusages_anchor ON VariableUsages(Scope_Anchor);
CREATE INDEX IF NOT EXISTS idx_varcatalog_scope ON VariablesCatalog(Variable_Scope);
CREATE INDEX IF NOT EXISTS idx_varcatalog_file ON VariablesCatalog(File_Name);
CREATE INDEX IF NOT EXISTS idx_varcatalog_anchor ON VariablesCatalog(Scope_Anchor);
CREATE INDEX IF NOT EXISTS idx_varcatalog_name ON VariablesCatalog(Variable_Name);

-- Variablen-Parser Statistik
SELECT '=== Variablen-Parser Ergebnis ===' as Info;

SELECT Source, COUNT(*) as Anzahl_Usages
FROM VariableUsages GROUP BY Source ORDER BY Anzahl_Usages DESC;

SELECT
    'Gesamt VariableUsages' as Metrik, COUNT(*)::VARCHAR as Wert FROM VariableUsages
UNION ALL SELECT 'Gesamt VariablesCatalog', COUNT(*)::VARCHAR FROM VariablesCatalog
UNION ALL SELECT 'Davon global', COUNT(*)::VARCHAR FROM VariablesCatalog WHERE Variable_Scope = 'global'
UNION ALL SELECT 'Davon lokal', COUNT(*)::VARCHAR FROM VariablesCatalog WHERE Variable_Scope = 'local'
UNION ALL SELECT 'Davon superglobal', COUNT(*)::VARCHAR FROM VariablesCatalog WHERE Variable_Scope = 'superglobal'
UNION ALL SELECT 'Davon let_local', COUNT(*)::VARCHAR FROM VariablesCatalog WHERE Variable_Scope = 'let_local';


-- ############################################################
-- Phase A.5: FolderHierarchy
-- ############################################################
-- Vereinheitlichte Hierarchie für Folder-Strukturen aller Objekttypen.
-- FileMaker modelliert Folder als sequenzielle Marker im XML:
--   isFolder='True'   → Ordner-Beginn (+1 Tiefe)
--   isFolder='Marker' → Ordner-Ende  (−1 Tiefe)
--   isSeparatorItem='True' → Trennlinie (kein Folder, nur UI)
--
-- Subtypen werden über Source_Table unterschieden:
--   ScriptCatalog          → Script-Folder
--   Layouts                → Layout-Folder
--   CustomFunctionsCatalog → CustomFunction-Folder (ab Schema 1.15.0)
-- ############################################################

CREATE OR REPLACE VIEW FolderHierarchy AS
WITH all_items AS (
    -- Scripts: Sequence_ID = XML-Reihenfolge (NICHT Script_ID, das ist Anlege-Reihenfolge!)
    SELECT
        Script_UUID AS Source_UUID,
        Script_Name AS Item_Name,
        File_Name,
        Sequence_ID,
        Folder_Type,
        Is_Separator,
        'ScriptCatalog' AS Source_Table
    FROM ScriptCatalog

    UNION ALL

    -- Layouts: Sequence_ID = XML-Reihenfolge (analog zu Scripts)
    SELECT
        L_UUID AS Source_UUID,
        L_Name AS Item_Name,
        File_Name,
        Sequence_ID,
        Folder_Type,
        Is_Separator,
        'Layouts' AS Source_Table
    FROM Layouts

    UNION ALL

    -- Custom Functions: Sequence_ID = XML-Reihenfolge (analog zu Scripts). Der
    -- "Manage Custom Functions"-Dialog kennt Ordner und Trennlinien; FileMaker
    -- schreibt sie als <CustomFunction isFolder="True"/"Marker"> (ab FM 22 in den
    -- Fixtures belegt), seit Schema 1.15.0 extrahiert.
    SELECT
        CF_UUID AS Source_UUID,
        CF_Name AS Item_Name,
        File_Name,
        Sequence_ID,
        Folder_Type,
        COALESCE(Is_Separator, False) AS Is_Separator,
        'CustomFunctionsCatalog' AS Source_Table
    FROM CustomFunctionsCatalog
),
numbered AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY File_Name, Source_Table
                           ORDER BY Sequence_ID) - 1 AS seq
    FROM all_items
),
with_levels AS (
    SELECT *,
        -- Stack-Logik: kumulative Summe bis VOR der aktuellen Zeile.
        -- 'True' öffnet einen Folder (+1), 'Marker' schließt ihn (−1).
        GREATEST(0, COALESCE(
            SUM(CASE WHEN Folder_Type = 'True'   THEN 1
                     WHEN Folder_Type = 'Marker' THEN -1
                     ELSE 0 END)
            OVER (PARTITION BY File_Name, Source_Table ORDER BY seq
                  ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
        , 0)) AS nesting_level,
        CASE
            WHEN Is_Separator           THEN 'Separator'
            WHEN Folder_Type = 'True'   THEN 'Folder'
            WHEN Folder_Type = 'Marker' THEN 'FolderEnd'
            ELSE                             'Item'
        END AS subtype
    FROM numbered
)
SELECT
    t.Source_UUID,
    t.Item_Name,
    t.File_Name,
    t.Source_Table,
    t.Sequence_ID,
    t.seq,
    t.Folder_Type,
    t.Is_Separator,
    t.nesting_level,
    t.subtype,
    -- Parent_Folder_UUID: letzter offener Folder mit nesting_level = current - 1
    -- und seq < current. Korrelierte Subquery — DuckDB optimiert das.
    (
        SELECT p.Source_UUID
        FROM with_levels p
        WHERE p.File_Name    = t.File_Name
          AND p.Source_Table = t.Source_Table
          AND p.subtype      = 'Folder'
          AND p.nesting_level = t.nesting_level - 1
          AND p.seq          < t.seq
        ORDER BY p.seq DESC
        LIMIT 1
    ) AS Parent_Folder_UUID
FROM with_levels t;



-- ============================================
-- A.7: StepsForScripts.Inserted_Text — Anzeige-Payload für "Insert Text"
-- ============================================
-- Der von FileMaker erzeugte DDR-Step_Text lässt bei "Insert Text" den literalen
-- <Parameter type="Text"><Text value="…">-Inhalt weg (zeigt nur Ziel + [ Select ]).
-- Hier in eine Hilfsspalte aufgelöst — xml_extract_text DEKODIERT die XML-Entities
-- (&quot;, &#xFC;, &#13; …) bereits korrekt. So zeigen die REST-Templates/Formatter
-- den Inhalt OHNE eigene XML-/Entity-Behandlung an (der READ_ONLY-API-Server kann
-- webbed nicht laden). Nur "Insert Text" trägt dieses Literal (datenbasiert
-- verifiziert: einziger Step-Typ, dessen @value-Literal im DDR-Text fehlt — alle
-- anderen Literale, Pfade, URLs, Calcs zeigt der DDR).
--
-- WICHTIG — Phase-Wahl: NICHT in P2 (resolve). P2 läuft K-fach partitioniert, jede
-- Slice mountet die Master-DB read-only und sieht StepsForScripts nur als VIEW über
-- `src` (CREATE VIEW … AS SELECT * FROM src.StepsForScripts …) → ALTER/UPDATE darauf
-- scheitert ("Can only modify view"/"Can only update base table"). P3 dagegen läuft
-- EINMAL auf der Master-DB, wo StepsForScripts ein Base-Table ist. Additiv/idempotent
-- (analog Step_XML in P1); ein Rebuild recreiert die Tabelle in P1 ohne die Spalte,
-- P3 fügt sie hier wieder hinzu.
-- Zweiter Decode-Pass (wa_attr_unescape-gegatet, Default ON): unter SAX doppel-escaped
-- webbed numerische Char-Refs im @value (Quelle `&#38;` → Roh-Step_XML `&amp;#38;`), sodass
-- xml_extract_text nur den aeusseren `&amp;` aufloest und `&#38;` (bzw. `&#60;`/`&#62;`/
-- `&#34;`/`&#39;`) im Text zurueckbleibt.
-- CHIRURGISCH — nur die 5 XML-predefined NUMERISCHEN Refs ersetzen; KEIN html_unescape:
-- html_unescape fasst auch literale `&`/named entities/Markup im Insert-Text an (mangelt
-- z.B. HTML-Rich-Text: 1385→1380 Zeichen, obwohl kein `&#` enthalten). Der ordered-replace
-- laesst literales `&`, `&amp;`/`&lt;`/... und Markup unveraendert → praktisch No-op auf dem
-- DOM-Wert (0 Kollateral im Korpus, byte-identisch) und stellt DOM≡SAX her.
-- BEKANNTER TRADEOFF (NICHT garantiert No-op): der Replace laeuft NACH der Entity-
-- Dekodierung, daher wird ein Text, der LITERAL die Zeichenfolge `&#38;` (bzw. `&#60;`/…)
-- enthaelt (z.B. Doku ueber XML-Entities), auch auf dem DOM-Pfad zu `&`/… verfaelscht. Nach
-- single-decode ist dieser Fall vom SAX-Doppel-Escape prinzipiell nicht unterscheidbar →
-- im Korpus 0 Treffer, aber theoretisch moeglich; endgueltige Loesung bleibt der webbed-
-- Upstream-Fix.
ALTER TABLE StepsForScripts ADD COLUMN IF NOT EXISTS Inserted_Text VARCHAR;
UPDATE StepsForScripts
SET Inserted_Text = CASE WHEN getvariable('wa_attr_unescape')
        THEN replace(replace(replace(replace(replace(
                 xml_extract_text(Step_XML, '//Parameter[@type=''Text'']/Text/@value')[1],
                 '&#38;','&'), '&#60;','<'), '&#62;','>'), '&#34;','"'), '&#39;','''')
        ELSE xml_extract_text(Step_XML, '//Parameter[@type=''Text'']/Text/@value')[1] END
WHERE Step_ID = 61;  -- 'Insert Text'


-- ============================================
-- A.8: StepsForScripts.Comment_Text — Kommentartext für DDR-lose Dateien
-- ============================================
-- Die Script-Detailansicht (object_details_script_tokens.sql) bezieht Text UND
-- kind-Klassifikation jeder Zeile aus dem DDR-Join — Dateien OHNE DDR-Info
-- (Has_DDR_INFO=False) rendern Kommentar-Steps dadurch als leere Zeilen
-- (kind='empty'), obwohl der Text die ganze Zeit in Step_XML liegt. Analog
-- Inserted_Text (A.7) hier beim Konvertieren in eine Hilfsspalte vorberechnet;
-- der READ_ONLY-API-Server macht nur noch COALESCE (kann webbed nicht laden).
-- Beide Comment-Formen: Attribut <Comment value="…"/> (Korpus-Standard) und
-- Element <Comment>…</Comment> (Fallback); leere Platzhalter (<Comment/>)
-- bleiben NULL → kind='empty', konsistent mit der Dashboard-Heuristik
-- (leere Kommentare = keine Dokumentation). Entity-Dekodierung durch
-- xml_extract_text; @value-Pfad mit demselben wa_attr_unescape-gegateten
-- Zweitpass wie A.7 (SAX-Doppel-Escape numerischer Char-Refs, chirurgisch —
-- inkl. des in A.7 dokumentierten Tradeoffs bei literalen `&#NN;`-Strings).
ALTER TABLE StepsForScripts ADD COLUMN IF NOT EXISTS Comment_Text VARCHAR;
UPDATE StepsForScripts
SET Comment_Text = COALESCE(
        NULLIF(CASE WHEN getvariable('wa_attr_unescape')
            THEN replace(replace(replace(replace(replace(
                     xml_extract_text(Step_XML, '//Comment/@value')[1],
                     '&#38;','&'), '&#60;','<'), '&#62;','>'), '&#34;','"'), '&#39;','''')
            ELSE xml_extract_text(Step_XML, '//Comment/@value')[1] END, ''),
        NULLIF(xml_extract_text(Step_XML, '//Comment')[1], '')
    )
WHERE Step_ID = 89;  -- '# (comment)'


-- ============================================
-- A.9: StepCalculations — alle Berechnungs-Slots eines Steps
-- ============================================
-- StepsForScripts.Calculation_Text trägt nur die ERSTE Berechnung eines Steps
-- (Dokument-Reihenfolge, ohne Repetitions-/Geometrie-Slots — siehe P1). Viele
-- Step-Typen führen aber MEHRERE positionierte Berechnungen (Set Variable:
-- value+repetition; New Window: Name+height+width+top+left; Insert from URL:
-- URL+cURL-Optionen; Show Custom Dialog: Title+Message+Inputs; …). Diese Tabelle
-- löst JEDE <Calculation @position> in eine eigene Zeile auf, mit Slot-Kontext:
--   Slot          — Name des Elternelements des Calculation-Wrappers (Name, height,
--                   URL, Title, value, repetition, …); liegt der Wrapper direkt
--                   unter <Parameter>, stattdessen 'Parameter:<type>'.
--   Calc_Position — @position des Wrappers. NICHT step-eindeutig (FileMaker
--                   startet die Nummerierung in manchen Parameter-Containern neu,
--                   z.B. Data-File-Steps) — Eindeutigkeit nur zusammen mit Slot
--                   und Slot_Seq.
--   Slot_Seq      — 1-basierte Ordnungszahl INNERHALB eines Slot-Elternteils
--                   (z.B. die Argumentliste von Perform JavaScript in Web Viewer:
--                   mehrere Calculations unter EINEM <Parameter type="Parameter">).
-- Phase-Wahl analog A.7/A.8: P3 läuft einmal auf der Master-DB, liest das in P1
-- persistierte (bereits ws_restore-te) Step_XML → kein eigener SAX-Zweig nötig.
-- DROP+CREATE (Muster VariableUsages): vollständiger Neuaufbau je P3-Lauf.

DROP TABLE IF EXISTS StepCalculations;

CREATE TABLE StepCalculations AS
WITH slot_parents AS (
    SELECT
        s.Step_UUID, s.File_Name, s.Script_UUID, s.Script_Name, s.Script_ID,
        s.Step_Index, s.Step_ID, s.Step_Name, s.Is_Enabled,
        unnest(xml_extract_elements(s.Step_XML, '//*[Calculation[@position]]')) AS slot_xml
    FROM StepsForScripts s
    WHERE s.Step_XML LIKE '%<Calculation%'
),
slot_calcs AS (
    SELECT
        Step_UUID, File_Name, Script_UUID, Script_Name, Script_ID,
        Step_Index, Step_ID, Step_Name, Is_Enabled,
        CASE WHEN regexp_extract(slot_xml::VARCHAR, '^<([A-Za-z]+)', 1) = 'Parameter'
             THEN 'Parameter:' || coalesce(xml_extract_text(slot_xml, '/Parameter/@type')[1], '')
             ELSE regexp_extract(slot_xml::VARCHAR, '^<([A-Za-z]+)', 1) END AS Slot,
        unnest(xml_extract_elements(slot_xml, '/*/Calculation[@position]')) AS calc_xml,
        generate_subscripts(xml_extract_elements(slot_xml, '/*/Calculation[@position]'), 1) AS Slot_Seq
    FROM slot_parents
)
SELECT
    Step_UUID, File_Name, Script_UUID, Script_Name, Script_ID,
    Step_Index, Step_ID, Step_Name, Is_Enabled,
    Slot,
    xml_extract_text(calc_xml, '/Calculation/@position')[1]::BIGINT AS Calc_Position,
    Slot_Seq,
    xml_extract_text(calc_xml, '/Calculation/Calculation/Text')[1] AS Calc_Text
FROM slot_calcs;


-- ============================================
-- A.10: StepsForScripts.Opens_Window — fensteröffnende Steps markieren
-- ============================================
-- Ein neues Fenster öffnen zwei Step-Typen: New Window (Step_ID 122, immer) und
-- Go to Related Record (Step_ID 74, NUR mit gesetzter "New window"-Option). Die
-- GTRR-Option ist im Katalog ausschließlich strukturell erkennbar (<WindowReference>
-- im Step_XML; Parameter_Type ist bei beiden GTRR-Varianten 'Related', der DDR-Text
-- ist lokalisiert). Hier einmalig beim Import abgeleitet, damit Analyse-Queries und
-- SCA-Regeln (Fenster-Lebenszyklus) nicht zur Laufzeit über Step_XML scannen müssen.
-- Nur für die beiden fensterfähigen Step-IDs belegt (TRUE/FALSE), sonst NULL —
-- bewusst KEIN Full-Table-UPDATE (StepsForScripts kann Millionen Zeilen haben).
-- Additiv/idempotent analog Inserted_Text (A.7).

ALTER TABLE StepsForScripts ADD COLUMN IF NOT EXISTS Opens_Window BOOLEAN;
UPDATE StepsForScripts
SET Opens_Window = (Step_ID = 122 OR Step_XML LIKE '%<WindowReference%')
WHERE Step_ID IN (74, 122);  -- 74 = Go to Related Record, 122 = New Window


-- ============================================
-- A.11: Layouts.L_Theme_Resolved_* — effektives Theme je Layout
-- ============================================
-- SaXML kodiert das Classic-Theme als LEERES Element: `<LayoutThemeReference/>`
-- ohne id/name/UUID/Base. Nur Layouts mit einem NICHT-Classic-Theme tragen das
-- Attribut-Tripel. P1 bildet das 1:1 ab — L_Theme_ID/_Name/_UUID/_Base bleiben
-- für jedes Classic-Layout NULL. Ein Konsument, der auf
-- L_Theme_Name/_Base = 'com.filemaker.theme.classic' prüft, findet deshalb NIE
-- ein Classic-Layout (die Zeichenkette steht in keinem einzigen Layout-Datensatz);
-- die uses_theme-Kante (P4) blieb aus demselben Grund für Classic komplett leer,
-- das Classic-Theme erschien in jeder Datei als „unbenutzt".
--
-- Die Deutung „leere Referenz = Classic" ist am Korpus beidseitig verifiziert:
-- genau die Dateien mit themenlosen Layouts führen com.filemaker.theme.classic
-- im ThemeCatalog, und Classic wird von keinem Layout je explizit referenziert
-- (der ThemeCatalog listet nur tatsächlich verwendete Themes).
--
-- Die Rohspalten bleiben unangetastet (roh = „was stand im Export"); die
-- Auflösung kommt in eigene Spalten:
--   L_Theme_Resolved_Name — effektiver Theme-Name, locale-unabhängig
--                           (Anzeigename via ThemeCatalog.Theme_Display)
--   L_Theme_Resolved_UUID — effektive Theme-UUID (für Joins/Kanten)
-- Nur für echte Layouts belegt — Ordner (Folder_Type 'True'/'Marker') und
-- Trenner haben nie ein Theme und bleiben NULL.
--
-- Theme_ID = 1 ist NICHT verlässlich Classic (im Korpus tragen zwei Dateien dort
-- ein anderes Theme) — die UUID wird deshalb über den Theme-NAMEN aufgelöst,
-- nie über die datei-lokale ID. Fehlt der Classic-Eintrag im ThemeCatalog einer
-- Datei, bleibt die UUID NULL; der Name wird trotzdem gesetzt (die leere
-- Referenz ist auch ohne Katalogeintrag eindeutig).
-- Additiv/idempotent analog Opens_Window (A.10).

ALTER TABLE Layouts ADD COLUMN IF NOT EXISTS L_Theme_Resolved_Name VARCHAR;
ALTER TABLE Layouts ADD COLUMN IF NOT EXISTS L_Theme_Resolved_UUID VARCHAR;

UPDATE Layouts l
SET L_Theme_Resolved_Name = COALESCE(
        l.L_Theme_Name,
        'com.filemaker.theme.classic'
    ),
    L_Theme_Resolved_UUID = COALESCE(
        l.L_Theme_UUID,
        (SELECT tc.Theme_UUID FROM ThemeCatalog tc
          WHERE tc.File_Name = l.File_Name
            AND tc.Theme_Name = 'com.filemaker.theme.classic'
          LIMIT 1)
    )
-- Ordner-/Trenner-Prädikat identisch zur uses_theme-Kante in P4: isFolder liefert
-- 'True'/'Marker' für Ordner bzw. Trennlinien, echte Layouts sind NULL (oder
-- 'False', defensiv mitgeführt).
WHERE (l.Folder_Type IS NULL OR l.Folder_Type = 'False')
  AND NOT COALESCE(l.Is_Separator, FALSE);


-- ============================================
-- A.12: LayoutObjectConditions — Conditional-Formatting-Regeln (Schema 1.25.0)
-- ============================================
-- Eine Zeile pro CF-Regel, DEPTH-VERANKERT extrahiert: Object_XML jedes
-- Layout-Objekts hat die Wurzel <LayoutObject>, die EIGENEN Regeln liegen exakt
-- unter /LayoutObject/Conditions/Formatting/Condition. Container nesten die
-- Kind-XML eine oder mehr LayoutObject-Ebenen tiefer — der depth-Pfad erfasst
-- sie nicht (kein Leaf-Filter nötig; Container mit EIGENEN Regeln, die ein
-- Leaf-Filter verlöre, werden korrekt gezählt). <Conditions> hat genau zwei
-- mögliche Kinder, Formatting (CF) und Hide — der Pfad über Formatting schließt
-- die Hide-Bedingung strukturell aus.
--
-- Korpus-verifizierte Struktur (Analyse-Doc analyse_conditional_formatting_c1.md):
--   Condition/@type   0 = Formel-Bedingung; 1-13 = wertbasierter Operator
--                     (fixture-verifiziert: 1 zwischen, 2 nicht zwischen,
--                      3 gleich, 4 ungleich, 5 größer, 6 kleiner, 7 größer/
--                      gleich, 8 kleiner/gleich, 9 enthält, 10 enthält nicht,
--                      11 beginnt mit, 12 endet mit, 13 leer — "nicht leer"
--                      existiert in der UI nicht). Wertbasierte Regeln
--                     serialisiert FileMaker IMMER zusätzlich als äquivalente
--                     Self-Formel in Calculation/Text — Calc_Text ist also
--                     auch bei Condition_Kind='value' befüllt.
--   Condition/@id     0-basierte Serialisierungsposition (redundant zu Rule_Index,
--                     nicht persistiert); DDRREF-Suffix Condition_N = Rule_Index.
--   Options           Bitmaske der Format-Auswahl (roh persistiert; Deutung ist
--                     Anzeige-/Parser-Sache). Fixture-verifiziert: Bit0 = Regel
--                     AKTIV (0 = im Dialog deaktiviert), Bit1 Textfarbe,
--                     Bit2 Füllfarbe, Bit4 "Weitere Formatierung", Bit7 Icon-
--                     Farbe; Stil-Toggles (Fett/Kursiv/Unterstrichen/Durch-
--                     gestrichen) setzen KEIN Bit, nur LocalCSS-Properties.
--   Range/Start|End   Operanden wertbasierter Regeln als roher Ausdruckstext
--                     (Zahlen, zitierte Strings, auch Variablen/Ausdrücke).
--                     FileMaker schreibt den Text selbst entity-VORkodiert
--                     (&quot;aktiv&quot; als Textinhalt) — nach dem XML-Decode
--                     von xml_extract_text bleibt diese Vorkodierung stehen,
--                     daher der wa_entity_decode-gegatete html_unescape-Zweitpass
--                     (Muster A.3; idempotent für unkodierte Werte).
--                     Range ist NICHT typ-autoritativ: ein Operator-Wechsel im
--                     Dialog kann ein Rest-Range an einer type-0-Regel hinterlassen.
--   LocalCSS          angewandtes Format als roher CSS-Regelsatz (CDATA) — die
--                     Aufbereitung in Anzeige-Eigenschaften macht bewusst die
--                     API/das Frontend (Theme-Vokabular ohne Re-Import erweiterbar).
--
-- Calculation_UUID (FK auf CalculationsCatalog, Rolle 'conditional_format') wird
-- in P4 NACH dem CalculationsCatalog-Aufbau gefüllt — Join über
-- Calc_Kind_Raw = 'Condition_' || Rule_Index, NICHT über Index-Gleichheit:
-- DDRREF-lose Regeln (wertbasiert ohne Anker, Dateien ohne DDR-Info) erzeugen
-- Lücken in Calc_Index. Bleibt NULL für Regeln ohne CalculationsCatalog-Zeile.
--
-- Formatting_Membercount: @membercount des eigenen Formatting-Blocks (korpus-
-- verifiziert == eigene Regelzahl bei 8.745/8.745 Objekten) — persistiert als
-- Anti-Nesting-Guard-Basis für P6 (v_check_cf_rules), table-only auswertbar.
-- DROP+CREATE (Muster VariableUsages/StepCalculations): Neuaufbau je P3-Lauf.

DROP TABLE IF EXISTS LayoutObjectConditions;

CREATE TABLE LayoutObjectConditions AS
WITH lo AS (
    -- Dedup analog P4 lo_rep: LayoutObjects kann Doppel-Zeilen je
    -- (Object_UUID, File_Name) tragen — deterministischer Erst-Vertreter.
    SELECT Object_UUID, File_Name, Layout_ID,
           CAST(Object_XML AS VARCHAR) AS xml_str,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    -- Grob-Vorfilter; Container ohne eigene Regeln matchen (genestete Kind-XML),
    -- liefern aber am depth-Pfad eine leere Liste → keine Zeilen.
    WHERE Object_XML LIKE '%<Condition type=%'
),
conds AS (
    -- unnest und generate_subscripts über DIESELBE Listen-Spalte bleiben
    -- zeilen-aligniert → Rule_Index = 1-basierte Serialisierungsreihenfolge
    -- (== FileMaker-Dialogreihenfolge == Condition/@id + 1 == DDRREF-Suffix N).
    SELECT
        Object_UUID, File_Name, Layout_ID,
        TRY_CAST(xml_extract_text(xml_str, '/LayoutObject/Conditions/Formatting/@membercount')[1] AS BIGINT) AS Formatting_Membercount,
        unnest(xml_extract_elements(xml_str, '/LayoutObject/Conditions/Formatting/Condition')) AS cond_xml,
        generate_subscripts(xml_extract_elements(xml_str, '/LayoutObject/Conditions/Formatting/Condition'), 1) AS Rule_Index
    FROM lo
    WHERE rn = 1
)
SELECT
    -- Typ-getaggter synthetischer Schlüssel (docs/agents/synthetic-uuids.md);
    -- File_Name im Schlüssel, weil Object_UUIDs nur je Datei eindeutig sind.
    md5('CFRule::' || File_Name || '::' || Object_UUID || '::' || Rule_Index) AS Rule_UUID,
    Object_UUID,
    Layout_ID,
    Rule_Index,
    TRY_CAST(xml_extract_text(cond_xml, '/Condition/@type')[1] AS BIGINT)    AS Condition_Type,
    CASE TRY_CAST(xml_extract_text(cond_xml, '/Condition/@type')[1] AS BIGINT)
        WHEN 0 THEN 'formula'
        ELSE 'value'
    END                                                                      AS Condition_Kind,
    TRY_CAST(xml_extract_text(cond_xml, '/Condition/Options')[1] AS BIGINT)  AS Options_Raw,
    -- CDATA-Inhalt ist literal (keine FM-Vorkodierung) — kein Zweitpass nötig.
    NULLIF(xml_extract_text(cond_xml, '/Condition/Calculation/Text')[1], '') AS Calc_Text,
    NULLIF(xml_extract_text(cond_xml, '/Condition/Calculation/DDRREF/@hash')[1], '') AS Calc_Hash,
    CAST(NULL AS VARCHAR)                                                    AS Calculation_UUID,  -- P4 füllt
    CASE WHEN getvariable('wa_entity_decode')
         THEN NULLIF(html_unescape(xml_extract_text(cond_xml, '/Condition/Range/Start')[1]), '')
         ELSE NULLIF(xml_extract_text(cond_xml, '/Condition/Range/Start')[1], '') END AS Range_Start,
    CASE WHEN getvariable('wa_entity_decode')
         THEN NULLIF(html_unescape(xml_extract_text(cond_xml, '/Condition/Range/End')[1]), '')
         ELSE NULLIF(xml_extract_text(cond_xml, '/Condition/Range/End')[1], '') END   AS Range_End,
    Formatting_Membercount,
    NULLIF(xml_extract_text(cond_xml, '/Condition/LocalCSS')[1], '')         AS Local_CSS,
    File_Name
FROM conds;

CREATE INDEX idx_layoutobjectconditions_owner ON LayoutObjectConditions(Object_UUID, File_Name);


-- ========================================
-- A.13: LayoutObjectSymbols — Symbol-Inventar {{…}} (Schema 1.27.0)
-- ========================================
-- Symbole ({{CurrentDate}}, {{FoundCount}}, …) sind Laufzeit-Platzhalter im
-- Textblock — semantisch das Ergebnis von Get(X) zur Anzeigezeit, aber KEINE
-- Katalogobjekte: bewusst keine Where-used-Kanten (Minimal-Entscheid der
-- Merge-Familien-Analyse), nur Inventar am tragenden Text-LayoutObject.
-- Symbol_Norm (lower) als case-robuster Gruppierungsschlüssel — Symbole sind
-- laut Claris-Doku case-insensitiv tippbar ({{currenttime}} ≡ {{CurrentTime}}).
-- Dedup analog A.12/P4 lo_rep: LayoutObjects kann Doppel-Zeilen je
-- (Object_UUID, File_Name) tragen.
DROP TABLE IF EXISTS LayoutObjectSymbols;
CREATE TABLE LayoutObjectSymbols AS
WITH lo_dedup AS (
    SELECT Object_UUID, Layout_ID, File_Name, Text_Content,
           ROW_NUMBER() OVER (PARTITION BY Object_UUID, File_Name ORDER BY Object_ID) AS rn
    FROM LayoutObjects
    WHERE Text_Content LIKE '%{{%'
),
sym AS (
    SELECT Object_UUID, Layout_ID, File_Name,
           unnest(regexp_extract_all(Text_Content, '\{\{\s*([A-Za-z][A-Za-z0-9]*)\s*\}\}', 1)) AS Symbol_Text
    FROM lo_dedup
    WHERE rn = 1
)
SELECT
    Object_UUID,
    Layout_ID,
    File_Name,
    Symbol_Text,
    lower(Symbol_Text) AS Symbol_Norm,
    count(*)           AS Occurrence_Count
FROM sym
GROUP BY ALL;

CREATE INDEX idx_layoutobjectsymbols_owner ON LayoutObjectSymbols(Object_UUID, File_Name);
