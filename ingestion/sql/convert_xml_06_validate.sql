/*
-- convert_xml_06_validate.sql — Phase 6 der XML-Konvertierungs-Pipeline.
-- Plausibilitäts-/Konsistenz-Checks als
-- wiederverwendbare, versionierte SQL-Views. TABLE-ONLY (liest nur die fertigen
-- Pipeline-Tabellen).
--
-- Abgrenzung zu postprocess_db() (Shell): Diese Datei liefert die Prüf-DATEN
-- (Views); die Shell ruft sie ab, bewertet die Befunde und reportet
-- (Schweregrad, Exit-Code). „Daten-Logik im SQL, Ablauf-/Reporting-Logik im
-- Shell." Vorteil: dieselben Checks sind auch außerhalb des Konvertierungslaufs
-- nutzbar (REST-API, Ad-hoc) und versioniert.
--
-- Wird NICHT in @SCHEMA_HASH_FILES gelistet: rein abgeleitete Prüf-Views,
-- ändern das Datenmodell nicht → sollen keinen Auto-Heal-Rebuild auslösen.
*/

-- Mengen-Plausibilität: eine Zeile mit allen relevanten Zählwerten.
-- Die Bewertung (welche Kombination ein Problem ist) macht die Shell.
CREATE OR REPLACE VIEW v_check_counts AS
SELECT
    (SELECT COUNT(*) FROM FilesCatalog)        AS files_n,
    (SELECT COUNT(*) FROM BaseTableCatalog)    AS basetables_n,
    (SELECT COUNT(*) FROM Layouts)             AS layouts_n,
    (SELECT COUNT(*) FROM LayoutObjects)       AS layoutobjects_n,
    (SELECT COUNT(*) FROM ScriptCatalog
       WHERE (Folder_Type IS NULL OR Folder_Type = 'False')
         AND NOT COALESCE(Is_Separator, FALSE)) AS scripts_n,
    (SELECT COUNT(*) FROM StepsForScripts)     AS steps_n;

-- C1 (primärer Regressions-Wächter): leere/NULL Calc_UUID in DDR_Calculations.
-- Per Slot-erhaltendem Regex in convert_xml_01_extract.sql per Konstruktion 0.
CREATE OR REPLACE VIEW v_check_calc_uuid AS
SELECT COUNT(*) AS bad_calc_uuid
FROM DDR_Calculations
WHERE Calc_UUID = '' OR Calc_UUID IS NULL;

-- Verwaiste Same-File-Link-Ziele: ObjectLinks-Ziele ohne ObjectCatalog-Eintrag.
-- Cross-File-Links sind ausgenommen (die lösen sauber auf). Ziel: ECHTE Zahl,
-- KEIN Cap — der frühere `LIMIT 100` machte aus einem realen 1.877 ein "100"
-- und verschleierte die Größenordnung.
--
-- Wichtige Unterscheidung (Schweregrad macht die Shell): Auf einem UNVOLLSTÄNDIGEN
-- Mehrdatei-Korpus sind solche Orphans ERWARTBAR — Referenzen (Relationship-
-- Prädikatfelder, displays_field, calls_script, Import-/Export-Mappings) zeigen in
-- externe Dateien, die nicht mit-importiert wurden; deren Objekte stehen in keinem
-- Katalog. `missing_ext_files` liefert genau diesen Kontext: referenzierte externe
-- FileMaker-Dateien (ExternalDataSourceCatalog), die nicht in FilesCatalog sind.
-- Erst wenn missing_ext_files = 0 (Korpus vollständig) deuten Orphans auf echte
-- tote Referenzen / ein Integritätsproblem. (Nicht primär ein --split-Effekt.)
CREATE OR REPLACE VIEW v_check_orphan_links AS
SELECT
    (SELECT COUNT(*) FROM (
        SELECT DISTINCT Target_UUID
        FROM ObjectLinks
        WHERE Target_UUID IS NOT NULL AND Target_UUID <> ''
          AND COALESCE(Is_Cross_File, FALSE) = FALSE
          AND Target_UUID NOT IN (SELECT Object_UUID FROM ObjectCatalog)
    )) AS orphan_n,
    (SELECT COUNT(*) FROM (
        SELECT DISTINCT regexp_replace(DS_Name, '\.fmp12$', '') AS ref_file
        FROM ExternalDataSourceCatalog
        WHERE (DS_Type ILIKE '%FileMaker%' OR DS_Type IS NULL)
          AND DS_Name IS NOT NULL AND DS_Name <> ''
    ) ref WHERE ref.ref_file NOT IN (SELECT File_Name FROM FilesCatalog)) AS missing_ext_files;

-- Schema-Stand der DB (aktuellste SchemaInfo-Zeile). Die Shell vergleicht die
-- Version gegen die Template-Version (@SCHEMA_VERSION) — die liegt nur im Shell-
-- Kontext vor, daher findet der Vergleich dort statt.
CREATE OR REPLACE VIEW v_check_schema AS
SELECT Schema_Version AS db_version
FROM SchemaInfo
ORDER BY Schema_Built_At DESC
LIMIT 1;

-- Synthetik-Regression: „abgeleitete Rolle X darf nicht leer sein, wenn Quelle Y
-- befüllt ist". Fängt die gefährlichste Fehlerklasse der Pipeline — stumme
-- 0-Zeilen-INSERTs nach Pattern-/Namenskonventions-Drift (z.B. die
-- PluginComponent-Regression 'MBS::%' vs. 'MBS:%'). Eine Zeile pro Regel;
-- Verletzung = source_n > 0 AND derived_n = 0 (Bewertung in der Shell).
-- Hinweis contains_menu: Quelle sind Menü-Sets mit Member-Liste; ein Korpus,
-- dessen Sets ausschließlich Built-in-Menüs referenzieren, würde die Regel
-- formal verletzen (Built-ins erzeugen bewusst keine Links) — dann Regel prüfen,
-- nicht blind fixen.
CREATE OR REPLACE VIEW v_check_synthetic AS
SELECT 'plugincomponent_objects' AS rule,
       (SELECT COUNT(*) FROM ObjectCatalog WHERE Object_Type = 'PluginFunction') AS source_n,
       (SELECT COUNT(*) FROM ObjectCatalog WHERE Object_Type = 'PluginComponent') AS derived_n
UNION ALL
SELECT 'groups_into_links',
       (SELECT COUNT(*) FROM ObjectCatalog WHERE Object_Type = 'PluginFunction'),
       (SELECT COUNT(*) FROM ObjectLinks WHERE Link_Role = 'groups_into')
UNION ALL
SELECT 'contains_menu_links',
       (SELECT COUNT(*) FROM CustomMenuSetCatalog
         WHERE Member_Menu_IDs IS NOT NULL AND len(Member_Menu_IDs) > 0),
       (SELECT COUNT(*) FROM ObjectLinks WHERE Link_Role = 'contains_menu')
UNION ALL
SELECT 'parent_script_links',
       (SELECT COUNT(*) FROM StepsForScripts),
       (SELECT COUNT(*) FROM ObjectLinks WHERE Link_Role = 'parent_script')
UNION ALL
SELECT 'parent_layout_links',
       (SELECT COUNT(*) FROM LayoutObjects),
       (SELECT COUNT(*) FROM ObjectLinks WHERE Link_Role = 'parent_layout')
UNION ALL
SELECT 'grants_privilege_links',
       (SELECT COUNT(*) FROM ExtendedPrivilegesCatalog
         WHERE PrivilegeSet_IDs IS NOT NULL AND len(PrivilegeSet_IDs) > 0),
       (SELECT COUNT(*) FROM ObjectLinks WHERE Link_Role = 'grants_privilege')
UNION ALL
-- Hinweis uses_theme: Quelle ist die AUFGELÖSTE Theme-UUID (P3/A.11), nicht die
-- rohe L_Theme_UUID — SaXML kodiert Classic als leere <LayoutThemeReference/>,
-- die Rohspalte ist dort NULL und unterzählte die Erwartung massiv.
SELECT 'uses_theme_links',
       (SELECT COUNT(*) FROM Layouts WHERE L_Theme_Resolved_UUID IS NOT NULL
         AND (Folder_Type IS NULL OR Folder_Type = 'False')
         AND NOT COALESCE(Is_Separator, FALSE)),
       (SELECT COUNT(*) FROM ObjectLinks WHERE Link_Role = 'uses_theme')
UNION ALL
-- Calculation-Objekttyp (Schema 1.22.0): jede CalculationsCatalog-Zeile muss
-- als ObjectCatalog-Eintrag existieren; jede Zeile mit aufgelöstem Owner
-- zusätzlich als has_calculation-Kante.
SELECT 'calculation_objects',
       (SELECT COUNT(*) FROM CalculationsCatalog),
       (SELECT COUNT(*) FROM ObjectCatalog WHERE Object_Type = 'Calculation')
UNION ALL
SELECT 'has_calculation_links',
       (SELECT COUNT(*) FROM CalculationsCatalog WHERE Owner_Type <> 'unresolved'),
       (SELECT COUNT(*) FROM ObjectLinks WHERE Link_Role = 'has_calculation');

-- Rollen-Registry-Vollständigkeit: jede in ObjectLinks aktive Rolle muss
-- in LinkRoleRegistry klassifiziert sein (usage/containment/restriction) — sonst
-- arbeiten Where-used-/Graph-Konsumenten mit undokumentierter Semantik. Fängt
-- „neue Rolle eingeführt, Registry vergessen".
CREATE OR REPLACE VIEW v_check_link_roles AS
SELECT COUNT(*) AS unregistered_roles,
       string_agg(Link_Role, ', ') AS role_list
FROM (
    SELECT DISTINCT ol.Link_Role
    FROM ObjectLinks ol
    LEFT JOIN LinkRoleRegistry r ON r.Link_Role = ol.Link_Role
    WHERE r.Link_Role IS NULL
);

-- Duplikat-Wächter ObjectCatalog — (Object_UUID, File_Name) muss eindeutig
-- sein (heute 0, genau deshalb billig). Ein Treffer = Composite-UUID-Kollision
-- (B-C4-Klasse: synthetische UUIDs ohne/mit falschem Namespace-Präfix) oder ein
-- Katalog-Block, der dasselbe Objekt doppelt registriert.
CREATE OR REPLACE VIEW v_check_catalog_dups AS
SELECT COUNT(*) AS dup_n,
       string_agg(Object_UUID || ' (' || File_Name || ' ×' || cnt || ')', ', ') AS sample
FROM (
    SELECT Object_UUID, File_Name, COUNT(*) AS cnt
    FROM ObjectCatalog
    GROUP BY 1, 2
    HAVING COUNT(*) > 1
    ORDER BY cnt DESC
    LIMIT 20
);

