-- @template_type: content
-- @description: Detailed view of a FileMaker custom function - parameters, formula code, and DDR dependencies
-- @params: uuid (required)
-- @output_format: content
-- @author: Marcel
-- @version: 1.0
-- @tags: customfunctions, details, ddr, calculations
-- @note: Shows function definition, calculation code, and DDR dependency chunks (if available)

WITH func_match AS (
  -- Clone-Scoping: Identität ist (UUID, File_Name) — auf kanonische Datei einschränken
  SELECT cf.CF_ID, cf.CF_Name, cf.CF_Display, cf.CF_UUID,
         cf.Parameters, cf.DDR_Hash, cf.File_Name
  FROM CustomFunctionsCatalog cf
  JOIN ObjectCatalog oc ON cf.CF_UUID = oc.Object_UUID AND oc.File_Name = cf.File_Name
  WHERE oc.Object_UUID = getvariable('uuid')
    AND (getvariable('file') IS NULL OR cf.File_Name = getvariable('file'))
  LIMIT 1
),
calc_code AS (
  SELECT ccf.Calculation_Code
  FROM CalcsForCustomFunctions ccf
  JOIN func_match fm ON ccf.CF_UUID = fm.CF_UUID AND ccf.File_Name = fm.File_Name
  LIMIT 1
),
ddr_chunks AS (
  SELECT d.Chunk_Index, d.Chunk_Type, d.Chunk_Content
  FROM DDR_Calculations d
  JOIN func_match fm ON fm.DDR_Hash = d.Calc_Hash
  WHERE fm.DDR_Hash IS NOT NULL
  ORDER BY d.Chunk_Index
),
func_usage AS (
  SELECT
    oc.Object_Type as Used_By_Type,
    oc.Object_Name as Used_By_Name,
    oc.File_Name as Used_By_File,
    ol.Link_Role,
    ol.Is_Cross_File
  FROM ObjectLinks ol
  JOIN ObjectCatalog oc ON ol.Source_UUID = oc.Object_UUID AND oc.File_Name = ol.Source_File
  WHERE ol.Target_UUID = getvariable('uuid')
    AND ol.Link_Type = 'operational'
    AND (getvariable('file') IS NULL OR ol.Target_File = getvariable('file'))
  ORDER BY oc.Object_Type, oc.Object_Name
)

SELECT content FROM (
  -- Header
  SELECT 1 as sort_key, 0 as sub_key,
    '=== CustomFunction Details ===' as content
  FROM func_match

  UNION ALL
  SELECT 2, 0, '' FROM func_match

  UNION ALL

  -- Function properties
  SELECT 3, 1, 'Function:     ' || fm.CF_Name FROM func_match fm
  UNION ALL
  SELECT 3, 2, 'Display:      ' || COALESCE(fm.CF_Display, '-') FROM func_match fm
  UNION ALL
  SELECT 3, 3, 'Parameters:   ' || COALESCE(array_to_string(fm.Parameters, ', '), '(none)') FROM func_match fm
  UNION ALL
  SELECT 3, 4, 'File:         ' || fm.File_Name FROM func_match fm
  UNION ALL
  SELECT 3, 5, 'UUID:         ' || fm.CF_UUID FROM func_match fm

  UNION ALL

  -- Calculation code
  SELECT 5, 0, '' WHERE (SELECT COUNT(*) FROM calc_code WHERE Calculation_Code IS NOT NULL) > 0
  UNION ALL
  SELECT 5, 1, '--- Calculation Code ---'
  WHERE (SELECT COUNT(*) FROM calc_code WHERE Calculation_Code IS NOT NULL) > 0
  UNION ALL
  SELECT 6, 1, cc.Calculation_Code
  FROM calc_code cc
  WHERE cc.Calculation_Code IS NOT NULL

  UNION ALL

  -- DDR dependency chunks (if available) — header only; chunk list omitted
  SELECT 8, 0, '' WHERE (SELECT COUNT(*) FROM ddr_chunks) > 0
  UNION ALL
  SELECT 8, 1,
    '--- DDR Dependencies --- (' || CAST((SELECT COUNT(*) FROM ddr_chunks) AS VARCHAR) || ' chunks)'
  WHERE (SELECT COUNT(*) FROM ddr_chunks) > 0

  UNION ALL

  -- Usage references
  SELECT 11, 0, '' WHERE (SELECT COUNT(*) FROM func_usage) > 0
  UNION ALL
  SELECT 11, 1,
    '--- Used in --- (' || CAST((SELECT COUNT(*) FROM func_usage) AS VARCHAR) || ')'
  WHERE (SELECT COUNT(*) FROM func_usage) > 0
  UNION ALL
  SELECT 12, ROW_NUMBER() OVER (ORDER BY Used_By_Type, Used_By_Name),
    '  <- ' || Used_By_Type || ': ' || Used_By_Name
    || CASE WHEN Is_Cross_File THEN ' [' || Used_By_File || ']' ELSE '' END
    || ' (' || Link_Role || ')'
  FROM func_usage
) details
ORDER BY sort_key, sub_key;
