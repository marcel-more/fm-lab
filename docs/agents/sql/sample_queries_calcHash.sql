/*
-- Calculated Field Dependencies (DDR-Hash basiert)
-- Requires: FileMaker 21+ with DDR-Info enabled
--
-- Version 1.0
-- Date: 2026-01-21
*/


-- ============================================================================
-- CALCULATED FIELD DEPENDENCIES
-- ============================================================================


-- List all Calculated Fields with DDR_Hash
SELECT
    f.Table_Name,
    f.Field_Name,
    f.DDR_Hash,
    CASE WHEN f.DDR_Hash IS NOT NULL THEN 'Yes' ELSE 'No' END AS Has_Hash
FROM FieldsForTables f
WHERE f.Field_Type = 'Calculated'
ORDER BY f.Table_Name, f.Field_Name;


-- Count Dependencies per Calculated Field
SELECT
    f.Field_Name,
    f.Table_Name,
    COUNT(d.Chunk_Index) as Dependency_Count
FROM FieldsForTables f
JOIN DDR_Calculations d ON f.DDR_Hash = d.Calc_Hash
WHERE f.Field_Type = 'Calculated'
GROUP BY f.Field_Name, f.Table_Name
ORDER BY Dependency_Count DESC, f.Field_Name
LIMIT 20;


-- Show all Dependencies for a specific Calculated Field
SET VARIABLE field_name = 'Artikel Nr Filter';

SELECT
    f.Field_Name AS Calculated_Field,
    f.Table_Name,
    d.Chunk_Index,
    d.Chunk_Content
FROM FieldsForTables f
JOIN DDR_Calculations d ON f.DDR_Hash = d.Calc_Hash
WHERE f.Field_Name = getvariable('field_name')
  AND f.Field_Type = 'Calculated'
ORDER BY d.Chunk_Index;


-- Find Calculated Fields with many Dependencies (complex calculations)
SELECT
    f.Field_Name,
    f.Table_Name,
    COUNT(d.Chunk_Index) as Chunk_Count,
    f.DDR_Hash
FROM FieldsForTables f
JOIN DDR_Calculations d ON f.DDR_Hash = d.Calc_Hash
WHERE f.Field_Type = 'Calculated'
GROUP BY f.Field_Name, f.Table_Name, f.DDR_Hash
HAVING COUNT(d.Chunk_Index) > 50
ORDER BY Chunk_Count DESC;


-- Statistics: Calculated Fields by Table
SELECT
    f.Table_Name,
    COUNT(*) AS Total_Calc_Fields,
    COUNT(f.DDR_Hash) AS With_Hash,
    ROUND(COUNT(f.DDR_Hash) * 100.0 / COUNT(*), 1) AS Hash_Percentage
FROM FieldsForTables f
WHERE f.Field_Type = 'Calculated'
GROUP BY f.Table_Name
ORDER BY Total_Calc_Fields DESC;



-- ============================================================================
-- CUSTOMFUNCTION DEPENDENCIES
-- ============================================================================


-- List all CustomFunctions with DDR_Hash
SELECT
    cf.CF_Name,
    cf.CF_Display,
    cf.DDR_Hash,
    CASE WHEN cf.DDR_Hash IS NOT NULL THEN 'Yes' ELSE 'No' END AS Has_Hash
FROM CustomFunctionsCatalog cf
ORDER BY cf.CF_Name;


-- Count Dependencies per CustomFunction
SELECT
    cf.CF_Name,
    COUNT(d.Chunk_Index) as Chunk_Count
FROM CustomFunctionsCatalog cf
JOIN DDR_Calculations d ON cf.DDR_Hash = d.Calc_Hash
GROUP BY cf.CF_Name
ORDER BY Chunk_Count DESC
LIMIT 20;


-- Show all Dependencies for a specific CustomFunction
SET VARIABLE cf_name = '_ListField';

SELECT
    cf.CF_Name AS Custom_Function,
    d.Chunk_Index,
    d.Chunk_Content
FROM CustomFunctionsCatalog cf
JOIN DDR_Calculations d ON cf.DDR_Hash = d.Calc_Hash
WHERE cf.CF_Name = getvariable('cf_name')
ORDER BY d.Chunk_Index;


-- Find CustomFunctions with many Dependencies (complex functions)
SELECT
    cf.CF_Name,
    cf.CF_Display,
    COUNT(d.Chunk_Index) as Chunk_Count,
    cf.DDR_Hash
FROM CustomFunctionsCatalog cf
JOIN DDR_Calculations d ON cf.DDR_Hash = d.Calc_Hash
GROUP BY cf.CF_Name, cf.CF_Display, cf.DDR_Hash
HAVING COUNT(d.Chunk_Index) > 30
ORDER BY Chunk_Count DESC;


-- Statistics: CustomFunctions Coverage
SELECT
    COUNT(*) AS Total_CustomFunctions,
    COUNT(DDR_Hash) AS With_Hash,
    ROUND(COUNT(DDR_Hash) * 100.0 / COUNT(*), 1) AS Hash_Percentage
FROM CustomFunctionsCatalog;



-- ============================================================================
-- CROSS-REFERENCE: FIELDS & CUSTOMFUNCTIONS
-- ============================================================================


-- Compare Calculated Fields vs CustomFunctions Complexity
SELECT
    'Calculated Fields' AS Type,
    COUNT(*) AS Count,
    AVG(Chunk_Count) AS Avg_Chunks,
    MAX(Chunk_Count) AS Max_Chunks,
    MIN(Chunk_Count) AS Min_Chunks
FROM (
    SELECT
        f.Field_UUID,
        COUNT(d.Chunk_Index) as Chunk_Count
    FROM FieldsForTables f
    JOIN DDR_Calculations d ON f.DDR_Hash = d.Calc_Hash
    WHERE f.Field_Type = 'Calculated'
    GROUP BY f.Field_UUID
)
UNION ALL
SELECT
    'CustomFunctions' AS Type,
    COUNT(*) AS Count,
    AVG(Chunk_Count) AS Avg_Chunks,
    MAX(Chunk_Count) AS Max_Chunks,
    MIN(Chunk_Count) AS Min_Chunks
FROM (
    SELECT
        cf.CF_UUID,
        COUNT(d.Chunk_Index) as Chunk_Count
    FROM CustomFunctionsCatalog cf
    JOIN DDR_Calculations d ON cf.DDR_Hash = d.Calc_Hash
    GROUP BY cf.CF_UUID
);


-- Find Calculated Fields and CustomFunctions with same Hash (code reuse)
SELECT
    f.Field_Name AS Calc_Field,
    f.Table_Name,
    cf.CF_Name AS Custom_Function,
    f.DDR_Hash AS Shared_Hash
FROM FieldsForTables f
JOIN CustomFunctionsCatalog cf ON f.DDR_Hash = cf.DDR_Hash
WHERE f.Field_Type = 'Calculated'
ORDER BY f.Table_Name, f.Field_Name;