-- Variablen-Identität (Klon-Dateien) — lokale Variablen (local, let_local)
-- gehören genau einer Datei: P3 führt sie in VariablesCatalog je (Name, Scope,
-- Anker, Datei). Klon-Dateien teilen Script- und Kontext-UUIDs und damit den
-- Anker; eine Zeile mit File_Count > 1 heißt, die Variablen zweier Dateien
-- sind zu einer Katalogzeile zusammengelegt — ihre Kanten zeigten dann auf die
-- Variable der anderen Datei. Soll 0.
CREATE OR REPLACE VIEW v_check_variable_identity AS
WITH merged AS (
    SELECT Variable_Name, Variable_Scope, Files
    FROM VariablesCatalog
    WHERE Variable_Scope IN ('local', 'let_local') AND File_Count > 1
)
SELECT
    (SELECT COUNT(*) FROM merged) AS merged_n,
    (SELECT COUNT(*) FROM merged WHERE Variable_Scope = 'local') AS local_n,
    (SELECT COUNT(*) FROM merged WHERE Variable_Scope = 'let_local') AS let_local_n,
    (SELECT string_agg(Variable_Name || ' [' || Variable_Scope || '] (' || array_to_string(Files, ', ') || ')', '; ')
     FROM (SELECT * FROM merged ORDER BY Variable_Name, Variable_Scope LIMIT 10)) AS sample;

-- Kardinalitäts-Wächter (Klon-Fan-out) — strukturelle 1:1-Beziehungen,
-- die durch UUID-Mehrdeutigkeit (Klon-Korpora) auffächern würden:
--   TableOccurrence → base_table  genau 1
--   LayoutObject    → parent_layout (operational, Block 9)  genau 1
--   ScriptStep      → parent_script  genau 1
--   Layout          → context_table  ≤ 1
CREATE OR REPLACE VIEW v_check_cardinality AS
SELECT rule, COUNT(*) AS violation_n FROM (
    SELECT 'to_base_table' AS rule, Source_UUID
    FROM ObjectLinks WHERE Link_Role = 'base_table' AND Source_Type = 'TableOccurrence'
    GROUP BY Source_UUID, Source_File HAVING COUNT(*) > 1
    UNION ALL
    SELECT 'lo_parent_layout', Source_UUID
    FROM ObjectLinks WHERE Link_Role = 'parent_layout' AND Source_Type = 'LayoutObject'
    GROUP BY Source_UUID, Source_File HAVING COUNT(*) > 1
    UNION ALL
    SELECT 'step_parent_script', Source_UUID
    FROM ObjectLinks WHERE Link_Role = 'parent_script' AND Source_Type = 'ScriptStep'
    GROUP BY Source_UUID, Source_File HAVING COUNT(*) > 1
    UNION ALL
    SELECT 'layout_context_table', Source_UUID
    FROM ObjectLinks WHERE Link_Role = 'context_table' AND Source_Type = 'Layout'
    GROUP BY Source_UUID, Source_File HAVING COUNT(*) > 1
)
GROUP BY rule;

-- Phantom-Signatur-Wächter (Klon-Korpora) — ALLE operationalen Rollen: eine Kante
-- (Source, Rolle, Target_UUID), die über >1 Ziel-Dateien auffächert, ist ein
-- Klon-Artefakt-Kandidat. Nach dem prefer-declared-source-Pass (P4) dürfen nur
-- Gruppen übrig sein, deren Quelldatei KEINE (undeclared) oder MEHRERE
-- (multi_declared) der Ziel-Dateien als Datenquelle deklariert — die ehrliche
-- Modellgrenze. declared=1-Gruppen hier ⇒ der P4-Pass hat ein Leck.
CREATE OR REPLACE VIEW v_check_phantom_links AS
SELECT Link_Role,
       COUNT(*) AS phantom_groups,
       SUM(CASE WHEN declared_n = 1 THEN 1 ELSE 0 END) AS declared_one_groups,
       SUM(CASE WHEN declared_n = 0 THEN 1 ELSE 0 END) AS undeclared_groups,
       SUM(CASE WHEN declared_n > 1 THEN 1 ELSE 0 END) AS multi_declared_groups
FROM (
    SELECT ol.Source_UUID, ol.Source_File, ol.Link_Role, ol.Target_UUID,
           COUNT(DISTINCT d.Resolved_File) AS declared_n
    FROM ObjectLinks ol
    LEFT JOIN (SELECT DISTINCT File_Name, Resolved_File FROM DataSourceFileMap) d
           ON d.File_Name = ol.Source_File
          AND d.Resolved_File = ol.Target_File
    WHERE ol.Link_Type = 'operational'
      AND ol.Target_File IS NOT NULL
    GROUP BY ol.Source_UUID, ol.Source_File, ol.Link_Role, ol.Target_UUID
    HAVING COUNT(DISTINCT ol.Target_File) > 1
)
GROUP BY Link_Role;

-- XML-Zählung vs. Katalog-Zeilen — Sequence_ID ist ROW_NUMBER() in
-- XML-Reihenfolge (+seq_offset, je Datei ab 1): MAX(Sequence_ID) = Zahl der im
-- XML gesehenen Records. COUNT(*) < MAX ⇒ der UPSERT hat UUID-Dubletten still
-- kollabiert (B-K3-Klasse, stiller Datenverlust).
CREATE OR REPLACE VIEW v_check_xml_counts AS
SELECT catalog, File_Name, rows_n, max_seq FROM (
    SELECT 'ScriptCatalog' AS catalog, File_Name,
           COUNT(*) AS rows_n, MAX(Sequence_ID) AS max_seq
    FROM ScriptCatalog GROUP BY File_Name
    UNION ALL
    SELECT 'Layouts', File_Name, COUNT(*), MAX(Sequence_ID)
    FROM Layouts GROUP BY File_Name
)
WHERE rows_n <> max_seq;

-- Generischer Dup-Absorption-Zensus — absorbierte UUID-Dubletten je Katalog/Datei.
-- Source_Records kommt aus dem P1-Zensus (DuplicateAbsorptions, je Chunk eine Zeile →
-- SUM je Katalog/Datei; grenz-robust beim Sub-Chunking). Stored_Rows wird LIVE aus den
-- Katalogtabellen gezählt (nicht persistiert → nie stale, kein Nach-Zensus-Schritt).
-- ScriptCatalog/Layouts brauchen keinen P1-Zensus: MAX(Sequence_ID) IST der Record-
-- Zähler in XML-Reihenfolge — dadurch für diese beiden deckungsgleich mit dem XML-Zähl-Wächter
-- (Selbsttest des Mechanismus). Absorbed > 0 ⇒ stiller Zeilenverlust durch
-- Quelldefekt (doppelte UUIDs im FileMaker-Export, Klasse B-K3).
CREATE TABLE IF NOT EXISTS DuplicateAbsorptions (
    File_Name VARCHAR NOT NULL,
    Catalog VARCHAR NOT NULL,
    PK_Columns VARCHAR,
    Chunk_Seq BIGINT NOT NULL DEFAULT 0,
    Source_Records BIGINT,
    PRIMARY KEY (Catalog, File_Name, Chunk_Seq)
);
CREATE OR REPLACE VIEW v_check_absorbed_dups AS
WITH source_counts AS (
    SELECT Catalog, File_Name, SUM(Source_Records) AS Source_Records
    FROM DuplicateAbsorptions GROUP BY Catalog, File_Name
    UNION ALL
    SELECT 'ScriptCatalog', File_Name, MAX(Sequence_ID) FROM ScriptCatalog GROUP BY File_Name
    UNION ALL
    SELECT 'Layouts', File_Name, MAX(Sequence_ID) FROM Layouts GROUP BY File_Name
),
stored_counts AS (
              SELECT 'ExternalDataSourceCatalog' AS Catalog, File_Name, COUNT(*) AS Stored_Rows FROM ExternalDataSourceCatalog GROUP BY File_Name
    UNION ALL SELECT 'BaseTableCatalog',        File_Name, COUNT(*) FROM BaseTableCatalog        GROUP BY File_Name
    UNION ALL SELECT 'TableOccurrenceCatalog',  File_Name, COUNT(*) FROM TableOccurrenceCatalog  GROUP BY File_Name
    UNION ALL SELECT 'RelationshipCatalog',     File_Name, COUNT(*) FROM RelationshipCatalog     GROUP BY File_Name
    UNION ALL SELECT 'FieldsForTables',         File_Name, COUNT(*) FROM FieldsForTables         GROUP BY File_Name
    UNION ALL SELECT 'ValueListCatalog',        File_Name, COUNT(*) FROM ValueListCatalog        GROUP BY File_Name
    UNION ALL SELECT 'OptionsForValueLists',    File_Name, COUNT(*) FROM OptionsForValueLists    GROUP BY File_Name
    UNION ALL SELECT 'CustomFunctionsCatalog',  File_Name, COUNT(*) FROM CustomFunctionsCatalog  GROUP BY File_Name
    UNION ALL SELECT 'AccountsCatalog',         File_Name, COUNT(*) FROM AccountsCatalog         GROUP BY File_Name
    UNION ALL SELECT 'StepsForScripts',         File_Name, COUNT(*) FROM StepsForScripts         GROUP BY File_Name
    UNION ALL SELECT 'LayoutObjects',           File_Name, COUNT(*) FROM LayoutObjects           GROUP BY File_Name
    UNION ALL SELECT 'ScriptCatalog',           File_Name, COUNT(*) FROM ScriptCatalog           GROUP BY File_Name
    UNION ALL SELECT 'Layouts',                 File_Name, COUNT(*) FROM Layouts                 GROUP BY File_Name
)
SELECT
    s.Catalog,
    s.File_Name,
    s.Source_Records,
    COALESCE(t.Stored_Rows, 0) AS Stored_Rows,
    s.Source_Records - COALESCE(t.Stored_Rows, 0) AS Absorbed
FROM source_counts s
LEFT JOIN stored_counts t ON t.Catalog = s.Catalog AND t.File_Name = s.File_Name
WHERE s.Source_Records - COALESCE(t.Stored_Rows, 0) > 0
ORDER BY Absorbed DESC;

