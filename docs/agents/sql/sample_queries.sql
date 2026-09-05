/*
-- DuckDB SQL queries to parse FileMaker XML Catalog

-- SQL Table must be loaded with test_catalog.sql query before running these queries

-- Version 0.1
-- Date: 2026-01-10
*/




-- ============================================================================
-- SCRIPTS
-- ============================================================================


-- List all Scripts
SELECT
    Script_ID,
    Script_Name,
    CASE
        WHEN Folder_Type = 'True' THEN 'Folder'
        WHEN Is_Separator THEN 'Separator'
        ELSE 'Script'
    END AS Type,
    CASE WHEN Is_Hidden THEN 'Yes' ELSE 'No' END AS Hidden,
    CASE WHEN Full_Access THEN 'Yes' ELSE 'No' END AS Full_Access,
    Last_Modified_By,
    Last_Modified_At
FROM ScriptCatalog
;


-- List only executable Scripts (no folders/separators)
SELECT
    Script_ID,
    Script_Name,
    --CASE WHEN Is_Hidden THEN 'Yes' ELSE 'No' END AS Hidden,
    --CASE WHEN Full_Access THEN 'Yes' ELSE 'No' END AS Full_Access,
    Last_Modified_By,
    Last_Modified_At
FROM ScriptCatalog
WHERE (Folder_Type IS NULL OR Folder_Type = 'False')
  AND NOT Is_Separator
ORDER BY Script_Name;


-- List all Scripts in Pretty Format
SELECT
    Script_ID,
    CASE
        WHEN Folder_Type = 'True' THEN '📁 ' || Script_Name
        WHEN Folder_Type = 'Marker' OR Is_Separator THEN '----------'
        ELSE '  ' || Script_Name
    END AS Script_Name
FROM ScriptCatalog
;



-- ============================================================================
-- SCRIPT DETAILS
-- ============================================================================

-- Show complete Script with all Steps for a specific Script ID
SET VARIABLE script_id = 1;  -- Change this to the desired Script ID

SELECT
    s.Script_ID,
    s.Script_Name,
    '---' AS Separator,
    st.Step_Index,
    CASE WHEN st.Is_Enabled THEN '✓' ELSE '✗' END AS Enabled,
    st.Step_Name,
    st.Parameter_Type,
    st.Variable_Name,
    st.Calculation_Text,
    st.Boolean_Type,
    st.Boolean_Value,
    st.Parameters_XML
FROM ScriptCatalog s
LEFT JOIN StepsForScripts st ON s.Script_ID = st.Script_ID
WHERE s.Script_ID = getvariable('script_id')
  AND (s.Folder_Type IS NULL OR s.Folder_Type = 'False')
  AND NOT s.Is_Separator
ORDER BY st.Step_Index;


-- Show Script Steps in compact format
SET VARIABLE script_id = 1;  -- Change this to the desired Script ID

SELECT
    Step_Index,
    CASE WHEN Is_Enabled THEN '' ELSE '# ' END || Step_Name AS Script_Step,
    CASE
        WHEN Parameter_Type = 'Variable' THEN COALESCE(Variable_Name, '?')
        WHEN Calculation_Text IS NOT NULL THEN Calculation_Text
        WHEN Boolean_Type IS NOT NULL THEN Boolean_Type || ' = ' || Boolean_Value
        ELSE Parameter_Type
    END AS Parameter_Info,
    Parameters_XML
FROM StepsForScripts
WHERE Script_ID = getvariable('script_id')
ORDER BY Step_Index;



-- ============================================================================
-- BASE TABLES
-- ============================================================================

-- List all Base Tables
SELECT
    BT_ID,
    BT_Name,
    BT_UUID
FROM BaseTableCatalog
ORDER BY BT_Name;


-- Count Fields per Base Table
SELECT
    b.BT_ID,
    b.BT_Name,
    COUNT(f.Field_ID) AS Field_Count
FROM BaseTableCatalog b
LEFT JOIN FieldsForTables f ON b.BT_ID = f.Table_ID
GROUP BY b.BT_ID, b.BT_Name
ORDER BY Field_Count DESC, b.BT_Name;



-- ============================================================================
-- FIELDS
-- ============================================================================

-- Show all Fields for a specific Base Table
SET VARIABLE table_id = 131;  -- Change this to the desired Table ID

SELECT
    Table_ID,
    Table_Name,
    '---' AS Separator,
    Field_ID,
    Field_Name,
    Field_Type,
    Data_Type,
    CASE WHEN Is_Global THEN 'Yes' ELSE 'No' END AS Global,
    Max_Repetitions,
    Field_Comment
FROM FieldsForTables
WHERE Table_ID = getvariable('table_id')
ORDER BY Field_ID;


-- Show Fields in compact format
SET VARIABLE table_id = 131;  -- Change this to the desired Table ID

SELECT
    Field_ID,
    Field_Name,
    Field_Type ||
    CASE
        WHEN Data_Type IS NOT NULL THEN ' (' || Data_Type || ')'
        ELSE ''
    END AS Type_Info,
    CASE
        WHEN Is_Global THEN 'Global'
        WHEN Max_Repetitions > 1 THEN 'Repeating (' || Max_Repetitions || ')'
        ELSE 'Normal'
    END AS Storage_Info,
    Field_Comment