-- Zensus-Integrität — Gegenrichtung zu v_check_absorbed_dups. Der P1-Zensus zählt die
-- GEPARSTEN Quell-Records, gespeichert wird nach dem Upsert-Dedup: auf einem korrekten
-- Katalog gilt daher je (Katalog, Datei) Stored_Rows <= Source_Records, und jede Datei
-- mit gespeicherten Zeilen eines zensierten Katalogs trägt eine Zensus-Zeile. Ein
-- Verstoß bedeutet, dass der Zensus nach der Extraktion überschrieben oder verloren
-- wurde (z. B. ein Chunk ohne den Katalog hat den Zähler auf 0 gesetzt) — dann sind
-- auch v_check_absorbed_dups und die Heilungs-Zuordnung (DuplicateAbsorptionDetails)
-- dieser Datei nicht belastbar. Behebung: Re-Import der Datei. ScriptCatalog/Layouts
-- fehlen bewusst: sie haben keinen P1-Zensus (MAX(Sequence_ID) ist ihr Zähler).
CREATE OR REPLACE VIEW v_check_census_integrity AS
WITH source_counts AS (
    SELECT Catalog, File_Name, SUM(Source_Records) AS Source_Records
    FROM DuplicateAbsorptions GROUP BY Catalog, File_Name
),
stored_counts AS (
              SELECT 'ExternalDataSourceCatalog' AS Catalog, File_Name, COUNT(*) AS Stored_Rows FROM ExternalDataSourceCatalog GROUP BY File_Name
    UNION ALL SELECT 'BaseTableCatalog',        File_Name, COUNT(*) FROM BaseTableCatalog        GROUP BY File_Name
    UNION ALL SELECT 'TableOccurrenceCatalog',  File_Name, COUNT(*) FROM TableOccurrenceCatalog  GROUP BY File_Name
    UNION ALL SELECT 'RelationshipCatalog',     File_Name, COUNT(*) FROM RelationshipCatalog     GROUP BY File_Name
    UNION ALL SELECT 'FieldsForTables',         File_Name, COUNT(*) FROM FieldsForTables         GROUP BY File_Name
    UNION ALL SELECT 'ValueListCatalog',        File_Name, COUNT(*) FROM ValueListCatalog        GROUP BY File_Name
    UNION ALL SELECT 'OptionsForValueLists',    File_Name, COUNT(*) FROM OptionsForValueLists    GROUP BY File_Name
    UNION ALL SELECT 'CustomFunctionsCatalog',  File_Name, COUNT(*) FROM CustomFunctionsCatalog  GROUP BY File_Name
    UNION ALL SELECT 'AccountsCatalog',         File_Name, COUNT(*) FROM AccountsCatalog         GROUP BY File_Name
    UNION ALL SELECT 'StepsForScripts',         File_Name, COUNT(*) FROM StepsForScripts         GROUP BY File_Name
    UNION ALL SELECT 'LayoutObjects',           File_Name, COUNT(*) FROM LayoutObjects           GROUP BY File_Name
)
SELECT
    t.Catalog,
    t.File_Name,
    s.Source_Records,
    t.Stored_Rows,
    CASE WHEN s.Source_Records IS NULL THEN 'no census row'
         ELSE 'census below stored rows' END AS Problem
FROM stored_counts t
LEFT JOIN source_counts s ON s.Catalog = t.Catalog AND s.File_Name = t.File_Name
WHERE t.Stored_Rows > 0
  AND (s.Source_Records IS NULL OR t.Stored_Rows > s.Source_Records)
ORDER BY t.File_Name, t.Catalog;

-- Datei-Optionen-Abdeckung — jede importierte Datei trägt genau eine
-- FileOptionsCatalog-Zeile (Metadata-Branch, in jedem SaXML-Export vorhanden). Eine
-- Lücke heißt: die Zeile ist nach der Extraktion verloren gegangen; mit ihr fehlen die
-- Kanten auto_login_account/default_layout und die Datei-Ansicht bleibt leer.
-- Behebung: Re-Import der Datei.
CREATE OR REPLACE VIEW v_check_file_options_coverage AS
SELECT f.File_Name
FROM FilesCatalog f
WHERE NOT EXISTS (SELECT 1 FROM FileOptionsCatalog o WHERE o.File_Name = f.File_Name)
ORDER BY f.File_Name;

-- External-Wertelisten-Auflösung: Wrapper-VLs (Source_Type='External') sollen in P4
-- einen source_valuelist-Link auf die Ziel-VL der Quelldatei erhalten. Nicht auflösbare
-- Ziele (Zieldatei nicht im Korpus, VL-ID/Name dort unbekannt, Datenquelle fehlt) werden
-- hier ausgewiesen statt still verschluckt. Auf einem Teil-Korpus sind Treffer erwartbar
-- (fehlende Zieldatei) — auf dem Voll-Korpus deutet jeder Treffer auf einen toten
-- External-Verweis im FileMaker-Quellbestand oder eine Resolver-Lücke.
CREATE OR REPLACE VIEW v_check_external_vl_unresolved AS
SELECT
    ovl.File_Name,
    ovl.VL_Name        AS Wrapper_VL,
    ovl.External_DS_Name,
    ovl.External_VL_ID,
    ovl.External_VL_Name
FROM OptionsForValueLists ovl
WHERE ovl.Source_Type = 'External'
  AND NOT EXISTS (
      SELECT 1 FROM ObjectLinks ol
      WHERE ol.Source_UUID = ovl.VL_UUID
        AND ol.Source_File = ovl.File_Name
        AND ol.Link_Role = 'source_valuelist'
  );

-- Submenu-Ziel-Auflösung — ein Submenu-Item (isSubMenuItem="True") referenziert
-- sein Ziel-Menü nur per @id (ohne UUID); P4 löst es per (File_Name, Menu_ID) zu einem
-- opens_menu-Link auf. Items ohne Link haben eine nicht auflösbare Ziel-ID (kein Custom-
-- Menu-Katalog-Treffer — z.B. Verweis auf ein Built-in-Menü) und dürfen nicht still
-- verschluckt werden (Akzeptanzkriterium). Der Rest wird hier ausgewiesen.
CREATE OR REPLACE VIEW v_check_submenu_unresolved AS
SELECT
    COUNT(*) AS unresolved_n,
    string_agg(DISTINCT cmi.File_Name, ', ') AS files
FROM CustomMenuItemCatalog cmi
WHERE cmi.Is_SubMenuItem
  AND NOT EXISTS (
      SELECT 1 FROM ObjectLinks ol
      WHERE ol.Source_UUID = cmi.Item_UUID
        AND ol.Source_File = cmi.File_Name
        AND ol.Link_Role = 'opens_menu'
  );

-- Menü-Aktions-Auflösung — ein Menü-Eintrag mit <action>…<ScriptReference> bekommt in
-- P4 eine Kante triggers_script·menu_action, aufgelöst über (Zieldatei, Script-@id).
-- Einträge ohne Kante werden hier ausgewiesen statt still verschluckt. Aufgeteilt nach
-- Ursache: target_file_missing_n = Zieldatei nicht in diesem Import (Teil-Korpus,
-- erwartbar); in_corpus_n = Zieldatei importiert, Script-ID dort aber unbekannt
-- (gelöschtes Script oder Resolver-Lücke). Reine String-Funktionen auf dem
-- <action>-Ausschnitt (P6-Views laufen ohne webbed).
CREATE OR REPLACE VIEW v_check_menu_action_unresolved AS
WITH actions AS (
    SELECT cmi.Item_UUID, cmi.File_Name,
           regexp_extract(cmi.Item_XML, '(?s)<action>(.*)</action>', 1) AS Action_XML
    FROM CustomMenuItemCatalog cmi
    WHERE cmi.Item_XML LIKE '%<ScriptReference%'
),
refs AS (
    SELECT a.Item_UUID, a.File_Name,
           NULLIF(regexp_extract(a.Action_XML, '<DataSourceReference [^>]*UUID="([^"]*)"', 1), '') AS DS_UUID,
           NULLIF(regexp_extract(a.Action_XML, '<DataSourceReference [^>]*name="([^"]*)"', 1), '') AS DS_Name
    FROM actions a
    WHERE a.Action_XML LIKE '%<ScriptReference%'
      AND NOT EXISTS (
          SELECT 1 FROM ObjectLinks ol
          WHERE ol.Source_UUID = a.Item_UUID
            AND ol.Source_File = a.File_Name
            AND ol.Link_Role = 'triggers_script'
            AND ol.Link_Subrole = 'menu_action'
      )
),
classified AS (
    SELECT r.File_Name,
           CASE WHEN r.DS_UUID IS NULL AND r.DS_Name IS NULL THEN r.File_Name
                ELSE COALESCE(d.Resolved_File, regexp_replace(r.DS_Name, '\.fmp12$', ''))
           END AS Target_File
    FROM refs r
    LEFT JOIN DataSourceFileMap d ON d.File_Name = r.File_Name AND d.DS_UUID = r.DS_UUID
)
SELECT
    COUNT(*) AS unresolved_n,
    COUNT(*) FILTER (WHERE fc.File_Name IS NULL)     AS target_file_missing_n,
    COUNT(*) FILTER (WHERE fc.File_Name IS NOT NULL) AS in_corpus_n,
    string_agg(DISTINCT c.File_Name, ', ') AS files
FROM classified c
LEFT JOIN FilesCatalog fc ON fc.File_Name = c.Target_File;

-- Menü-Aktionen mit nicht verdrahteten Bezügen (Report, KEIN Gate): P4 verdrahtet nur
-- Perform Script. Andere Objektbezüge in <action> (Layout, Feld, TO, Werteliste) und
-- Formeln in der Aktion (Script-Parameter, Step-Formeln) bekommen keine Kante — hier
-- sichtbar, damit neue Fälle in fremden Korpora nicht verschluckt werden.
CREATE OR REPLACE VIEW v_report_menu_action_unlinked AS
WITH actions AS (
    SELECT cmi.File_Name, cmi.Item_UUID, cmi.Menu_Name,
           regexp_extract(cmi.Item_XML, '(?s)<action>(.*)</action>', 1) AS Action_XML
    FROM CustomMenuItemCatalog cmi
    WHERE cmi.Item_XML LIKE '%<action>%'
)
SELECT
    File_Name,
    Item_UUID,
    Menu_Name,
    regexp_extract(Action_XML, '<Step [^>]*name="([^"]*)"', 1) AS Step_Name,
    regexp_matches(Action_XML, '<(LayoutReference|FieldReference|TableOccurrenceReference|ValueListReference)[ />]') AS Has_Object_Ref,
    Action_XML LIKE '%<Calculation%' AS Has_Calculation
FROM actions
WHERE regexp_matches(Action_XML, '<(LayoutReference|FieldReference|TableOccurrenceReference|ValueListReference)[ />]')
   OR Action_XML LIKE '%<Calculation%';

-- Chunk_Type-NULL-Wächter — der P3-Backfill für Chunk_Type läuft NACH
-- seinem P2-Konsumenten (toter Verteidigungscode); taucht hier je ein NULL auf,
-- hat sich der P1-Extraktionspfad geändert und die P2-Chunk-Logik arbeitet blind.
CREATE OR REPLACE VIEW v_check_chunk_type_null AS
SELECT COUNT(*) AS null_n FROM DDR_Calculations WHERE Chunk_Type IS NULL;

-- Phase-S/P1-Integritäts-Check: Chunk-KLASSIFIKATION (XML-Attribut /Chunk/@type)
-- gegen Chunk-INHALT — zwei unabhängige Artefakte desselben Ingests. Divergiert
-- der Phase-S/D-Pfad oder verliert der Parse Inhalts-Elemente, bleiben typisierte
-- Chunks mit totem Inhalt zurück: P2 scannt dann voll und findet 0 Referenzen —
-- sichtbar erst am Gate, ohne Datei-/Chunk-Zuordnung. Dieser Check meldet den
-- Mismatch direkt nach P1 pro Datei. Invarianten (korpus-validiert, 840k Chunks):
--   FieldRef            → Inhalt trägt IMMER ein <FieldReference …>-Element mit
--                         UUID-ATTRIBUT — exakt der Anker, über den P2 auflöst
--                         (die TO-Referenz-UUID allein genügt NICHT, sonst bliebe
--                         ein zerstörter Feld-Anker unerkannt). Geprüft wird die
--                         Attribut-PRÄSENZ, nicht der Wert: UUID="" ist ein
--                         bekannter QUELL-Defekt (Leerstring-Refs, Hygiene T4)
--                         und kein Pipeline-Schaden
--   benannte Ref-Typen  → Inhalt (Funktions-/Variablenname) ist nie leer
-- Bewusst OHNE gsub-/Zähler-Logik (n>0 trotz No-op ist belegt) — reiner
-- Output-Vergleich auf dem ingestierten Bestand.
CREATE OR REPLACE VIEW v_check_chunk_refs AS
SELECT File_Name,
       SUM(CASE WHEN Chunk_Type = 'FieldRef'
                 AND NOT regexp_matches(Chunk_Content, 'FieldReference[^>]*UUID="')
                THEN 1 ELSE 0 END) AS fieldref_no_uuid,
       SUM(CASE WHEN Chunk_Type IN ('CustomFunctionRef','PluginFunctionRef','FunctionRef','VariableReference')
                 AND trim(regexp_replace(Chunk_Content, '^<Chunk[^>]*>|</Chunk>$', '', 'g')) = ''
                THEN 1 ELSE 0 END) AS namedref_empty,
       MIN(CASE WHEN (Chunk_Type = 'FieldRef'
                       AND NOT regexp_matches(Chunk_Content, 'FieldReference[^>]*UUID="'))
                  OR (Chunk_Type IN ('CustomFunctionRef','PluginFunctionRef','FunctionRef','VariableReference')
                       AND trim(regexp_replace(Chunk_Content, '^<Chunk[^>]*>|</Chunk>$', '', 'g')) = '')
                THEN Calc_UUID || '#' || Chunk_Index END) AS sample_chunk
FROM DDR_Calculations
GROUP BY File_Name
HAVING fieldref_no_uuid > 0 OR namedref_empty > 0;

-- Step-Rollen-Kuration (Step-ID-Mapping): field-Referenzen, deren Step-Typ
-- nicht in ScriptStepRoleMap kuratiert ist, landen im references_field-Fallback —
-- Where-used bleibt erhalten, aber ohne differenzierte Rolle (sets/reads/…).
-- Meldet die betroffenen Step-IDs samt Korpus-Namen (ggf. lokalisiert) zur
-- Nachkuration; greift locale-unabhängig auch für neue Steps künftiger
-- FileMaker-Versionen.
CREATE OR REPLACE VIEW v_check_step_roles AS
SELECT COUNT(*) AS unmapped_types,
       COALESCE(SUM(cnt), 0) AS unmapped_refs,
       string_agg('id=' || Step_ID || ' (' || any_name || ') ×' || cnt, ', ' ORDER BY cnt DESC) AS detail
FROM (
    SELECT sfs.Step_ID, any_value(xsr.Step_Name) AS any_name, COUNT(*) AS cnt
    FROM XMLStepReferences xsr
    JOIN (SELECT DISTINCT Step_UUID, Script_UUID, File_Name, Step_ID
          FROM StepsForScripts) sfs
      ON sfs.Step_UUID = xsr.Step_UUID
     AND sfs.Script_UUID = xsr.Script_UUID
     AND sfs.File_Name = xsr.File_Name
    LEFT JOIN ScriptStepRoleMap rm ON rm.Step_ID = sfs.Step_ID
    WHERE xsr.Ref_Type = 'field' AND rm.Step_ID IS NULL
    GROUP BY sfs.Step_ID
);

-- Orphan-QUELLEN + NULL-Ziel-Bestand: Gegenstück zu v_check_orphan_links (das
-- nur Targets prüft). Quellen sind per Konstruktion datei-lokal (der Link
-- entsteht beim Import der Quelldatei) — ein Orphan-Source ist daher AUCH auf
-- einem Teil-Korpus ein Integritätsproblem (Klasse B-C1: Quelle im Link-Block
-- nicht gefiltert, im Catalog-Block schon). NULL-Targets/NULL-Is_Cross_File
-- zwingen jeden direkten ObjectLinks-Konsumenten zu NULL-Safety (NOT-IN-Falle).
CREATE OR REPLACE VIEW v_check_orphan_sources AS
SELECT
    (SELECT COUNT(*) FROM (
        SELECT DISTINCT Source_UUID
        FROM ObjectLinks
        WHERE Source_UUID IS NOT NULL AND Source_UUID <> ''
          AND Source_UUID NOT IN (SELECT Object_UUID FROM ObjectCatalog)
    )) AS orphan_src_n,
    (SELECT COUNT(*) FROM ObjectLinks WHERE Target_UUID IS NULL) AS null_target_links,
    (SELECT COUNT(*) FROM ObjectLinks WHERE Is_Cross_File IS NULL) AS null_crossfile_links;

-- Auflösungsquote je Referenz-Typ nach Phase A (P2). Die Code-Kommentare
-- behaupten ≈97–99 % — bislang unüberwacht; ein Resolver-Drift (z.B. nach einem
-- Join-/Scoping-Umbau) würde sonst still Links verlieren. Nur Typen, deren
-- Ref_UUID in P2 aufgelöst wird: Step-/Layout-Referenzen (außer step/variable —
-- Variablen erhalten erst in P3/P4 synthetische UUIDs) und Calc-Feld-Referenzen
-- (function/customfunction/pluginfunction/variable lösen namensbasiert in P4 auf,
-- tragen hier konstruktionsbedingt kein Ref_UUID).
CREATE OR REPLACE VIEW v_check_resolution AS
SELECT
    'step' AS source,
    Ref_Type AS ref_type,
    COUNT(*) AS total,
    COUNT(*) FILTER (Ref_UUID IS NOT NULL AND Ref_UUID <> '') AS resolved,
    ROUND(100.0 * COUNT(*) FILTER (Ref_UUID IS NOT NULL AND Ref_UUID <> '') / COUNT(*), 1) AS quote_pct
FROM XMLStepReferences
WHERE Ref_Type <> 'variable'
GROUP BY Ref_Type
UNION ALL
SELECT 'layout', Ref_Type, COUNT(*),
       COUNT(*) FILTER (Ref_UUID IS NOT NULL AND Ref_UUID <> ''),
       ROUND(100.0 * COUNT(*) FILTER (Ref_UUID IS NOT NULL AND Ref_UUID <> '') / COUNT(*), 1)
FROM XMLLayoutReferences
GROUP BY Ref_Type
UNION ALL
SELECT 'calc', Ref_Type, COUNT(*),
       COUNT(*) FILTER (Ref_UUID IS NOT NULL AND Ref_UUID <> ''),
       ROUND(100.0 * COUNT(*) FILTER (Ref_UUID IS NOT NULL AND Ref_UUID <> '') / COUNT(*), 1)
FROM XMLCalcReferences
WHERE Ref_Type = 'field'
GROUP BY Ref_Type;

-- MBS-SubName-Auflösung (P2-Proximity + P3.5-Klartext-Recovery). Restbestand
-- 'MBS' (unqualifiziert) sind legitim nur dynamische 1. Argumente
-- (MBS($var; …)). Ein steigender Restbestand zeigt entweder eine neue
-- DDR-Verlust-Konstellation, die der P3.5-Lexer nicht abdeckt, oder einen
-- Drift in der Proximity-Paarung — Schwellwert-Bewertung im Quality-Report.
CREATE OR REPLACE VIEW v_check_mbs_subname_resolution AS
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (Plugin_Function_Name = 'MBS') AS unresolved,
    ROUND(100.0 * COUNT(*) FILTER (Plugin_Function_Name = 'MBS') / NULLIF(COUNT(*), 0), 1) AS unresolved_pct
FROM PluginFunctionUsages
WHERE Plugin_Function_Name = 'MBS' OR Plugin_Function_Name LIKE 'MBS:%';

-- Design-function retype (Phase 1c): FileMaker's SaXML emits the design
-- functions (WindowNames, DatabaseNames, …) as PluginFunctionRef chunks; phase
-- 1c re-types them to FunctionRef against the generated DesignFunctionNames
-- list. FunctionRef chunks whose token is a design-function name are therefore
-- exactly the retyped set (FileMaker never emits them as FunctionRef itself).
-- Matched like phase 1c: case-insensitive, plain name or its &#xHH; char-ref
-- form (no extension needed). Informational — import-report line, no threshold.
CREATE OR REPLACE VIEW v_check_design_function_retype AS
WITH tok AS (
    SELECT File_Name,
           lower(regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1)) AS token
    FROM DDR_Calculations
    WHERE Chunk_Type = 'FunctionRef'
),
names AS (
    SELECT lower(Name) AS token, Canonical_Name FROM DesignFunctionNames
    UNION
    SELECT lower(Name_XML), Canonical_Name FROM DesignFunctionNames WHERE Name_XML IS NOT NULL
),
hit AS (
    SELECT t.File_Name, n.Canonical_Name
    FROM tok t
    JOIN names n USING (token)
)
SELECT
    (SELECT COUNT(*) FROM hit)                        AS chunks,
    (SELECT COUNT(DISTINCT Canonical_Name) FROM hit)  AS distinct_functions,
    (SELECT COUNT(DISTINCT File_Name) FROM hit)       AS files,
    (SELECT string_agg(Canonical_Name, ', ' ORDER BY Canonical_Name)
       FROM (SELECT DISTINCT Canonical_Name FROM hit)) AS names;