FROM FieldsForTables
WHERE Table_ID = getvariable('table_id')
ORDER BY Field_ID;


-- List all Fields across all Tables
SELECT
    Table_Name,
    Field_Name,
    Field_Type,
    Data_Type,
    CASE WHEN Is_Global THEN 'Global' ELSE '' END AS Storage
FROM FieldsForTables
ORDER BY Table_Name, Field_ID;


-- List all Calculated Fields
SELECT
    Table_Name,
    Field_Name,
    CASE WHEN DDR_Hash IS NOT NULL THEN 'Yes' ELSE 'No' END AS Has_DDR_Hash
FROM FieldsForTables
WHERE Field_Type = 'Calculated'
ORDER BY Table_Name, Field_Name;


-- ========================================
-- Lookup & AutoEnter Analysen
-- ========================================

-- AutoEnter-Statistik pro Datei
SELECT
    File_Name,
    AutoEnter_Type,
    COUNT(*) as Anzahl
FROM FieldsForTables
WHERE AutoEnter_Type IS NOT NULL
GROUP BY File_Name, AutoEnter_Type
ORDER BY File_Name, Anzahl DESC;

-- Alle Lookup-Felder einer Tabelle
SELECT
    Field_Name,
    Lookup_TO_Name as Beziehung,
    Lookup_Field_Name as Quellfeld,
    Lookup_NoMatchOption as Bei_Kein_Treffer
FROM FieldsForTables
WHERE Table_Name = 'Artikel'
  AND AutoEnter_Type = 'Looked_up'
ORDER BY Field_Name;

-- Woher kommt der Wert eines Lookup-Feldes?
SELECT
    Table_Name,
    Field_Name,
    Lookup_TO_Name as Über_Beziehung,
    Lookup_Field_Name as Quellfeld,
    Lookup_DontCopyIfEmpty,
    Lookup_NoMatchOption
FROM FieldsForTables
WHERE AutoEnter_Type = 'Looked_up'
  AND Field_Name = 'Status Auswertungen';

-- Versteckte Berechnungen: Normal-Felder mit AutoEnter Calculated
SELECT
    Table_Name,
    Field_Name,
    AE_Calc_Text as Formel,
    AE_Calc_OverwriteExisting as Überschreibt,
    AE_Calc_AlwaysEvaluate as Immer_Neu,
    File_Name as Datei
FROM FieldsForTables
WHERE AutoEnter_Type = 'Calculated'
ORDER BY File_Name, Table_Name, Field_Name;

-- Vollständige Formel-Übersicht (echte Calculated + AutoEnter Calculated)
SELECT
    Table_Name,
    Field_Name,
    CASE
        WHEN Field_Type = 'Calculated' THEN 'Calculated Field'
        WHEN AutoEnter_Type = 'Calculated' THEN 'AutoEnter Calculated'
    END as Berechnungs_Typ,
    COALESCE(Calculation_Text, AE_Calc_Text) as Formel,
    File_Name
FROM FieldsForTables
WHERE Calculation_Text IS NOT NULL OR AE_Calc_Text IS NOT NULL
ORDER BY File_Name, Table_Name, Field_Name;

-- Felder mit Standardwerten (ConstantData)
SELECT
    Table_Name,
    Field_Name,
    AE_ConstantData as Standardwert,
    File_Name as Datei
FROM FieldsForTables
WHERE AutoEnter_Type = 'ConstantData'
ORDER BY File_Name, Table_Name;

-- Reverse-Lookup: Wo wird ein Feld als Lookup-Quelle verwendet?
SELECT
    oc_source.Object_Name as Lookup_Feld,
    oc_source.File_Name as In_Datei,
    ol.Link_Role
FROM ObjectCatalog oc_target
JOIN ObjectLinks ol ON oc_target.Object_UUID = ol.Target_UUID
JOIN ObjectCatalog oc_source ON ol.Source_UUID = oc_source.Object_UUID
WHERE oc_target.Object_Type = 'Field'
  AND oc_target.Object_Name = 'Vorgabe 9'
  AND ol.Link_Role = 'lookup_source';



-- ============================================
-- Calculations als Objekte (Schema 1.22.0)
-- ============================================
-- Alle Berechnungs-Instanzen eines Owners (Slot-Inventar): Rolle, Index,
-- struktureller Ursprung, Formel-Vorschau. Instanzen existieren auch ohne
-- DDR-Info (Formula_Hash/Chunk-Spalten sind dann NULL).
SELECT Calc_Role, Calc_Index, Source_Path, Is_Static,
       left(COALESCE(Formula_Text, Display_Text), 100) AS Formula
FROM CalculationsCatalog
WHERE Owner_Name = 'Artikel::Preis' AND File_Name = 'Artikel'
ORDER BY Calc_Role, Calc_Index;

-- Ziel-Aufloesung einer Instanz (abgeleitete Sicht, Variante A — Where-used
-- bleibt auf den Owner-Kanten; has_calculation zaehlt nie als Verwendung):
SELECT vl.Link_Role, tgt.Object_Type, tgt.Object_Name
FROM v_calculation_links vl
JOIN ObjectCatalog tgt ON tgt.Object_UUID = vl.Target_UUID
WHERE vl.Calculation_UUID = '<Calculation_UUID>'
ORDER BY vl.Link_Role, tgt.Object_Name;