-- SaXML-Profile (Schema 1.28.0 / Konverter 2.24.0): Kennzahlen der versions-
-- expliziten Pipeline. files_*: Dateien je Profil (FilesCatalog.SaXML_Profile;
-- unknown = weder saxml22 noch saxml23 → WARN). promoted_anchors/padding_anchors:
-- DisplayCalculations-Anker der saxml23-Dateien, die P1d in die DDR-Tabellen
-- übernommen hat bzw. als FM-26-Polster im Staging belassen hat (informational).
-- Die Übernahme begrenzt auch die Kanten: P2 (_layout_obj_hashes) und P3 (A.3f)
-- lösen DisplayCalculations-Anker nur auf, wenn sie in DDR_ChunkListContexts
-- stehen — Polster liefern keine Referenzen und keine Variablennutzungen.
-- staging_rows_outside_saxml23 / table_view_rows_outside_saxml23: Soll 0 — nur
-- saxml23 speist DDR_DisplayCalcAnchors23 und LayoutTableViewColumns (Dispatch-
-- Drift). cf_calc_rows = cf_functions (Soll): jede echte Custom Function hat
-- genau eine Calc-Zeile, Ordner/Trenner keine. display_anchor_violations:
-- DisplayCalculations-Anker in DDR_Calculations mit Slot ≥ <<ƒ:…>>-Token-Zahl
-- ihres Layoutobjekts mit Text (Textobjekt oder Button-Beschriftung, Schema
-- 1.33.0; Soll 0 — > 0 heißt, P1d lief nicht oder das Muster hat sich geändert).
CREATE OR REPLACE VIEW v_check_saxml_profile AS
WITH owners AS (
    SELECT upper(Object_UUID) AS Owner_UUID, File_Name,
           MAX(len(regexp_extract_all(COALESCE(Text_Content, ''), '(?s)<<ƒ:(.*?)>>', 1))) AS Token_Count
    FROM LayoutObjects
    GROUP BY 1, 2
),
anchors AS (
    SELECT DISTINCT File_Name, Calc_UUID FROM DDR_Calculations
    WHERE Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
),
viol AS (
    SELECT a.Calc_UUID
    FROM anchors a
    JOIN owners o
      ON o.Owner_UUID = upper(regexp_extract(a.Calc_UUID, '_([0-9A-Fa-f-]{36})', 1))
     AND o.File_Name  = a.File_Name
    WHERE TRY_CAST(regexp_extract(a.Calc_UUID, '_DisplayCalculations_([0-9]+)$', 1) AS BIGINT) >= o.Token_Count
),
saxml23_files AS (SELECT File_Name FROM FilesCatalog WHERE SaXML_Profile = 'saxml23')
SELECT
    (SELECT COUNT(*) FROM FilesCatalog WHERE SaXML_Profile = 'saxml22')                          AS files_saxml22,
    (SELECT COUNT(*) FROM FilesCatalog WHERE SaXML_Profile = 'saxml23')                          AS files_saxml23,
    (SELECT COUNT(*) FROM FilesCatalog
      WHERE SaXML_Profile IS NULL OR SaXML_Profile NOT IN ('saxml22', 'saxml23'))               AS files_unknown_profile,
    (SELECT COUNT(*) FROM DDR_DisplayCalcAnchors23 WHERE Chunk_Index = 0)                        AS staged_anchors,
    (SELECT COUNT(*) FROM DDR_DisplayCalcAnchors23 WHERE Chunk_Index = 0 AND Promoted)           AS promoted_anchors,
    (SELECT COUNT(*) FROM DDR_DisplayCalcAnchors23 WHERE Chunk_Index = 0 AND NOT Promoted)       AS padding_anchors,
    (SELECT COUNT(*) FROM DDR_DisplayCalcAnchors23
      WHERE File_Name NOT IN (SELECT File_Name FROM saxml23_files))                              AS staging_rows_outside_saxml23,
    (SELECT COUNT(*) FROM CalcsForCustomFunctions)                                              AS cf_calc_rows,
    (SELECT COUNT(*) FROM CustomFunctionsCatalog
      WHERE COALESCE(Folder_Type, 'False') = 'False' AND NOT COALESCE(Is_Separator, FALSE))      AS cf_functions,
    (SELECT COUNT(*) FROM LayoutTableViewColumns
      WHERE File_Name NOT IN (SELECT File_Name FROM saxml23_files))                              AS table_view_rows_outside_saxml23,
    (SELECT COUNT(*) FROM viol)                                                                 AS display_anchor_violations,
    -- Dormante Felddefinitionen (Schema 1.29.0): Felder mit mindestens einem
    -- deaktivierten Slot (nur saxml23 kann sie tragen) und — Soll 0 — operationale
    -- Kanten, die trotzdem aus einem deaktivierten Slot stammen.
    (SELECT COUNT(*) FROM FieldsForTables
      WHERE AE_Calc_Enabled = FALSE OR Lookup_Enabled = FALSE
         OR Validation_Calc_Enabled = FALSE OR Validation_Message_Calc_Enabled = FALSE)          AS dormant_definitions,
    (SELECT COUNT(*) FROM ObjectLinks ol
      JOIN FieldsForTables f ON f.Field_UUID = ol.Source_UUID AND f.File_Name = ol.Source_File
      WHERE ol.Link_Type = 'operational' AND ol.Source_Type = 'Field'
        AND ((ol.Link_Subrole = 'auto_enter'         AND f.AE_Calc_Enabled = FALSE)
          OR (ol.Link_Subrole = 'validation'         AND f.Validation_Calc_Enabled = FALSE)
          OR (ol.Link_Subrole = 'validation_message' AND f.Validation_Message_Calc_Enabled = FALSE)
          OR (ol.Link_Role IN ('lookup_source', 'lookup_relationship', 'lookup_context')
                                                     AND f.Lookup_Enabled = FALSE)))                 AS dormant_operational_edges;

-- Tabellenansichts-Spalten (Schema 1.28.0, SaXML 2.3.0.0 / FM 26+): Spalten mit
-- Feldreferenz, deren Feld-UUID fehlt (externe TO) oder nicht im Katalog liegt →
-- keine displays_field/table_view_column-Kante. Informational (Teilkorpus legitim).
CREATE OR REPLACE VIEW v_check_table_view_columns AS
SELECT
    COUNT(*)                                                    AS columns_total,
    COUNT(*) FILTER (WHERE Field_UUID IS NULL)                  AS field_uuid_missing,
    COUNT(*) FILTER (WHERE Field_UUID IS NOT NULL
                       AND Field_UUID NOT IN (SELECT Field_UUID FROM FieldsForTables
                                              WHERE Field_UUID IS NOT NULL)) AS field_unresolved,
    COUNT(DISTINCT L_UUID || '|' || File_Name)                  AS layouts
FROM LayoutTableViewColumns;

-- F-1b: Auflösungsquote der Relationship-Prädikat-Felder (left_field/right_field).
-- Seit der strukturellen P1-Gültigkeitsprüfung tragen Prädikat-Felder auf externen
-- TO-Seiten eine leere (→NULL) Feld-UUID; P4 löst sie über (Field_TO_UUID, Field_ID)
-- auf die kanonische Feld-UUID auf. Unaufgelöst bleiben legitim nur die Fälle, deren
-- Zieldatei nicht im (Teil-)Korpus importiert ist — daher INFO, kein Fehler. Zähl-
-- einheit = ein Prädikat-Feld-Slot je (Rel_ID, File_Name, Predicate_Index, Seite).
CREATE OR REPLACE VIEW v_check_relationship_field_resolution AS
WITH slots AS (
    SELECT File_Name, 'left' AS side,
           Left_Field_ID AS field_id, Left_Field_UUID AS field_uuid
    FROM RelationshipCatalog WHERE Left_Field_ID IS NOT NULL
    UNION ALL
    SELECT File_Name, 'right',
           Right_Field_ID, Right_Field_UUID
    FROM RelationshipCatalog WHERE Right_Field_ID IS NOT NULL
)
SELECT
    'relationship' AS source,
    side AS ref_type,
    COUNT(*) AS total,
    COUNT(*) FILTER (
        field_uuid IS NOT NULL
        AND field_uuid IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL)
    ) AS resolved,
    ROUND(100.0 * COUNT(*) FILTER (
        field_uuid IS NOT NULL
        AND field_uuid IN (SELECT Field_UUID FROM FieldsForTables WHERE Field_UUID IS NOT NULL)
    ) / NULLIF(COUNT(*), 0), 1) AS quote_pct
FROM slots
GROUP BY side;

-- Relationship-Identität: Object_UUID einer Relationship ist ihre native FileMaker-UUID
-- (RelationshipCatalog.Rel_UUID). Zähleinheit = Relation (DISTINCT über die Prädikat-
-- Zeilen).
--   fallback_keys    — Relationen ohne <UUID> im Export; Katalogschlüssel fällt auf
--                      'rel_<Rel_ID>_<File_Name>' zurück. Soll 0: alle unterstützten
--                      SaXML-Profile (ab 2.1.0.0) schreiben die UUID.
--   healed           — Intra-File-Zwillinge (gleiche UUID, verschiedene Rel_ID) mit
--                      deterministischer Ersatz-UUID (Zensus DuplicateAbsorptionDetails).
--   multi_file_uuids — native UUIDs, die in mehreren Dateien vorkommen (Klon-/Modul-
--                      Dateien). Nur Info: Identität ist (Object_UUID, File_Name).
CREATE OR REPLACE VIEW v_check_relationship_uuid AS
WITH rel AS (
    SELECT DISTINCT Rel_ID, File_Name, Rel_UUID FROM RelationshipCatalog
)
SELECT
    COUNT(*)                                                    AS relationships,
    COUNT(*) FILTER (WHERE Rel_UUID IS NULL)                    AS fallback_keys,
    (SELECT COUNT(*) FROM DuplicateAbsorptionDetails
     WHERE Catalog = 'RelationshipCatalog' AND Heal_Status = 'healed') AS healed,
    (SELECT COUNT(*) FROM (
        SELECT Rel_UUID FROM rel
        WHERE Rel_UUID IS NOT NULL
        GROUP BY Rel_UUID
        HAVING COUNT(DISTINCT File_Name) > 1))                  AS multi_file_uuids
FROM rel;

-- Änderungs-Metadaten (ObjectChangeMeta / CatalogChangeMeta):
--   stamped_objects   — Objekte mit eigenem Stempel (Info)
--   missing_objects   — ObjectCatalog-Objekte stempeltragender Quellkataloge (inkl.
--                       Ordner) ohne Zeile in ObjectChangeMeta. Soll 0: jede unterstützte
--                       SaXML-Version schreibt die Attribute an jedes <UUID>.
--   cast_failures     — Rohstempel, die nicht als TIMESTAMP lesbar sind (Objekt + Katalog). Soll 0.
--   duplicate_keys    — (Object_UUID, File_Name) mehrfach in ObjectChangeMeta. Soll 0.
--   future_stamps     — Stempel mehr als einen Tag nach dem Import (Uhr des ändernden
--                       Clients falsch; Stempel sind lokale Zeit ohne Zone → Toleranz 1 Tag). Info.
--   catalog_rows      — Zeilen in CatalogChangeMeta (Info).
--   mass_minute_pct   — Anteil der Objekt-Stempel in Minuten mit ≥ 50 Stempeln derselben
--                       Datei (grobe Massenereignis-Quote, Info; Vergleichswert zu bulk_pct).
--   unassigned_bursts — Stempel mit lesbarem Zeitpunkt ohne Burst_ID. Soll 0.
--   bulk_events       — Zeilen in ChangeBulkEvents (Info).
--   solution_events   — davon dateiübergreifend (Scope 'solution', Info).
--   bulk_pct          — Anteil der Objekt-Stempel in einem Massenereignis (Info).
CREATE OR REPLACE VIEW v_check_change_meta AS
WITH meta_sources(Source_Table) AS (
    VALUES ('ScriptCatalog'), ('Layouts'), ('CustomFunctionsCatalog'), ('FieldsForTables'),
           ('BaseTableCatalog'), ('TableOccurrenceCatalog'), ('RelationshipCatalog'),
           ('ValueListCatalog'), ('ExternalDataSourceCatalog'), ('AccountsCatalog'),
           ('PrivilegeSetsCatalog'), ('ExtendedPrivilegesCatalog'), ('CustomMenuCatalog'),
           ('CustomMenuSetCatalog'), ('ThemeCatalog'), ('BaseDirectoryCatalog')
),
minute_buckets AS (
    SELECT File_Name, date_trunc('minute', Modified_At) AS m, COUNT(*) AS n
    FROM ObjectChangeMeta
    WHERE Modified_At IS NOT NULL
    GROUP BY ALL
)
SELECT
    (SELECT COUNT(*) FROM ObjectChangeMeta)                                  AS stamped_objects,
    (SELECT COUNT(*) FROM ObjectCatalog oc
     JOIN meta_sources ms ON ms.Source_Table = oc.Source_Table
     WHERE NOT EXISTS (SELECT 1 FROM ObjectChangeMeta m
                       WHERE m.Object_UUID = oc.Object_UUID
                         AND m.File_Name = oc.File_Name))                    AS missing_objects,
    (SELECT COUNT(*) FROM ObjectChangeMeta
     WHERE Modified_At IS NULL AND Modified_At_Raw IS NOT NULL)
  + (SELECT COUNT(*) FROM CatalogChangeMeta
     WHERE Modified_At IS NULL AND Modified_At_Raw IS NOT NULL)              AS cast_failures,
    (SELECT COUNT(*) FROM (
        SELECT Object_UUID, File_Name FROM ObjectChangeMeta
        GROUP BY ALL HAVING COUNT(*) > 1))                                   AS duplicate_keys,
    (SELECT COUNT(*) FROM ObjectChangeMeta m
     JOIN FilesCatalog f ON f.File_Name = m.File_Name
     WHERE m.Modified_At > f.Import_Timestamp + INTERVAL 1 DAY)              AS future_stamps,
    (SELECT COUNT(*) FROM CatalogChangeMeta)                                 AS catalog_rows,
    (SELECT round(100.0 * COALESCE(SUM(n) FILTER (WHERE n >= 50), 0)
                  / NULLIF(SUM(n), 0), 1) FROM minute_buckets)               AS mass_minute_pct,
    -- Jeder Stempel mit lesbarem Zeitpunkt gehört zu genau einem Burst (Soll 0).
    (SELECT COUNT(*) FROM ObjectChangeMeta
     WHERE Modified_At IS NOT NULL AND Burst_ID IS NULL)                     AS unassigned_bursts,
    (SELECT COUNT(*) FROM ChangeBulkEvents)                                  AS bulk_events,
    (SELECT COUNT(*) FROM ChangeBulkEvents WHERE Scope = 'solution')         AS solution_events,
    (SELECT round(100.0 * COUNT(Bulk_Event_ID) / NULLIF(COUNT(*), 0), 1)
     FROM ObjectChangeMeta)                                                  AS bulk_pct;

-- Dateien ohne DDR-Info — der Export lief ohne „Details für Analysewerkzeuge
-- einschließen" (Root-Attribut Has_DDR_INFO="False"). Der Import ist trotzdem
-- vollständig (Objekte, Formeltexte), aber der DDR-Chunk-Strom ist die EINZIGE
-- Quelle für Formel-Referenzen (Felder, Funktionen, Custom Functions,
-- Plugin-Aufrufe) — für diese Dateien existieren keine. > 0 ⇒ Warn-Finding:
-- Re-Export mit der Option. Gegenstück zur Header-Probe der Import-Seite
-- (rest-api utils/xml-head.js) und zum Analysis-Test plugin-availability.
CREATE OR REPLACE VIEW v_check_ddr_missing AS
SELECT
    COUNT(*) AS file_n,
    string_agg(File_Name, ', ' ORDER BY File_Name) AS files
FROM FilesCatalog
WHERE NOT COALESCE(Has_DDR_INFO, FALSE);

-- „Function Missing"-Platzhalter — FileMaker schreibt bei einer beim EXPORT nicht
-- geladenen Plugin-Funktion <Chunk type="VariableReference">Function Missing</Chunk>.
-- P3 verwirft diese Chunks aus der Variablen-Extraktion (kein Scheinvariablen-Objekt),
-- die Roh-Chunks bleiben aber in DDR_Calculations. Diese View zählt sie, damit die
-- eigentliche Information (ein Plugin fehlte im Export → Referenzen unauflösbar) als
-- Warn-Finding sichtbar wird statt still unterzugehen. > 0 ⇒ Export unvollständig
-- (Plugin auf dem exportierenden Client nicht installiert/aktiviert).
CREATE OR REPLACE VIEW v_check_function_missing AS
SELECT
    COUNT(*) AS chunk_n,
    string_agg(DISTINCT File_Name, ', ') AS files
FROM DDR_Calculations
WHERE Chunk_Type = 'VariableReference'
  AND regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1) = 'Function Missing';

-- %X:-Fehlchunks in DisplayCalculations (Schema 1.27.0) — FileMaker chunked
-- typisierte Layoutformeln mit einzelner Feldreferenz (<<ƒ:%N:Zahl>>) als
-- <Chunk type="VariableReference">%N:Zahl</Chunk>. P3 verwirft sie aus der
-- Variablen-Extraktion (keine Phantom-Variablen), P2 A.5.1b rettet die
-- Feldreferenz gegen die Kontext-TO. Diese View zählt die kompensierten
-- Chunks, damit der Quell-Defekt sichtbar bleibt. > 0 ⇒ DDR-Defekt kompensiert
-- (Info, kein Handlungsbedarf — Kanten sind gerettet, sofern auflösbar).
CREATE OR REPLACE VIEW v_check_display_prefix_chunks AS
SELECT
    COUNT(*) AS chunk_n,
    string_agg(DISTINCT File_Name, ', ') AS files
FROM DDR_Calculations
WHERE Chunk_Type = 'VariableReference'
  AND Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\'
  AND regexp_matches(regexp_extract(Chunk_Content, '>([^<]+)</Chunk>', 1), '^%[A-Z]+:');

-- Leere DisplayCalculations-ChunkLists (Schema 1.27.0) — bei %X:-typisierten
-- Layoutformeln mit Ausdruck schreibt FileMaker eine leere ChunkList
-- (Chunk_Count = 0): Formel + Referenzen fehlen im DDR-Teil komplett.
-- P4 b_disp legt eine Fallback-Instanz an (Formula_Text aus Text_Content),
-- P2 A.5.1c rettet die Feldkanten der Kontext-TO; Funktionsreferenzen bleiben
-- verloren (lokalisierte Namen, Ausbaustufe). > 0 ⇒ Import-Qualitäts-Finding:
-- strukturell kompensiert, aber Funktions-Where-used dieser Formeln unvollständig.
CREATE OR REPLACE VIEW v_check_display_empty_chunklist AS
SELECT
    COUNT(*) AS anchor_n,
    string_agg(DISTINCT File_Name, ', ') AS files
FROM DDR_ChunkListContexts
WHERE Chunk_Count = 0
  AND Calc_UUID LIKE '%\_DisplayCalculations\_%' ESCAPE '\';

-- Textpfade der Layoutobjekte (Schema 1.33.0). Text_Content,
-- Label_Calculation_Text und Title_Calculation_Text lesen je @kind genau einen
-- XML-Pfad (P1-Makros fm_layout_object_text/_label_calc/_title_calc). Die View
-- prüft die Annahme gegen das Roh-XML, ohne XML-Parser (P6-Abfragen laufen ohne
-- webbed): verglichen wird nur der objekteigene Kopf des Object_XML — alles vor
-- dem ersten Kind-<LayoutObject>; Beschriftung und Titel stehen dort vor den
-- Kindern, Container-Inhalte bleiben so außen vor.
--   text_path_mismatch  — Kopf trägt einen nicht leeren Text-/Beschriftungstext
--                         (<Text><StyledText><Data>), Text_Content ist aber NULL:
--                         ein Typ, für den das Makro keinen Pfad kennt. Soll 0.
--   label_text_and_calc — Button/Popover-Button mit Beschriftungstext UND
--                         Beschriftungsformel (schließen sich aus). Soll 0.
--   title_path_mismatch — Kopf trägt eine nicht leere Titelformel (<Title> bzw.
--                         <TabPanel><Calculation>), Title_Calculation_Text ist
--                         aber NULL. Soll 0.
-- > 0 ⇒ WARN im Import-Report: Pfad-Dispatch der Makros prüfen.
CREATE OR REPLACE VIEW v_check_layout_text_paths AS
WITH lo AS (
    SELECT Object_Kind, Object_Type, File_Name, Text_Content, Label_Calculation_Text,
           Title_Calculation_Text,
           regexp_replace(Object_XML, '(?s)^(<LayoutObject.*?)<LayoutObject\b.*$', '\1') AS head
    FROM LayoutObjects
    WHERE Object_XML LIKE '%<StyledText>%'
       OR Object_XML LIKE '%<Title>%'
       OR Object_XML LIKE '%<TabPanel%'
),
flags AS (
    SELECT *,
        regexp_matches(head, '(?s)<Text>\s*(?:<Options>[^<]*</Options>\s*)?<StyledText>\s*<Data>\s*(?:<!\[CDATA\[)?\s*[^\]<\s]') AS has_text,
        regexp_matches(head, '(?s)(?:<Title>|<TabPanel\b[^>]*>\s*(?:<Options>[^<]*</Options>\s*)?<Calculation>)\s*(?:<DDRREF[^>]*>[^<]*</DDRREF>\s*)?<Text>\s*(?:<!\[CDATA\[)?\s*[^\]<\s]') AS has_title
    FROM lo
)
SELECT
    (SELECT COUNT(*) FROM flags WHERE has_text AND Text_Content IS NULL)            AS text_path_mismatch,
    (SELECT COUNT(*) FROM LayoutObjects
      WHERE Object_Kind IN (10, 14)
        AND NULLIF(Text_Content, '') IS NOT NULL
        AND NULLIF(Label_Calculation_Text, '') IS NOT NULL)                         AS label_text_and_calc,
    (SELECT COUNT(*) FROM flags WHERE has_title AND Title_Calculation_Text IS NULL) AS title_path_mismatch,
    (SELECT string_agg(DISTINCT Object_Kind || ':' || Object_Type, ', ')
       FROM flags
      WHERE (has_text AND Text_Content IS NULL)
         OR (has_title AND Title_Calculation_Text IS NULL))                         AS mismatch_kinds;

-- Getippte Merge-Felder in Button-Beschriftungen über externe TOs (Konverter
-- 2.34.0). P2 schreibt dafür offene label_text-Zeilen (Ref_UUID NULL), P4 Phase A
-- löst sie über die Heimatdatei der Basistabelle auf oder löscht sie (Feld fehlt
-- dort). Was offen bleibt, hat keine Heimatdatei im Import.
--   unverified        — offene Zeilen (Info): Anker auf eine nicht importierte
--                       oder mehrdeutige Datei; keine Kante, kein Finding.
--   open_on_local_to  — offene Zeile, deren TO nicht extern ist. Soll 0 (P2 löst
--                       lokale TOs selbst auf oder schreibt keine Zeile).
--   open_with_k1_home — offene Zeile, obwohl die BT_UUID der externen TO genau
--                       eine importierte Datei trifft: Die P4-Auflösung hätte sie
--                       aufgelöst oder gelöscht. Soll 0.
CREATE OR REPLACE VIEW v_check_label_anchor_external AS
WITH open_rows AS (
    SELECT x.File_Name, x.TO_Ref_ID, t.TO_Type, t.BT_UUID
    FROM XMLLayoutReferences x
    LEFT JOIN TableOccurrenceCatalog t
           ON t.File_Name = x.File_Name
          AND t.TO_ID = x.TO_Ref_ID
    WHERE x.Ref_Source = 'label_text' AND x.Ref_Type = 'field' AND x.Ref_UUID IS NULL
),
bt_files AS (
    SELECT Table_UUID, count(DISTINCT File_Name) AS n
    FROM FieldsForTables
    WHERE Table_UUID IS NOT NULL
    GROUP BY ALL
)
SELECT
    (SELECT COUNT(*) FROM open_rows)                                                  AS unverified,
    (SELECT COUNT(*) FROM open_rows WHERE TO_Type IS DISTINCT FROM 'External')         AS open_on_local_to,
    (SELECT COUNT(*) FROM open_rows o JOIN bt_files b ON b.Table_UUID = o.BT_UUID
      WHERE o.TO_Type = 'External' AND b.n = 1)                                       AS open_with_k1_home;

-- unbekannte LayoutObject-Typen. `Object_Type` ist der lokalisierte
-- /LayoutObject/@type-String; die P4-Locale-Normalisierung bildet die bekannten dt.
-- Namen auf ihr englisches Kanon ab. Diese View listet jeden Object_Type, der NACH der
-- Normalisierung NICHT im kanonischen englischen Typ-Set liegt — also (a) ein neuer
-- Locale-Name eines künftigen Exports (Mapping in convert_xml_04_catalog.sql erweitern)
-- oder (b) ein echter neuer FileMaker-Typ (Kanon-Set hier ergänzen). > 0 ⇒ typ-gefilterte
-- Analysen/Dashboards zählen diese Objekte falsch. Das Kanon-Set ist die autoritative
-- Liste der gültigen englischen Typnamen (inkl. der real existierenden „Rounded Rectangle"/
-- „Concealed Edit Box", die in der CLAUDE.md-22er-Liste fehlen).
CREATE OR REPLACE VIEW v_check_unknown_object_types AS
SELECT
    Object_Type,
    COUNT(*)                              AS n,
    string_agg(DISTINCT File_Name, ', ')  AS files
FROM LayoutObjects
WHERE Object_Type IS NOT NULL
  AND Object_Type NOT IN (
      'Text', 'Edit Box', 'Grouped Button', 'Rectangle', 'Line', 'Graphic',
      'Group', 'Checkbox Set', 'Button', 'Container', 'Portal', 'Drop-down List',
      'Panel', 'Radio Button Set', 'Button Bar', 'PopoverPanel', 'Popover Button',
      'Pop-up Menu', 'Tab Control', 'Web Viewer', 'Chart', 'Oval', 'Rounded Rectangle',
      'Concealed Edit Box', 'Slide Control', 'Drop-down Calendar'
  )
GROUP BY Object_Type
ORDER BY n DESC;

-- Calculation-Objekttyp (Schema 1.22.0) — drei Wächter in einer Zeile:
--   unresolved_n : DDR-Anker ohne ObjectCatalog-Owner (Soll 0; Regression der
--                  Anker-Auflösung, vormals v_calc_anchors/'unresolved')
--   dup_uuid_n   : Calculation_UUID-Kollisionen (Soll 0; Identität
--                  Owner × Rolle × Index ist dann nicht mehr eindeutig)
--   uncovered_anchor_n : DDR-Anker (verankerte Calc_UUIDs) OHNE
--                  CalculationsCatalog-Zeile (Soll 0; Abdeckungs-Regression —
--                  „Vollständigkeit wird messbar")
CREATE OR REPLACE VIEW v_check_calculations AS
SELECT
    (SELECT COUNT(*) FROM CalculationsCatalog WHERE Owner_Type = 'unresolved') AS unresolved_n,
    (SELECT COUNT(*) FROM (
        SELECT Calculation_UUID FROM CalculationsCatalog
        GROUP BY Calculation_UUID HAVING COUNT(*) > 1
    )) AS dup_uuid_n,
    (SELECT COUNT(*) FROM (
        SELECT DISTINCT Calc_UUID, File_Name
        FROM DDR_Calculations
        WHERE regexp_extract(Calc_UUID, '_([0-9A-Fa-f-]{36})', 1) <> ''
    ) d
    WHERE NOT EXISTS (
        SELECT 1 FROM CalculationsCatalog c
        WHERE c.DDR_Calc_UUID = d.Calc_UUID AND c.File_Name = d.File_Name
    )) AS uncovered_anchor_n;

-- Rollen-Vokabular-Wächter: Calc_Role außerhalb des normalisierten Vokabulars
-- = neuer/unbekannter DDR-Suffix (lower(raw)-Fallback der P4-Klassifi-
-- kation). > 0 ⇒ Vokabular in convert_xml_04_catalog.sql nachkuratieren
-- (analog v_check_unknown_object_types; kein Fehler, ein Kurations-Signal).
CREATE OR REPLACE VIEW v_check_calc_roles AS
SELECT
    Calc_Role,
    COUNT(*)                              AS n,
    string_agg(DISTINCT File_Name, ', ')  AS files
FROM CalculationsCatalog
-- Unaufgelöste Anker haben keinen Owner-Typ-Kontext für die Klassifikation und
-- sind bereits über unresolved_n (v_check_calculations) gezählt.
WHERE Owner_Type <> 'unresolved'
  AND Calc_Role NOT IN (
    'field_calculation', 'auto_enter', 'validation', 'validation_message',
    'container_path', 'display_names',
    'custom_function',
    'step_parameter', 'step_xslt',
    'record_access',
    'hide', 'field_entry', 'tooltip', 'placeholder', 'conditional_format', 'portal_filter',
    'web_viewer_url', 'button_label', 'button_action', 'panel_title', 'popover_title',
    'active_segment',
    'display_calculation',
    'chart_series', 'chart_title', 'chart_xaxis_title', 'chart_yaxis_title',
    'script_trigger_parameter',
    'menu_install', 'menu_title', 'menu_item_install', 'menu_item_name',
    'menu_item_parameter'
)
GROUP BY Calc_Role
ORDER BY n DESC;

-- Conditional-Formatting-Regeln (LayoutObjectConditions, Schema 1.25.0) —
-- table-only Kennzahlen, Bewertung macht die Shell:
--   membercount_mismatch_n — Objekte, deren extrahierte Regelzahl vom
--     Formatting/@membercount des eigenen Blocks abweicht. Korpus-verifiziert
--     0 (8.745/8.745); > 0 ⇒ die depth-verankerte Extraktion zählt Kind-Regeln
--     mit (Nesting-Regression) oder verliert eigene Regeln. WARN.
--   calc_without_rule_n — CalculationsCatalog-Instanzen der Rolle
--     conditional_format ohne zugehörige Regel-Zeile (FK-Rückrichtung).
--     Soll 0; > 0 ⇒ die Instanz hängt am falschen Owner (Owner-Auflösung,
--     s. v_check_calc_owner_hash) oder die Regel-Extraktion verlor Regeln. WARN.
--   hash_without_fk_n — Regeln mit DDRREF-Hash, aber ohne aufgelösten
--     Calculation_UUID-FK, OHNE die leeren ChunkLists. Soll 0 — INFO, kein Gate.
--   empty_chunklist_n — Regeln mit Hash md5('') ohne FK: FileMaker schreibt für
--     die leere ChunkList (typisch Wertregeln) keine Chunks, also gibt es keine
--     DDR-Instanz und keinen FK. Erwartbar > 0, nur Statistik.
--   fk_hash_mismatch_n — Regeln, deren FK auf eine Instanz mit ANDEREM Hash
--     zeigt (Regel liest eine fremde Formel). Soll 0; WARN.
CREATE OR REPLACE VIEW v_check_cf_rules AS
SELECT
    (SELECT COUNT(*) FROM (
        SELECT File_Name, Object_UUID
        FROM LayoutObjectConditions
        GROUP BY File_Name, Object_UUID
        HAVING COUNT(*) <> MAX(Formatting_Membercount)
    ))                                                        AS membercount_mismatch_n,
    (SELECT COUNT(*)
     FROM CalculationsCatalog cc
     WHERE cc.Calc_Role = 'conditional_format'
       AND NOT EXISTS (SELECT 1 FROM LayoutObjectConditions c
                        WHERE c.Calculation_UUID = cc.Calculation_UUID))
                                                              AS calc_without_rule_n,
    (SELECT COUNT(*) FROM LayoutObjectConditions c
     WHERE c.Calc_Hash IS NOT NULL AND c.Calculation_UUID IS NULL
       AND c.Calc_Hash <> upper(md5('')))
                                                              AS hash_without_fk_n,
    (SELECT COUNT(*) FROM LayoutObjectConditions c
     WHERE c.Calc_Hash = upper(md5('')) AND c.Calculation_UUID IS NULL)
                                                              AS empty_chunklist_n,
    (SELECT COUNT(*) FROM LayoutObjectConditions c
     JOIN CalculationsCatalog cc ON cc.Calculation_UUID = c.Calculation_UUID
     WHERE c.Calc_Hash IS DISTINCT FROM cc.Formula_Hash)
                                                              AS fk_hash_mismatch_n,
    (SELECT COUNT(*) FROM LayoutObjectConditions)             AS rules_n;

-- Owner-Attribution der DDR-verankerten Berechnungs-Instanzen: der Formel-Hash
-- einer LayoutObject-/ScriptStep-Instanz muss im EIGENEN XML des Owners stehen
-- (DDRREF hash="<H>"). Ein Treffer heißt: die Instanz hängt am falschen Objekt —
-- typisch nach einer UUID-Heilung, wenn der Anker dem Survivor statt dem
-- Zwilling zugeordnet wurde (P4 heal_anchor_owner). Gilt für alle Rollen,
-- nicht nur CF. Baseline ohne Heilung korpusweit 0; Soll 0, WARN.
-- Eine Zeile je (Owner_Type, Calc_Role); leer = sauber.
CREATE OR REPLACE VIEW v_check_calc_owner_hash AS
SELECT cc.Owner_Type, cc.Calc_Role, COUNT(*) AS n,
       string_agg(DISTINCT cc.File_Name, ', ') AS files
FROM CalculationsCatalog cc
LEFT JOIN LayoutObjects lo
       ON lo.Object_UUID = cc.Owner_UUID AND lo.File_Name = cc.File_Name
LEFT JOIN StepsForScripts s
       ON s.Step_UUID = cc.Owner_UUID AND s.File_Name = cc.File_Name
WHERE cc.DDR_Calc_UUID IS NOT NULL
  AND cc.Formula_Hash IS NOT NULL
  AND cc.Owner_Type IN ('LayoutObject', 'ScriptStep')
  AND strpos(COALESCE(CASE cc.Owner_Type WHEN 'LayoutObject' THEN lo.Object_XML
                                         ELSE s.Step_XML END, ''),
             'hash="' || cc.Formula_Hash || '"') = 0
GROUP BY cc.Owner_Type, cc.Calc_Role
ORDER BY n DESC;

-- unbekannte LayoutPart-Typen (nach der P4-Locale-Normalisierung). Analog
-- v_check_unknown_object_types: jeder Part_Type außerhalb des kanonischen englischen
-- Part-Sets ⇒ neuer Locale-Name (DE→EN-Mapping in convert_xml_04_catalog.sql erweitern)
-- oder echter neuer Part-Typ (Kanon-Set hier ergänzen). Ein verpasster Sub-summary-Locale-
-- Name kostet zudem breaks_on_field-Links (Filter `LIKE '%Sub-summary%'`).
CREATE OR REPLACE VIEW v_check_unknown_part_types AS
SELECT
    Part_Type,
    COUNT(*)                              AS n,
    string_agg(DISTINCT File_Name, ', ')  AS files
FROM LayoutParts
WHERE Part_Type IS NOT NULL
  AND Part_Type NOT IN (
      'Title Header', 'Header', 'Leading Grand Summary', 'Leading Sub-summary',
      'Body', 'Trailing Sub-summary', 'Trailing Grand Summary', 'Footer',
      'Title Footer', 'Top Navigation', 'Bottom Navigation'
  )
GROUP BY Part_Type
ORDER BY n DESC;

-- LayoutObjects ohne zugeordneten Bereich (Schema 1.39.0). P4 setzt Part_Seq für
-- Root-Objekte aus der Oberkante im Bereichsband, für Kinder über die Eltern-Kette.
-- Erwartet 0; Treffer = Root-Objekt oberhalb des ersten / unterhalb des letzten
-- Bereichs oder ein Kind mit abgerissener Parent_Object_ID-Kette. Kein Datenfehler
-- des Exports, aber die Sektionsansicht kann das Objekt keinem Bereich zuordnen.
CREATE OR REPLACE VIEW v_check_layoutobjects_without_part AS
SELECT
    lo.File_Name,
    lo.Layout_ID,
    COUNT(*)                                         AS n,
    COUNT(*) FILTER (WHERE lo.Nesting_Level = 0)     AS n_root
FROM LayoutObjects lo
WHERE lo.Part_Seq IS NULL
GROUP BY lo.File_Name, lo.Layout_ID
ORDER BY n DESC;

-- Numerik-Sentinel-Drift (Wächter zur Sentinel-Normalisierung in P1):
-- Validation_MaxChars wird bei der Extraktion per NULLIF(…, 4294967295) auf NULL
-- normalisiert („unbegrenzt" = kein Limit). Der Wächter zählt, was danach noch
-- oberhalb einer bewusst groben Plausibilitätsschwelle (10⁹ Zeichen) liegt —
-- jeder Treffer ist per Konstruktion ein NICHT erkannter Sentinel (FileMaker hat
-- den Wert geändert) oder eine neue Serialisierungsform. Erkennung statt
-- Bereichsregel: der Wächter verändert nie Daten, die Shell reportet WARN
-- (kein Gate). Schwelle bewusst nicht „schlau": kein reales Zeichenlimit liegt
-- darüber, jeder Sentinel-Kandidat deutlich darüber.
CREATE OR REPLACE VIEW v_check_numeric_sentinels AS
SELECT
    COUNT(*)                                                   AS sentinel_n,
    string_agg(File_Name || '/' || Table_Name || '::' || Field_Name
               || '=' || Validation_MaxChars, ', ')            AS sample
FROM FieldsForTables
WHERE Validation_MaxChars > 1000000000;

-- Referenzlisten-Wächter (Konverter 2.43.0): aggregierte ID-/Namenslisten aus
-- LEFT JOIN LATERAL + list(). Vertrag: [] = keine Referenz (nie NULL, nie ein
-- NULL-Element), IDs und Namen gleich lang. Ein nacktes list() über den LEFT JOIN
-- sammelt die NULL-Zeile eines referenzlosen Objekts als [NULL] ein — genau das
-- fängt diese View. Soll: violation_n = 0 je Regel.
CREATE OR REPLACE VIEW v_check_reference_lists AS
SELECT 'ep_privilegeset_list' AS rule, COUNT(*) AS violation_n
FROM ExtendedPrivilegesCatalog
WHERE PrivilegeSet_IDs IS NULL OR PrivilegeSet_Names IS NULL
   OR len(list_filter(PrivilegeSet_IDs, lambda x: x IS NULL)) > 0
   OR len(PrivilegeSet_IDs) <> len(PrivilegeSet_Names)
UNION ALL
SELECT 'menuset_member_list', COUNT(*)
FROM CustomMenuSetCatalog
WHERE Member_Menu_IDs IS NULL OR Member_Menu_Names IS NULL
   OR len(list_filter(Member_Menu_IDs, lambda x: x IS NULL)) > 0
   OR len(Member_Menu_IDs) <> len(Member_Menu_Names);

-- Owner-exakte Layout-Script-Referenzen (Converter 2.15.0, P2-Ancestor-Guard) —
-- zwei table-only Kennzahlen für die beiden Regressionsrichtungen des Guards,
-- Bewertung macht die Shell:
--   trigger_deficit_n — (Objekt, Datei, Script)-Gruppen, deren eigene
--     ScriptTriggers-Zeilen (t, P1 owner-exakt) die XMLLayoutReferences-
--     Script-Zeilen (r) übersteigen. Invariante r ≥ t; < ⇒ der Guard
--     verliert EIGENE Trigger-Refs (Über-Filterung) — P4 Block 21b bliebe
--     dann still hinter 21a zurück. Soll 0. WARN.
--   container_action_n — überschüssige Script-Zeilen (r − t) auf reinen
--     Container-Typen (können keine eigene Button-Action tragen). > 0 ⇒
--     Kinder-Refs hoisten wieder in den Container (Descendant-Regression,
--     Phantom-'button_action'-Kanten). Soll 0. WARN.
CREATE OR REPLACE VIEW v_check_layout_script_refs AS
WITH r AS (
    SELECT Object_UUID, File_Name, Ref_UUID, COUNT(*) AS r
    FROM XMLLayoutReferences
    WHERE Ref_Type = 'script' AND Ref_UUID IS NOT NULL
    GROUP BY ALL
), t AS (
    SELECT Owner_UUID, File_Name, Script_UUID, COUNT(*) AS t
    FROM ScriptTriggers
    WHERE Owner_Type = 'LayoutObject' AND Script_UUID IS NOT NULL
    GROUP BY ALL
)
SELECT
    (SELECT COUNT(*)
     FROM t
     LEFT JOIN r ON r.Object_UUID = t.Owner_UUID
                AND r.File_Name  = t.File_Name
                AND r.Ref_UUID   = t.Script_UUID
     WHERE COALESCE(r.r, 0) < t.t)                             AS trigger_deficit_n,
    (SELECT COALESCE(SUM(r.r - COALESCE(t.t, 0)), 0)
     FROM r
     LEFT JOIN t ON t.Owner_UUID = r.Object_UUID
                AND t.File_Name  = r.File_Name
                AND t.Script_UUID = r.Ref_UUID
     WHERE r.r > COALESCE(t.t, 0)
       -- EXISTS statt Join: geheilte UUID-Zwillinge dürfen nicht multiplizieren
       AND EXISTS (SELECT 1 FROM LayoutObjects lo
                    WHERE lo.Object_UUID = r.Object_UUID
                      AND lo.File_Name   = r.File_Name
                      AND lo.Object_Type IN ('Portal', 'Tab Control', 'Panel',
                                             'Group', 'PopoverPanel', 'Button Bar',
                                             'Slide Control')))
                                                               AS container_action_n;

-- Transaktions-Parameterfelder (Report, KEIN Gate): OnWindowTransaction-Trigger
-- mit gesetztem scriptParameterFieldName und die Zahl ihrer file-lokalen
-- Namens-Kandidaten (Kanten reads_field·transaction_parameter_field, Block 18c
-- in P4). candidates_n = 0 heißt "verwaister Name" — z.B. nach einer Feld-
-- Umbenennung ein realer, legitimer Lösungszustand (der Name ist spät gebunden,
-- FileMaker validiert ihn nicht). Deshalb bewusst reine Info-View ohne
-- FAIL-Bewertung in der Shell.
CREATE OR REPLACE VIEW v_report_trigger_parameter_fields AS
SELECT
    st.File_Name,
    st.Owner_Type,
    st.Owner_UUID,
    st.Trigger_ID,
    st.Trigger_Action,
    st.Trigger_ScriptParameter_FieldName AS Parameter_Field_Name,
    (SELECT COUNT(*) FROM FieldsForTables ft
      WHERE ft.Field_Name = st.Trigger_ScriptParameter_FieldName
        AND ft.File_Name  = st.File_Name)  AS candidates_n
FROM ScriptTriggers st
WHERE NULLIF(st.Trigger_ScriptParameter_FieldName, '') IS NOT NULL;

-- Trigger-Spiegel-Symmetrie (Converter 2.17.0, P4 Block 21a auf allen drei
-- Owner-Ebenen): je Owner-Ebene muss gelten
--     #Event-Spiegel (triggers_script, Subrole ≠ button_action)
--   = #ScriptTriggers-Zeilen mit Script
--   = #granulare trigger_script-Kanten der Trigger-Knoten dieser Ebene.
-- Die Spiegel sind seit 2.17.0 die einzige zählende Where-used-Wahrheit
-- (LinkRoleRegistry: trigger_script Counts_For_Where_Used=FALSE) — ein Bruch
-- der 1:1-Beziehung heißt Doppelzählung oder Where-used-Lücke. owner_edge_n
-- (trigger_owner, Basis: ALLE Trigger der Ebene inkl. script-loser) ist
-- Info-Spalte: eine Lücke dort ist die bekannte PopoverPanel-Parser-Klasse,
-- kein Spiegel-Defekt. Bewertung macht die Shell (WARN, kein hartes Gate —
-- Alt-Kataloge vor 2.17.0 laufen absichtlich weiter).
CREATE OR REPLACE VIEW v_check_trigger_mirror_symmetry AS
WITH lvl AS (
    SELECT Owner_Type,
           COUNT(*) AS triggers_total_n,
           COUNT(*) FILTER (WHERE Script_UUID IS NOT NULL) AS triggers_with_script_n
    FROM ScriptTriggers
    GROUP BY Owner_Type
)
SELECT
    l.Owner_Type                                              AS owner_type,
    l.triggers_total_n,
    l.triggers_with_script_n,
    (SELECT COUNT(*) FROM ObjectLinks ol
      WHERE ol.Link_Role = 'triggers_script'
        AND ol.Link_Subrole IS NOT NULL
        AND ol.Link_Subrole <> 'button_action'
        AND ol.Source_Type = l.Owner_Type)                    AS mirror_n,
    (SELECT COUNT(*) FROM ObjectLinks ol
      JOIN ScriptTriggers st
        ON ol.Source_UUID = 'trig_' || st.Trigger_ID::VARCHAR
                            || '_' || st.Owner_UUID || '_' || st.File_Name
      WHERE ol.Link_Role = 'trigger_script'
        AND ol.Target_UUID IS NOT NULL
        AND st.Owner_Type = l.Owner_Type)                     AS granular_n,
    (SELECT COUNT(*) FROM ObjectLinks ol
      WHERE ol.Link_Role = 'trigger_owner'
        AND ol.Target_Type = l.Owner_Type)                    AS owner_edge_n
FROM lvl l;
